-- Fixes gamepad tooltips in bags and other windows for WoW Forever.
--
-- In Gamepad UI, GameTooltip_OnShow() hides every tooltip while any managed
-- frame is open and the GamepadDisableTooltips CVar is set. That CVar is
-- global and is toggled from several places (the bag RS toggle, the gamepad
-- action bar editor, ...), so it can be left on by another window. The RS
-- toggle that should turn it back off lives in a FrameControlsManager binding
-- group that is only active while that manager has a focused frame, so RS
-- often does nothing and the tooltips stay hidden. The Professions window
-- even advertises an LS toggle whose prompted binding has no callback.
--
-- This addon never replaces Blizzard functions, so nothing gets tainted:
--
--   * While any window is open (bags, or a frame the gamepad
--     FrameControlsManager tracks), it owns GamepadDisableTooltips: it applies
--     the state you chose, and restores the previous value when all close.
--   * While a window is open (and out of combat), RS - and LS in Professions,
--     matching its footer prompt - is override-bound to this addon's own
--     toggle, so it works no matter what Blizzard's focus state is.
--   * GameTooltip OnShow/OnUpdate hooks move any tooltip whose owner is inside
--     an open window (gamepad-managed frames, UI panels, bags, menus) next to
--     that window instead of the hovered element. HUD tooltips are untouched.
--   * A post-hook on GameTooltip:SetRecipeResultItem() fills in crafted item
--     tooltips in Professions when Blizzard's call leaves them empty.

local ADDON_NAME = ...;

local TOOLTIP_CVAR = "GamepadDisableTooltips";
local TOGGLE_KEY = "PADRSTICK";
local PROFESSIONS_TOGGLE_KEY = "PADLSTICK";
local TOOLTIP_GAP = 8;
-- Minimum room (in UIParent units) left of a window before the tooltip goes right.
local MIN_LEFT_SPACE = 330;
-- Windows wider than this fraction of the screen keep the default placement.
local MAX_WINDOW_WIDTH = 0.8;

local DEFAULTS = {
	hideTooltips = false,
	anchorToWindow = true,
};

local db;
local bagFrameSet = {};
local windowsOpen = false;
local savedCVarValue;
local settingCVar = false;
local boundKeys = {};
local lastDebugRecipeID;

local eventFrame = CreateFrame("Frame");
local bindingOwner = CreateFrame("Frame");
local toggleButton = CreateFrame("Button", "BagTooltipFixToggleButton", UIParent);

local function Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99" .. ADDON_NAME .. "|r: " .. msg);
end

local function GetBagFrames()
	local frames = {};
	if ContainerFrameCombinedBags then
		table.insert(frames, ContainerFrameCombinedBags);
	end
	if ContainerFrameContainer and ContainerFrameContainer.ContainerFrames then
		for _, frame in ipairs(ContainerFrameContainer.ContainerFrames) do
			table.insert(frames, frame);
		end
	end
	return frames;
end

local function IsAnyBagShown()
	for frame in pairs(bagFrameSet) do
		if frame:IsShown() then
			return true;
		end
	end
	return false;
end

local function IsAnyWindowShown()
	local manager = GamepadMode and GamepadMode.FrameControlsManager;
	if manager and manager:GetShownFrameCount() > 0 then
		return true;
	end
	return IsAnyBagShown();
end

local function SetTooltipCVar(disabled)
	settingCVar = true;
	SetCVar(TOOLTIP_CVAR, disabled and "1" or "0");
	settingCVar = false;
end

-- Re-runs the selected button's OnEnter so its tooltip comes back right away.
local function RefreshSelectedTooltip()
	local button = SmartNavigation and SmartNavigation:GetCurrentButton();
	if button and button:IsVisible() then
		local onEnter = button:GetScript("OnEnter");
		if onEnter then
			onEnter(button);
		end
	end
end

local function UpdateBinding()
	if InCombatLockdown() then
		-- Override bindings can't change in combat; PLAYER_REGEN_ENABLED retries.
		return;
	end

	local wanted = {};
	if windowsOpen and InputUtil.IsGamepadUIEnabled() then
		wanted[TOGGLE_KEY] = true;
		if ProfessionsFrame and ProfessionsFrame:IsShown() then
			wanted[PROFESSIONS_TOGGLE_KEY] = true;
		end
	end

	for key in pairs(boundKeys) do
		if not wanted[key] then
			SetOverrideBinding(bindingOwner, true, key, nil);
			boundKeys[key] = nil;
		end
	end
	for key in pairs(wanted) do
		if not boundKeys[key] then
			SetOverrideBindingClick(bindingOwner, true, key, toggleButton:GetName());
			boundKeys[key] = true;
		end
	end
end

local function ToggleTooltips()
	if not windowsOpen then
		return;
	end

	db.hideTooltips = not db.hideTooltips;
	SetTooltipCVar(db.hideTooltips);

	if db.hideTooltips then
		GameTooltip:Hide();
	else
		RefreshSelectedTooltip();
	end
end

toggleButton:RegisterForClicks("AnyDown");
toggleButton:SetScript("OnClick", ToggleTooltips);

local function OnWindowShown()
	if not windowsOpen and IsAnyWindowShown() then
		windowsOpen = true;
		savedCVarValue = GetCVar(TOOLTIP_CVAR);
		SetTooltipCVar(db.hideTooltips);
	end
	UpdateBinding();
end

local function OnWindowHidden()
	-- Defer so switching between windows doesn't count as closing them all.
	C_Timer.After(0, function()
		if windowsOpen and not IsAnyWindowShown() then
			windowsOpen = false;
			if savedCVarValue ~= nil then
				settingCVar = true;
				SetCVar(TOOLTIP_CVAR, savedCVarValue);
				settingCVar = false;
				savedCVarValue = nil;
			end
		end
		UpdateBinding();
	end);
end

local function IsWindow(frame)
	if bagFrameSet[frame] then
		return true;
	end

	local manager = GamepadMode and GamepadMode.FrameControlsManager;
	if manager and manager.shownFrames and tContains(manager.shownFrames, frame) then
		return true;
	end

	local name = frame:GetName();
	return name ~= nil and (UIPanelWindows[name] ~= nil or tContains(UISpecialFrames, name));
end

-- Walks up from the tooltip owner to the innermost open window containing it.
-- HUD elements (action bars, unit frames, ...) aren't windows and return nil.
local function FindWindow(owner)
	local frame = owner;
	while frame and frame ~= UIParent do
		if frame.IsVisible and frame:IsVisible() and IsWindow(frame) then
			return frame;
		end
		frame = frame:GetParent();
	end
end

-- Returns the frames to anchor to on the left and right side, and the left
-- edge in screen pixels. Open bags are treated as one window.
local function GetWindowBounds(window)
	if not bagFrameSet[window] then
		return window, window, window:GetLeft() * window:GetEffectiveScale();
	end

	local leftFrame, rightFrame, minLeft, maxRight;
	for frame in pairs(bagFrameSet) do
		if frame:IsVisible() and frame:GetLeft() then
			local scale = frame:GetEffectiveScale();
			local left, right = frame:GetLeft() * scale, frame:GetRight() * scale;
			if not minLeft or left < minLeft then
				minLeft, leftFrame = left, frame;
			end
			if not maxRight or right > maxRight then
				maxRight, rightFrame = right, frame;
			end
		end
	end
	return leftFrame, rightFrame, minLeft;
end

local function GetDesiredAnchor(tooltip)
	local owner = tooltip:GetOwner();
	local window = owner and FindWindow(owner);
	if not window or not window:GetLeft() then
		return;
	end

	-- Fullscreen windows have no room beside them; keep Blizzard's placement.
	local uiScale = UIParent:GetEffectiveScale();
	if window:GetWidth() * window:GetEffectiveScale() > UIParent:GetWidth() * uiScale * MAX_WINDOW_WIDTH then
		return;
	end

	local leftFrame, rightFrame, minLeft = GetWindowBounds(window);
	if not leftFrame then
		return;
	end

	if minLeft > MIN_LEFT_SPACE * uiScale then
		return "TOPRIGHT", leftFrame, "TOPLEFT", -TOOLTIP_GAP, "ANCHOR_LEFT";
	end
	return "TOPLEFT", rightFrame, "TOPRIGHT", TOOLTIP_GAP, "ANCHOR_RIGHT";
end

-- Runs on show (before item comparison tooltips are placed, so they pick the
-- right side) and every frame after, to undo any later re-anchoring.
local function AnchorTooltipToWindow(tooltip)
	if not db or not db.anchorToWindow then
		return;
	end

	local point, relativeTo, relativePoint, x, anchorType = GetDesiredAnchor(tooltip);
	if not point then
		return;
	end

	if tooltip:GetNumPoints() == 1 then
		local curPoint, curRelativeTo, curRelativePoint, curX, curY = tooltip:GetPoint(1);
		if curPoint == point and curRelativeTo == relativeTo and curRelativePoint == relativePoint and curX == x and curY == 0 then
			return;
		end
	end

	tooltip:SetAnchorType(anchorType, 0, 0);
	tooltip:ClearAllPoints();
	tooltip:SetPoint(point, relativeTo, relativePoint, x, 0);
end

-- Professions shows crafted item tooltips with GameTooltip:SetRecipeResultItem(),
-- which can leave the tooltip empty on this client while reagent tooltips
-- (SetRecipeReagentItem / SetItemByID) work. When it does, show the item
-- from its hyperlink instead, falling back to the item ID and then the recipe.
local function FillEmptyRecipeResultTooltip(tooltip, recipeID, reagents, allocationGUID, recipeLevel, overrideQualityID)
	local worked = tooltip:IsShown() and tooltip:NumLines() > 0;
	if db and db.debug and recipeID ~= lastDebugRecipeID then
		lastDebugRecipeID = recipeID;
		Print(("SetRecipeResultItem(%s): shown=%s lines=%d"):format(tostring(recipeID), tostring(tooltip:IsShown()), tooltip:NumLines()));
	end
	if not recipeID or worked then
		return;
	end

	local outputInfo = C_TradeSkillUI.GetRecipeOutputItemData(recipeID, reagents, allocationGUID, overrideQualityID);
	if outputInfo and outputInfo.hyperlink then
		tooltip:SetHyperlink(outputInfo.hyperlink);
		return;
	end

	local schematic = C_TradeSkillUI.GetRecipeSchematic(recipeID, false, recipeLevel);
	if schematic and schematic.outputItemID then
		tooltip:SetItemByID(schematic.outputItemID);
	else
		tooltip:SetSpellByID(recipeID);
	end
end

local function InstallHooks()
	if GameTooltip.SetRecipeResultItem then
		hooksecurefunc(GameTooltip, "SetRecipeResultItem", FillEmptyRecipeResultTooltip);
	end

	for _, frame in ipairs(GetBagFrames()) do
		bagFrameSet[frame] = true;
		frame:HookScript("OnShow", OnWindowShown);
		frame:HookScript("OnHide", OnWindowHidden);
	end

	-- Every other gamepad-managed window (Professions, character, menus, ...).
	local manager = GamepadMode and GamepadMode.FrameControlsManager;
	if manager then
		hooksecurefunc(manager, "FrameShown", OnWindowShown);
		hooksecurefunc(manager, "FrameHidden", OnWindowHidden);
	end
	GameTooltip:HookScript("OnShow", AnchorTooltipToWindow);
	GameTooltip:HookScript("OnUpdate", AnchorTooltipToWindow);
end

local function HandleSlashCommand(msg)
	msg = strtrim(msg or ""):lower();
	if msg == "anchor" then
		db.anchorToWindow = not db.anchorToWindow;
		Print("Tooltips next to their window: " .. (db.anchorToWindow and "on" or "off"));
	elseif msg == "debug" then
		db.debug = not db.debug;
		lastDebugRecipeID = nil;
		Print("Debug output: " .. (db.debug and "on" or "off"));
	elseif msg == "show" then
		db.hideTooltips = false;
		if windowsOpen then
			SetTooltipCVar(false);
			RefreshSelectedTooltip();
		end
		Print("Tooltips in windows turned back on.");
	else
		Print("RS in windows (and LS in Professions) toggles tooltips (currently " .. (db.hideTooltips and "hidden" or "shown") .. ").");
		Print("/btf anchor - toggle showing tooltips next to their window (currently " .. (db.anchorToWindow and "on" or "off") .. ")");
		Print("/btf show - force tooltips in windows back on");
	end
end

eventFrame:RegisterEvent("ADDON_LOADED");
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED");
eventFrame:RegisterEvent("CVAR_UPDATE");
eventFrame:SetScript("OnEvent", function(self, event, ...)
	if event == "ADDON_LOADED" then
		if ... ~= ADDON_NAME then
			return;
		end
		self:UnregisterEvent("ADDON_LOADED");

		BagTooltipFixDB = BagTooltipFixDB or {};
		db = BagTooltipFixDB;
		db.bagHeaderRow = nil; -- Setting from the removed bag layout feature.
		for key, value in pairs(DEFAULTS) do
			if db[key] == nil then
				db[key] = value;
			end
		end

		InstallHooks();
		if IsAnyWindowShown() then
			OnWindowShown();
		end

		SLASH_BAGTOOLTIPFIX1 = "/btf";
		SlashCmdList.BAGTOOLTIPFIX = HandleSlashCommand;
	elseif event == "PLAYER_REGEN_ENABLED" then
		UpdateBinding();
	elseif event == "CVAR_UPDATE" then
		local cvarName = ...;
		-- If Blizzard's own toggle fired while a window is open, adopt its choice.
		if cvarName == TOOLTIP_CVAR and windowsOpen and not settingCVar then
			db.hideTooltips = GetCVarBool(TOOLTIP_CVAR);
		end
	end
end);
