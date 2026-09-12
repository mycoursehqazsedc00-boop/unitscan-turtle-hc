--[[
	unitscan.lua — "soft" fork, mod-aware edition

	This build adds OPTIONAL integrations with five 1.12 client mods. None of them
	are required — if none are installed this behaves exactly like the original
	unitscan-soft (TargetByName flicker-scan). Each integration is feature-detected
	at load time and only used if actually present, so it's safe to drop this file
	into a client that has any subset of these installed.

		- ClassicAPI  (https://github.com/brues-code/ClassicAPI)
		    Adds nameplateN unit tokens (nameplate1..nameplateN = the Nth visible
		    nameplate, usable with UnitName/UnitGUID/UnitCanAttack/etc like any
		    other unit token). THIS is the actual fix for the flicker problem:
		    we can check "is there a nameplate named X nearby" without ever
		    calling TargetByName, so your real target is never touched and
		    other addons never see a PLAYER_TARGET_CHANGED for the scan.
		    Also fires NAME_PLATE_UNIT_ADDED (near-instant, not polled), and
		    natively adds UnitDistanceSquared(unit) / UnitInLineOfSight(unit) —
		    both used below instead of requiring UnitXP_SP3 for range/LOS.

		- SuperWoW (https://github.com/balakethelock/SuperWoW)
		    UnitExists() returns a GUID as its 2nd value, and unit-taking
		    functions accept raw GUID strings / mark1-mark8. Used here as a
		    fallback GUID source and for the mark1-mark8 convenience.

		- nampower (https://github.com/brues-code/nampower)
		    GetUnitGUID()/UnitGUID() (naming has drifted between versions,
		    both are checked) using the same extended token parser as
		    SuperWoW. Also fires UNIT_DIED, which we use to instantly drop a
		    tracked target from the zone list instead of waiting on the
		    90-second reload timer.

		- UnitXP_SP3 (https://codeberg.org/konaka/UnitXP_SP3)
		    UnitXP("distanceBetween", ...) / UnitXP("inSight", ...) as a
		    fallback range/LOS source for anyone running UnitXP without
		    ClassicAPI. UnitXP("notify", "taskbarIcon"/"systemSound") to
		    alert you even if the game is in the background — this part has
		    no ClassicAPI equivalent, so UnitXP is still the one that gets
		    you background alerts.

		- VanillaHelpers (https://github.com/isfir/VanillaHelpers)
		    SetUnitBlip(unit, texture, scale) to put a distinct marker on the
		    minimap for whatever was just found.

	Also uses, natively (no mod required, confirmed present in the base 1.12.1
	client): TargetUnit(unit) and SetRaidTarget(unit, index). The latter is
	paired with WeirdUtils' outline.dll (https://codeberg.org/MarcelineVQ/WeirdUtils/wiki/Outlines),
	which auto-draws a glowing screen outline around any raid-marked unit —
	if that DLL happens to be running, /unitscanmark gets you a free on-screen
	highlight on whatever was found. Harmless either way if it isn't.

	Load order note: none of these DLLs need to load before this addon — they
	patch engine functions at the C++ level before any Lua runs, so by the time
	VARIABLES_LOADED fires the globals below are either present or they aren't.
]]

local unitscan = CreateFrame'Frame'

------------------------------------------------------------------------------
-- Mod detection
------------------------------------------------------------------------------

local MODS = {}

-- SuperWoW sets these globals per its own documented feature list.
MODS.SuperWoW = (SUPERWOW_VERSION ~= nil) or (SUPERWOW_STRING ~= nil)

-- nampower's GUID getter has been named both UnitGUID and GetUnitGUID across
-- versions (its own changelog shows the migration) — check both.
local GetGUID = UnitGUID or GetUnitGUID
MODS.Nampower = (GetGUID ~= nil) or (type(GetCVar) == 'function' and GetCVar('NP_SpellQueueWindowMs') ~= nil)

-- UnitXP_SP3's own documented existence check.
MODS.UnitXP = (type(UnitXP) == 'function') and pcall(UnitXP, 'nop', 'nop')

-- ClassicAPI: probe for a nameplate token actually resolving. C_NamePlate
-- existing is a good hint too but the token is what we actually need.
MODS.ClassicAPI = (C_NamePlate ~= nil) or (type(UnitExists) == 'function' and (function()
	local ok, exists = pcall(UnitExists, 'nameplate1')
	return ok
end)())

MODS.VanillaHelpers = (type(SetUnitBlip) == 'function')

-- Confirmed native to the base 1.12.1 client (not added by any of the above) —
-- still feature-detected defensively since we can't be 100% sure of every
-- client build, but no longer treated as an uncertain "maybe modern API" call.
local CAN_TARGETUNIT = (type(TargetUnit) == 'function')
local CAN_MARK = (type(SetRaidTarget) == 'function')

-- ClassicAPI's native distance/LOS backport. When present this needs nothing
-- else -- UnitXP_SP3 is only consulted as a fallback for people who have
-- UnitXP but not ClassicAPI.
local CAN_NATIVE_DIST = (type(UnitDistanceSquared) == 'function')
local CAN_NATIVE_LOS = (type(UnitInLineOfSight) == 'function')

-- Unified GUID getter that works whichever of SuperWoW/nampower is present.
function unitscan.get_guid(unit)
	if GetGUID then
		local ok, guid = pcall(GetGUID, unit)
		if ok and guid then return guid end
	end
	if MODS.SuperWoW and type(UnitExists) == 'function' then
		local exists, guid = UnitExists(unit)
		if exists and guid then return guid end
	end
	return nil
end

------------------------------------------------------------------------------
-- Frame setup / events (unchanged from upstream, plus UNIT_DIED if present)
------------------------------------------------------------------------------

unitscan:SetScript('OnUpdate', function() unitscan.UPDATE() end)
unitscan:SetScript('OnEvent', function()
	if event == "VARIABLES_LOADED" then
		unitscan.LOAD()
		unitscan.scan = true
	elseif event == "PLAYER_REGEN_DISABLED" then
		unitscan.incombat = true
		unitscan.scan = nil
	elseif event == "PLAYER_REGEN_ENABLED" then
		unitscan.incombat = nil
		unitscan.scan = true
	elseif (event == "PLAYER_ENTER_COMBAT" or event == "START_AUTOREPEAT_SPELL") then
		if not unitscan.incombat then
			unitscan.scan = nil
		end
	elseif (event == "STOP_AUTOREPEAT_SPELL" or event == "PLAYER_LEAVE_COMBAT") then
		if not unitscan.incombat then
			unitscan.scan = true
		end
	elseif event == "UNIT_DIED" then
		-- nampower-only event. arg1 is a GUID; if it matches the unit we're
		-- currently tracking as "found", drop it immediately rather than
		-- waiting for the 90s zone-target reload.
		if unitscan.foundGuid and arg1 == unitscan.foundGuid then
			unitscan.foundGuid = nil
			if CAN_MARK and unitscan.markedUnit then
				pcall(SetRaidTarget, unitscan.markedUnit, 0)
				unitscan.markedUnit = nil
			end
		end
	elseif event == "NAME_PLATE_UNIT_ADDED" then
		-- ClassicAPI-only event, fires within a tick of the plate appearing
		-- (a per-frame diff internally, not a poll we're piggybacking on).
		-- arg1 is the "nameplateN" token for the unit that just appeared --
		-- check just that one unit immediately instead of waiting for the
		-- once-a-second sweep in unitscan.UPDATE.
		if unitscan.scan then
			unitscan.check_single_nameplate(arg1)
		end
	else
		unitscan.load_zonetargets()
	end
end)
unitscan:RegisterEvent'VARIABLES_LOADED'
unitscan:RegisterEvent'MINIMAP_ZONE_CHANGED'
unitscan:RegisterEvent'PLAYER_ENTERING_WORLD'
unitscan:RegisterEvent'PLAYER_REGEN_DISABLED'
unitscan:RegisterEvent'PLAYER_REGEN_ENABLED'
unitscan:RegisterEvent'PLAYER_ENTER_COMBAT'
unitscan:RegisterEvent'PLAYER_LEAVE_COMBAT'
unitscan:RegisterEvent'START_AUTOREPEAT_SPELL'
unitscan:RegisterEvent'STOP_AUTOREPEAT_SPELL'
if MODS.Nampower then
	unitscan:RegisterEvent'UNIT_DIED'
end
if MODS.ClassicAPI then
	unitscan:RegisterEvent'NAME_PLATE_UNIT_ADDED'
end

local BROWN = {.7, .15, .05}
local YELLOW = {1, 1, .15}
local CHECK_INTERVAL = 1
local MAX_NAMEPLATES = 40 -- loop bound for nameplate1..N; cheap even when unused

unitscan_targets = {}
unitscan_minlevel = unitscan_minlevel or 0
unitscan_wf = unitscan_wf or 0
unitscan_range = unitscan_range or 0 -- 0 = no distance filter (ClassicAPI native, UnitXP fallback)
unitscan_los = unitscan_los or 0 -- 1 = also require line of sight (ClassicAPI native, UnitXP fallback)
unitscan_ignoreelites = unitscan_ignoreelites or 0 -- 1 = skip plain "elite" hits from the zone-target list
unitscan_mark = unitscan_mark or 0 -- 1 = drop a raid-skull mark on whatever is found (pairs with WeirdUtils outline.dll)

do
	local last_played
	function unitscan.play_sound()
		if not last_played or GetTime() - last_played > 10 then
			SetCVar('MasterSoundEffects', 0)
			SetCVar('MasterSoundEffects', 1)
			PlaySoundFile[[Interface\AddOns\unitscan-turtle-hc\gruntling_horn_bb.ogg]]
			last_played = GetTime()

			-- UnitXP_SP3: also flash the taskbar / play an OS-level sound so
			-- you get alerted even if the game window is in the background.
			if MODS.UnitXP then
				pcall(UnitXP, 'notify', 'taskbarIcon')
				pcall(UnitXP, 'notify', 'systemSound')
			end
		end
	end
end

function unitscan.load_zonetargets()
	unitscan_zone_targets()
end

------------------------------------------------------------------------------
-- Scanning core
--
-- Two scan strategies, chosen automatically:
--   1. Nameplate scan (MODS.ClassicAPI) — walks nameplate1..MAX_NAMEPLATES,
--      never touches your real target, works even while you have one.
--   2. Legacy TargetByName flicker-scan — identical to upstream, used as a
--      fallback when nameplate tokens aren't available.
------------------------------------------------------------------------------

do
	local prevTarget
	local foundTarget
	local _PlaySound = PlaySound
	local _UIErrorsFrame_OnEvent = UIErrorsFrame_OnEvent
	local pass = function() end

	function unitscan.reset()
		prevTarget = nil
		foundTarget = nil
		unitscan.foundUnit = nil
		unitscan.foundGuid = nil
	end

	function unitscan.restoreTarget()
		if foundTarget and (not (prevTarget == foundTarget)) then
			PlaySound = pass
			TargetLastTarget()
			PlaySound = _PlaySound
		end
		prevTarget = nil
		foundTarget = nil
	end

	-- Applies the shared filters (level, alive, attackable, optional
	-- distance/LOS via UnitXP, optional elite suppression) to a unit token
	-- that already matched a name. isExplicit is true for names the user
	-- added with /unitscan directly -- those always alert regardless of the
	-- elite filter, since the user asked for that specific mob by name.
	-- Returns true if it should trigger an alert.
	local function passes_filters(unit, isExplicit)
		if UnitIsPlayer(unit) then
			return true
		end
		if UnitIsDead(unit) or not UnitCanAttack(unit, "player") then
			return false
		end
		local targetLevel = UnitLevel(unit)
		if targetLevel > 0 and targetLevel < unitscan_minlevel then
			return false
		end
		if (not isExplicit) and unitscan_ignoreelites == 1 and type(UnitClassification) == 'function' then
			local ok, classification = pcall(UnitClassification, unit)
			-- Only suppresses plain "elite". "rareelite", "rare" and
			-- "worldboss" always alert -- those are the ones actually worth
			-- an interrupt in an elite-dense zone.
			if ok and classification == "elite" then
				return false
			end
		end
		if unitscan_range > 0 then
			-- Prefer ClassicAPI's native backport (needs nothing else);
			-- fall back to UnitXP_SP3 for people who only have that.
			if CAN_NATIVE_DIST then
				local ok, distSq, checked = pcall(UnitDistanceSquared, unit)
				if ok and checked and distSq > (unitscan_range * unitscan_range) then
					return false
				end
			elseif MODS.UnitXP then
				local ok, dist = pcall(UnitXP, "distanceBetween", "player", unit)
				if ok and dist and dist > unitscan_range then
					return false
				end
			end
		end
		if unitscan_los == 1 then
			if CAN_NATIVE_LOS then
				local ok, visible = pcall(UnitInLineOfSight, unit)
				if ok and visible == false then
					return false
				end
			elseif MODS.UnitXP then
				local ok, visible = pcall(UnitXP, "inSight", "player", unit)
				if ok and visible == false then
					return false
				end
			end
		end
		return true
	end

	-- Marks (and un-marks) the found unit with a native raid icon. Harmless
	-- on its own; if WeirdUtils' outline.dll happens to be running, it also
	-- draws a glowing screen outline around whatever carries the mark.
	local function apply_mark(unit)
		if not (CAN_MARK and unitscan_mark == 1) then return end
		if unitscan.markedUnit then
			pcall(SetRaidTarget, unitscan.markedUnit, 0)
		end
		pcall(SetRaidTarget, unit, 8) -- skull
		unitscan.markedUnit = unit
	end

	-- Shared "did this already-resolved unit match either list, and if so
	-- fire the alert" step. Used by both the polling sweep (nameplate_scan)
	-- and the NAME_PLATE_UNIT_ADDED event handler (single-unit check) so the
	-- alert sequence only lives in one place.
	local function evaluate_unit(unit, uname)
		if not uname then return false end

		local key = strupper(uname)
		if unitscan_targets[key] and passes_filters(unit, true) then
			unitscan.foundUnit = unit
			unitscan.foundGuid = unitscan.get_guid(unit)
			unitscan.foundTarget = key
			unitscan.toggle_target(key)
			unitscan.play_sound()
			unitscan.flash.animation:Play()
			unitscan.button:set_target()
			apply_mark(unit)
			return true
		end

		if unitscan_zonetargets[uname] and passes_filters(unit, false) then
			unitscan.foundUnit = unit
			unitscan.foundGuid = unitscan.get_guid(unit)
			unitscan.foundTarget = uname
			unitscan.toggle_zonetarget(uname)
			unitscan.play_sound()
			unitscan.flash.animation:Play()
			unitscan.button:set_target()
			apply_mark(unit)
			return true
		end

		return false
	end

	-- Event-driven path: NAME_PLATE_UNIT_ADDED hands us one live token the
	-- instant it appears -- check just that unit instead of waiting for the
	-- once-a-second sweep.
	function unitscan.check_single_nameplate(unit)
		if not (unit and UnitExists(unit)) then return end
		evaluate_unit(unit, UnitName(unit))
	end

	-- Strategy 1: nameplate scan (polling sweep, still runs once a second as
	-- a safety net alongside the event-driven path above -- e.g. for a plate
	-- that existed before this addon loaded, or if an ADDED event is ever
	-- missed). Never touches your real target.
	local function nameplate_scan()
		for i = 1, MAX_NAMEPLATES do
			local unit = "nameplate" .. i
			if UnitExists(unit) then
				if evaluate_unit(unit, UnitName(unit)) then
					return
				end
			end
		end
	end

	-- Strategy 2: legacy flicker-scan, upstream behavior, unchanged except
	-- for also recording a GUID when SuperWoW/nampower can supply one, and
	-- threading isExplicit through to the elite filter.
	function unitscan.target(name, isExplicit)
		prevTarget = UnitName("target")
		UIErrorsFrame_OnEvent = pass
		PlaySound = pass
		TargetByName(name, true)
		UIErrorsFrame_OnEvent = _UIErrorsFrame_OnEvent
		PlaySound = _PlaySound
		foundTarget = UnitName("target")

		if not foundTarget then return nil end

		if not passes_filters("target", isExplicit) then
			return nil
		end

		unitscan.foundUnit = "target"
		unitscan.foundGuid = unitscan.get_guid("target")

		if UnitIsPlayer("target") then
			return strupper(foundTarget)
		else
			return strupper(foundTarget)
		end
	end

	function unitscan.check_for_targets()
		if MODS.ClassicAPI then
			-- Nameplate path: doesn't require an empty target, doesn't touch
			-- your real target, so we don't early-return on UnitExists("target").
			-- This is now just the once-a-second safety-net sweep; most hits
			-- will already have fired instantly via NAME_PLATE_UNIT_ADDED.
			nameplate_scan()
			return
		end

		-- Legacy path: identical to upstream, requires no current target.
		if UnitExists("target") then
			return
		end

		for name, _ in unitscan_targets do
			if name == unitscan.target(name, true) then
				unitscan.foundTarget = name
				unitscan.toggle_target(name)
				unitscan.play_sound()
				unitscan.flash.animation:Play()
				unitscan.button:set_target()
			end
			unitscan.restoreTarget()
		end

		for name, _ in unitscan_zonetargets do
			if strupper(name) == unitscan.target(name, false) then
				unitscan.foundTarget = name
				unitscan.toggle_zonetarget(name)
				unitscan.play_sound()
				unitscan.flash.animation:Play()
				unitscan.button:set_target()
			end
			unitscan.restoreTarget()
		end
	end
end

------------------------------------------------------------------------------
-- UI (unchanged from upstream, except button:set_target uses the live unit
-- token for the model preview when available, and drops a VanillaHelpers
-- minimap blip on the found unit)
------------------------------------------------------------------------------

function unitscan.LOAD()
	do
		local flash = CreateFrame'Frame'
		unitscan.flash = flash
		flash:Show()
		flash:SetAllPoints()
		flash:SetAlpha(0)
		flash:SetFrameStrata'FULLSCREEN_DIALOG'
		local texture = flash:CreateTexture()
		texture:SetBlendMode'ADD'
		texture:SetAllPoints()
		texture:SetTexture[[Interface\FullScreenTextures\LowHealth]]

		flash.animation = CreateFrame'Frame'
		flash.animation:Hide()
		flash.animation:SetScript('OnUpdate', function()
			local t = GetTime() - this.t0
			if t <= .2 then
				flash:SetAlpha(t * 5)
			elseif t <= .4 then
				flash:SetAlpha(1)
			elseif t <= .6 then
				flash:SetAlpha(1 - (t - .4) * 5)
			else
				flash:SetAlpha(0)
				this.loops = this.loops - 1
				if this.loops == 0 then
					this.t0 = nil
					this:Hide()
				else
					this.t0 = GetTime()
				end
			end
		end)
		function flash.animation:Play()
			if self.t0 then
				self.loops = 4
			else
				self.t0 = GetTime()
				self.loops = 3
			end
			self:Show()
		end
	end

	local button = CreateFrame("Button", "unitscan_button", UIParent)
	button:Hide()
	unitscan.button = button
	button.autoCloseTime = nil
	button:SetPoint('BOTTOM', UIParent, 0, 148)
	button:SetWidth(200)
	button:SetHeight(42)
	button:SetScale(1)
	button:SetMovable(true)
	button:SetUserPlaced(true)
	button:SetClampedToScreen(true)
	button:SetScript('OnMouseDown', function()
		if IsControlKeyDown() then
			this:RegisterForClicks()
			this:StartMoving()
		end
	end)
	button:SetScript('OnMouseUp', function()
		this:StopMovingOrSizing()
		this:RegisterForClicks'LeftButtonDown'
	end)
	button:SetFrameStrata'FULLSCREEN_DIALOG'
	button:SetBackdrop{
		tile = true,
		edgeSize = 16,
		edgeFile = [[Interface\Tooltips\UI-Tooltip-Border]],
	}
	button:SetBackdropBorderColor(unpack(BROWN))
	button:SetScript('OnEnter', function()
		this:SetBackdropBorderColor(unpack(YELLOW))
	end)
	button:SetScript('OnLeave', function()
		this:SetBackdropBorderColor(unpack(BROWN))
	end)
	button:SetScript('OnClick', function()
		SlashCmdList.UNITSCANTARGET()
	end)

	function button:set_target()
		-- Prefer showing the model of the live unit token we actually found
		-- (nameplate scan) over relying on "target" (legacy scan already set
		-- "target" to the found unit at this point, so both paths work).
		local previewUnit = unitscan.foundUnit or "target"
		self:SetText(unitscan.foundTarget or UnitName(previewUnit))
		self.model:reset()
		self.model:SetUnit(previewUnit)
		self:Show()
		self.glow.animation:Play()
		self.shine.animation:Play()

		if unitscan_wf and unitscan_wf > 0 then
			self.autoCloseTime = GetTime() + unitscan_wf
		else
			self.autoCloseTime = nil
		end

		-- VanillaHelpers: drop a distinct minimap blip on whatever was found,
		-- if we have a live unit token for it.
		if MODS.VanillaHelpers and unitscan.foundUnit then
			pcall(SetUnitBlip, unitscan.foundUnit, [[Interface\Minimap\ObjectIcons]], 1.4)
		end
	end

	do
		local background = button:CreateTexture(nil, 'BACKGROUND')
		background:SetTexture[[Interface\AddOns\unitscan-turtle-hc\UI-Achievement-Parchment-Horizontal]]
		background:SetPoint('BOTTOMLEFT', 3, 3)
		background:SetPoint('TOPRIGHT', -3, -3)
		background:SetTexCoord(0, 1, 0, .25)
	end

	do
		local title_background = button:CreateTexture(nil, 'BORDER')
		title_background:SetTexture[[Interface\AddOns\unitscan-turtle-hc\UI-Achievement-Title]]
		title_background:SetPoint('TOPRIGHT', -5, -5)
		title_background:SetPoint('LEFT', 5, 0)
		title_background:SetHeight(18)
		title_background:SetTexCoord(0, .9765625, 0, .3125)
		title_background:SetAlpha(.8)

		local title = button:CreateFontString(nil, 'OVERLAY')
		title:SetFont([[Fonts\FRIZQT__.TTF]], 14)
		title:SetShadowOffset(1, -1)
		title:SetPoint('TOPLEFT', title_background, 0, 0)
		title:SetPoint('RIGHT', title_background)
		button:SetFontString(title)

		local subtitle = button:CreateFontString(nil, 'OVERLAY')
		subtitle:SetFont([[Fonts\FRIZQT__.TTF]], 12)
		subtitle:SetTextColor(0, 0, 0)
		subtitle:SetPoint('TOPLEFT', title, 'BOTTOMLEFT', 0, -4)
		subtitle:SetPoint('RIGHT', title )
		subtitle:SetText'Unit Found!'
	end

	do
		local model = CreateFrame('PlayerModel', nil, button)
		button.model = model
		model:SetPoint('BOTTOMLEFT', button, 'TOPLEFT', 0, 10)
		model:SetPoint('RIGHT', 0, 0)
		model:SetHeight(button:GetWidth() * .6)

		do
			local last_update, delay
			function model:on_update()
				this:SetFacing(this:GetFacing() + (GetTime() - last_update) * math.pi / 4)
				last_update = GetTime()
			end
			function model:on_update_model()
				if delay > 0 then
					delay = delay - 1
					return
				end
				this:SetScript('OnUpdateModel', nil)
				this:SetScript('OnUpdate', this.on_update)
				this:SetModelScale(1)
				this:SetAlpha(1)
				last_update = GetTime()
			end
			function model:reset()
				self:SetAlpha(0)
				self:SetFacing(0)
				self:SetModelScale(1)
				self:ClearModel()
				self:SetScript('OnUpdate', nil)
				self:SetScript("OnUpdateModel", self.on_update_model)
				delay = 10
			end
		end
	end

	do
		local close = CreateFrame('Button', nil, button, 'UIPanelCloseButton')
		close:SetPoint('TOPRIGHT', 0, 0)
		close:SetWidth(32)
		close:SetHeight(32)
		close:SetScale(.8)
		close:SetHitRectInsets(8, 8, 8, 8)
	end

	do
		local glow = button.model:CreateTexture(nil, 'OVERLAY')
		button.glow = glow
		glow:SetPoint('CENTER', button, 'CENTER')
		glow:SetWidth(400 / 300 * button:GetWidth())
		glow:SetHeight(171 / 70 * button:GetHeight())
		glow:SetTexture[[Interface\AddOns\unitscan-turtle-hc\UI-Achievement-Alert-Glow]]
		glow:SetBlendMode'ADD'
		glow:SetTexCoord(0, .78125, 0, .66796875)
		glow:SetAlpha(0)

		glow.animation = CreateFrame'Frame'
		glow.animation:Hide()
		glow.animation:SetScript('OnUpdate', function()
			local t = GetTime() - this.t0
			if t <= .2 then
				glow:SetAlpha(t * 5)
			elseif t <= .7 then
				glow:SetAlpha(1 - (t - .2) * 2)
			else
				glow:SetAlpha(0)
				this:Hide()
			end
		end)
		function glow.animation:Play()
			self.t0 = GetTime()
			self:Show()
		end
	end

	do
		local shine = button:CreateTexture(nil, 'ARTWORK')
		button.shine = shine
		shine:SetPoint('TOPLEFT', button, 0, 8)
		shine:SetWidth(67 / 300 * button:GetWidth())
		shine:SetHeight(1.28 * button:GetHeight())
		shine:SetTexture[[Interface\AddOns\unitscan-turtle-hc\UI-Achievement-Alert-Glow]]
		shine:SetBlendMode'ADD'
		shine:SetTexCoord(.78125, .912109375, 0, .28125)
		shine:SetAlpha(0)

		shine.animation = CreateFrame'Frame'
		shine.animation:Hide()
		shine.animation:SetScript('OnUpdate', function()
			local t = GetTime() - this.t0
			if t <= .3 then
				shine:SetPoint('TOPLEFT', button, 0, 8)
			elseif t <= .7 then
				shine:SetPoint('TOPLEFT', button, (t - .3) * 2.5 * this.distance, 8)
			end
			if t <= .3 then
				shine:SetAlpha(0)
			elseif t <= .5 then
				shine:SetAlpha(1)
			elseif t <= .7 then
				shine:SetAlpha(1 - (t - .5) * 5)
			else
				shine:SetAlpha(0)
				this:Hide()
			end
		end)
		function shine.animation:Play()
			self.t0 = GetTime()
			self.distance = button:GetWidth() - shine:GetWidth() + 8
			self:Show()
		end
	end

	unitscan.print(string.format(
		"mods detected: ClassicAPI=%s SuperWoW=%s nampower=%s UnitXP_SP3=%s VanillaHelpers=%s",
		tostring(MODS.ClassicAPI), tostring(MODS.SuperWoW), tostring(MODS.Nampower),
		tostring(MODS.UnitXP), tostring(MODS.VanillaHelpers)))
	if MODS.ClassicAPI then
		unitscan.print("using nameplate scan (no target flicker)")
	else
		unitscan.print("using legacy TargetByName scan (install ClassicAPI to remove target flicker)")
	end
end

------------------------------------------------------------------------------
-- Update loop
------------------------------------------------------------------------------

do
	unitscan.last_check = GetTime()
	function unitscan.UPDATE()
		if unitscan.scan then
			if unitscan.button and unitscan.button:IsShown() and unitscan.button.autoCloseTime then
				if GetTime() >= unitscan.button.autoCloseTime then
					unitscan.button:Hide()
					unitscan.button.autoCloseTime = nil
				end
			end

			if GetTime() - unitscan.last_check >= CHECK_INTERVAL then
				unitscan.last_check = GetTime()
				if (unitscan.reloadtimer and (unitscan.last_check >= unitscan.reloadtimer)) then
					unitscan.reloadtimer = nil
					unitscan.load_zonetargets()
				end
				unitscan.check_for_targets()
			end
		end
	end
end

------------------------------------------------------------------------------
-- Helpers / slash commands
------------------------------------------------------------------------------

function unitscan.print(msg)
	if DEFAULT_CHAT_FRAME then
		DEFAULT_CHAT_FRAME:AddMessage(LIGHTYELLOW_FONT_COLOR_CODE .. '<unitscan> ' .. msg)
	end
end

function unitscan.sorted_targets()
	local sorted_targets = {}
	for key in pairs(unitscan_targets) do
		tinsert(sorted_targets, key)
	end
	sort(sorted_targets, function(key1, key2) return key1 < key2 end)
	return sorted_targets
end

function unitscan.sorted_zonetargets()
	local sorted_targets = {}
	for key in pairs(unitscan_zonetargets) do
		tinsert(sorted_targets, key)
	end
	sort(sorted_targets, function(key1, key2) return key1 < key2 end)
	return sorted_targets
end

function unitscan.toggle_target(name)
	local key = strupper(name)
	if unitscan_targets[key] then
		unitscan_targets[key] = nil
		unitscan.print('- ' .. key)
	elseif key ~= '' then
		unitscan_targets[key] = true
		unitscan.print('+ ' .. key)
	end
end

function unitscan.toggle_zonetarget(name)
	local key = name
	if unitscan_zonetargets[key] then
		unitscan.print(key .. ' was found!')
		unitscan_zonetargets[key] = nil
		unitscan.reloadtimer = GetTime() + 90
	end
end

SLASH_UNITSCAN1 = '/unitscan'
function SlashCmdList.UNITSCAN(parameter)
	local _, _, name = strfind(parameter, '^%s*(.-)%s*$')
	if name == '' then
		unitscan.print("Added targets:")
		for _, key in ipairs(unitscan.sorted_targets()) do
			unitscan.print(key)
		end
		unitscan.print("Zone targets:")
		for _, key in ipairs(unitscan.sorted_zonetargets()) do
			unitscan.print(key)
		end
	else
		unitscan.toggle_target(name)
	end
end

SLASH_UNITSCANLEVEL1 = "/unitscanlevel"
function SlashCmdList.UNITSCANLEVEL(msg)
	local num = tonumber(msg)
	if not num then
		unitscan.print("Current minimum alert level: " .. unitscan_minlevel)
		unitscan.print("Use /unitscanlevel <number> to change it.")
		return
	end
	if num < 1 or num > 100 then
		unitscan.print("Invalid level. Enter a number between 1 and 100.")
		return
	end
	unitscan_minlevel = num
	unitscan.print("Unitscan will now alert only mobs of level " .. num .. " or higher.")
end

SLASH_UNITSCANWF1 = "/unitscanwf"
function SlashCmdList.UNITSCANWF(msg)
	local num = tonumber(msg)
	if not num then
		unitscan.print("Current window fade time: " .. unitscan_wf)
		unitscan.print("Use /unitscanwf <seconds> (0-100).")
		return
	end
	if num < 0 or num > 100 then
		unitscan.print("Invalid value. Enter a number between 0 and 100.")
		return
	end
	unitscan_wf = num
	if num == 0 then
		unitscan.print("Unitscan window will stay open until closed manually.")
	else
		unitscan.print("Unitscan window will auto-close after " .. num .. " seconds.")
	end
end

SLASH_UNITSCANRANGE1 = "/unitscanrange"
function SlashCmdList.UNITSCANRANGE(msg)
	if not (CAN_NATIVE_DIST or MODS.UnitXP) then
		unitscan.print("/unitscanrange requires ClassicAPI or UnitXP_SP3 (neither detected).")
		return
	end
	local num = tonumber(msg)
	if not num then
		unitscan.print("Current max alert range: " .. (unitscan_range == 0 and "unlimited" or (unitscan_range .. " yd")))
		unitscan.print("Use /unitscanrange <yards> (0 = unlimited).")
		return
	end
	if num < 0 then
		unitscan.print("Invalid value.")
		return
	end
	unitscan_range = num
	unitscan.print("Max alert range set to " .. (num == 0 and "unlimited" or (num .. " yd")))
end

SLASH_UNITSCANLOS1 = "/unitscanlos"
function SlashCmdList.UNITSCANLOS(msg)
	if not (CAN_NATIVE_LOS or MODS.UnitXP) then
		unitscan.print("/unitscanlos requires ClassicAPI or UnitXP_SP3 (neither detected).")
		return
	end
	msg = strlower(msg or '')
	if msg == 'on' then
		unitscan_los = 1
	elseif msg == 'off' then
		unitscan_los = 0
	elseif msg ~= '' then
		unitscan.print("Use /unitscanlos on or /unitscanlos off.")
		return
	end
	unitscan.print("Line-of-sight requirement: " .. (unitscan_los == 1 and "on" or "off"))
end

SLASH_UNITSCANMARK1 = "/unitscanmark"
function SlashCmdList.UNITSCANMARK(msg)
	if not CAN_MARK then
		unitscan.print("/unitscanmark requires SetRaidTarget, which isn't available.")
		return
	end
	msg = strlower(msg or '')
	if msg == 'on' then
		unitscan_mark = 1
	elseif msg == 'off' then
		unitscan_mark = 0
		if unitscan.markedUnit then
			pcall(SetRaidTarget, unitscan.markedUnit, 0)
			unitscan.markedUnit = nil
		end
	elseif msg ~= '' then
		unitscan.print("Use /unitscanmark on or /unitscanmark off.")
		return
	end
	if unitscan_mark == 1 then
		unitscan.print("Will drop a skull mark on whatever is found. If WeirdUtils' outline.dll is running, that also draws a glowing outline around it.")
	else
		unitscan.print("Marking off.")
	end
end

SLASH_UNITSCANELITE1 = "/unitscanelite"
function SlashCmdList.UNITSCANELITE(msg)
	msg = strlower(msg or '')
	if msg == 'on' then
		unitscan_ignoreelites = 1
	elseif msg == 'off' then
		unitscan_ignoreelites = 0
	elseif msg ~= '' then
		unitscan.print("Use /unitscanelite on or /unitscanelite off.")
		return
	end
	if unitscan_ignoreelites == 1 then
		unitscan.print("Ignoring plain 'elite' hits from the zone-target list. Rares, rare-elites and world bosses still alert. Names you added with /unitscan always alert.")
	else
		unitscan.print("Elite suppression off -- zone-list elites alert normally.")
	end
end

SLASH_UNITSCANMODS1 = "/unitscanmods"
function SlashCmdList.UNITSCANMODS(msg)
	unitscan.print("===== Detected mods =====")
	unitscan.print("ClassicAPI (nameplate scan, instant NAME_PLATE_UNIT_ADDED, native range/LOS): " .. tostring(MODS.ClassicAPI))
	unitscan.print("SuperWoW (GUIDs, mark1-8): " .. tostring(MODS.SuperWoW))
	unitscan.print("nampower (GUIDs, UNIT_DIED): " .. tostring(MODS.Nampower))
	unitscan.print("UnitXP_SP3 (range/LOS fallback, taskbar/sound alert): " .. tostring(MODS.UnitXP))
	unitscan.print("VanillaHelpers (minimap blip on found unit): " .. tostring(MODS.VanillaHelpers))
	unitscan.print("Native TargetUnit/SetRaidTarget available: " .. tostring(CAN_TARGETUNIT) .. " / " .. tostring(CAN_MARK))
	unitscan.print("Scan method in use: " .. (MODS.ClassicAPI and "event-driven nameplate scan" or "legacy TargetByName flicker-scan"))
end

SLASH_UNITSCANHELP1 = "/unitscanhelp"
function SlashCmdList.UNITSCANHELP(msg)
	unitscan.print("===== Unitscan Help =====")
	unitscan.print("/unitscan <name>")
	unitscan.print("  Toggle tracking of a specific NPC by name.")
	unitscan.print("  Example: /unitscan Hogger")
	unitscan.print("  Current tracked targets: " .. table.getn(unitscan.sorted_targets()))
	unitscan.print("/unitscanlevel <number>")
	unitscan.print("  Only alert for mobs at or above this level.")
	unitscan.print("  0 shows all mobs. Current: " .. unitscan_minlevel)
	unitscan.print("/unitscanwf <seconds>")
	unitscan.print("  Sets how long the popup creature window stays open.")
	unitscan.print("  0 = stays open until closed manually.")
	unitscan.print("  Current: " .. unitscan_wf .. " seconds")
	unitscan.print("/unitscanrange <yards>")
	unitscan.print("  Requires ClassicAPI (native) or UnitXP_SP3 (fallback). Only alert within this range. 0 = unlimited.")
	unitscan.print("  Current: " .. (unitscan_range == 0 and "unlimited" or (unitscan_range .. " yd")))
	unitscan.print("/unitscanlos on|off")
	unitscan.print("  Requires ClassicAPI (native) or UnitXP_SP3 (fallback). Also require line of sight to alert.")
	unitscan.print("  Current: " .. (unitscan_los == 1 and "on" or "off"))
	unitscan.print("/unitscanmark on|off")
	unitscan.print("  Drops a skull raid-mark on whatever is found. Pairs with WeirdUtils' outline.dll for a glowing on-screen highlight; harmless without it.")
	unitscan.print("  Current: " .. (unitscan_mark == 1 and "on" or "off"))
	unitscan.print("/unitscanelite on|off")
	unitscan.print("  Suppresses plain 'elite' hits from the zone-target list (rares/rare-elites/world bosses still alert).")
	unitscan.print("  Names you added yourself with /unitscan always alert regardless of this setting.")
	unitscan.print("  Current: " .. (unitscan_ignoreelites == 1 and "on" or "off"))
	unitscan.print("/unitscantarget")
	unitscan.print("  Retarget the last detected NPC (if available).")
	unitscan.print("/unitscanmods")
	unitscan.print("  Shows which optional mods were detected and which scan method is active.")
	unitscan.print("/unitscanhelp")
	unitscan.print("  Shows this help message.")
end

SLASH_UNITSCANTARGET1 = '/unitscantarget'
function SlashCmdList.UNITSCANTARGET()
	-- Prefer a direct, unambiguous target by live unit token or GUID
	-- (works correctly even with duplicate-named mobs nearby). Falls back to
	-- name-based targeting, matching upstream behavior, if neither the mod
	-- support nor the live token is available anymore.
	if CAN_TARGETUNIT and unitscan.foundUnit and UnitExists(unitscan.foundUnit) then
		TargetUnit(unitscan.foundUnit)
		return
	end
	if CAN_TARGETUNIT and unitscan.foundGuid then
		local ok = pcall(TargetUnit, unitscan.foundGuid)
		if ok then return end
	end
	if unitscan.foundTarget then
		TargetByName(unitscan.foundTarget, true)
	end
end
