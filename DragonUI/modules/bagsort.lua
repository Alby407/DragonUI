-- Copyright (c) 2026 NeticSoul. Licensed under the MIT License; see LICENSE.

local addon = select(2, ...)
local L = addon.L

local function T(key, fallback)
    return (L and L[key]) or fallback or key
end

-- ============================================================================
-- BAG SORT MODULE FOR DRAGONUI
-- Sorts items in bags and bank by type, rarity, level, name.
-- Adds sort buttons to both Bagster frames and vanilla bag/bank frames.
-- ============================================================================

-- Module state tracking
local BagSortModule = {
    initialized = false,
    applied = false,
    originalStates = {},
    registeredEvents = {},
    hooks = {},
    frames = {}
}

-- Register with ModuleRegistry (if available)
if addon.RegisterModule then
    addon:RegisterModule("bagsort", BagSortModule,
        T("Bag Sort", "Bag Sort"),
        T("Sort bags and bank items with buttons", "Sort bags and bank items with buttons"),
        { lifecyclePrefix = "BagSort" })
end

-- ============================================================================
-- CONFIGURATION FUNCTIONS
-- ============================================================================

local function GetModuleConfig()
    return addon:GetModuleConfig("bagsort")
end

local function IsModuleEnabled()
    return addon:IsModuleEnabled("bagsort")
end

local function IsBankFillFromBagsEnabled()
    local cfg = GetModuleConfig()
    if not cfg or cfg.bank_fill_from_bags == nil then
        return true
    end
    return cfg.bank_fill_from_bags
end

local function IsBagsterEnabled()
    return addon:IsModuleEnabled("bagster")
end

-- Cached after the first check since addons can't load/unload mid-session.
local bagnonLoadedCache
local function IsBagnonLoaded()
    if bagnonLoadedCache == nil then
        bagnonLoadedCache = ((IsAddOnLoaded and IsAddOnLoaded("Bagnon")) or _G.Bagnon ~= nil) and true or false
    end
    return bagnonLoadedCache
end

-- True only during an active guild bank sort; doesn't affect bag/bank sorting.
local guildBankSortActive = false
local GUILDBANK_MOVE_THROTTLE = 0.4
-- 0.15s default: 3.3.5a (private) realms need time to release item locks
-- and to replicate bag updates. 0.03 was too fast and produced false
-- "Sort interrupted" aborts with a visually empty cursor.
local DEFAULT_SORT_MOVE_INTERVAL = 0.15
local MIN_SORT_MOVE_INTERVAL = 0.08
-- How long a cursor mismatch is tolerated before treating it as a real
-- external interruption. Covers the 1-2 frames where CursorHasItem() is
-- already set but GetCursorInfo() has no link yet (and vice versa).
local CURSOR_MISMATCH_TOLERANCE = 0.6

local function GetSortMoveInterval()
    local cfg = GetModuleConfig()
    local interval = cfg and tonumber(cfg.move_interval) or DEFAULT_SORT_MOVE_INTERVAL

    -- 0.05 and 0.03 were old defaults that proved too fast (false
    -- "item on cursor" aborts). Migrate those defaults to the safer
    -- interval while preserving any custom value.
    if cfg and (interval == 0.05 or interval == 0.03) then
        interval = DEFAULT_SORT_MOVE_INTERVAL
        cfg.move_interval = interval
    end

    if guildBankSortActive and interval < GUILDBANK_MOVE_THROTTLE then
        interval = GUILDBANK_MOVE_THROTTLE
    end
    if interval < MIN_SORT_MOVE_INTERVAL then return MIN_SORT_MOVE_INTERVAL end
    if interval > 0.5 then return 0.5 end
    return interval
end

local DEFAULT_LOCK_HOTKEY = "ALT_LEFT"
local LOCK_HOTKEY_MAP = {
    ALT_LEFT = { modifier = "ALT", button = "LeftButton" },
    CTRL_LEFT = { modifier = "CTRL", button = "LeftButton" },
    SHIFT_LEFT = { modifier = "SHIFT", button = "LeftButton" },
    ALT_RIGHT = { modifier = "ALT", button = "RightButton" },
    CTRL_RIGHT = { modifier = "CTRL", button = "RightButton" },
    SHIFT_RIGHT = { modifier = "SHIFT", button = "RightButton" },
    ALT_MIDDLE = { modifier = "ALT", button = "MiddleButton" },
    CTRL_MIDDLE = { modifier = "CTRL", button = "MiddleButton" },
    SHIFT_MIDDLE = { modifier = "SHIFT", button = "MiddleButton" },
}

local function NormalizeLockHotkey(value)
    if type(value) ~= "string" then
        return DEFAULT_LOCK_HOTKEY
    end

    local normalized = string.upper(value)
    if LOCK_HOTKEY_MAP[normalized] then
        return normalized
    end

    return DEFAULT_LOCK_HOTKEY
end

local function GetConfiguredLockHotkey()
    local cfg = GetModuleConfig()
    local hotkey = NormalizeLockHotkey(cfg and cfg.lock_hotkey)
    if cfg and cfg.lock_hotkey ~= hotkey then
        cfg.lock_hotkey = hotkey
    end
    return hotkey
end

local function GetLocalizedModifierName(modifier)
    if modifier == "ALT" then
        return T("Alt", "Alt")
    elseif modifier == "CTRL" then
        return T("Ctrl", "Ctrl")
    end
    return T("Shift", "Shift")
end

local function GetLocalizedMouseButtonName(button)
    if button == "LeftButton" then
        return T("Left Click", "Left Click")
    elseif button == "RightButton" then
        return T("Right Click", "Right Click")
    end
    return T("Middle Click", "Middle Click")
end

local function GetLockHotkeyLabel()
    local hotkey = GetConfiguredLockHotkey()
    local bindData = LOCK_HOTKEY_MAP[hotkey] or LOCK_HOTKEY_MAP[DEFAULT_LOCK_HOTKEY]
    return string.format("%s + %s", GetLocalizedModifierName(bindData.modifier), GetLocalizedMouseButtonName(bindData.button))
end

local function IsLockHotkeyPressed(mouseButton)
    local hotkey = GetConfiguredLockHotkey()
    local bindData = LOCK_HOTKEY_MAP[hotkey] or LOCK_HOTKEY_MAP[DEFAULT_LOCK_HOTKEY]
    if mouseButton ~= bindData.button then
        return false
    end

    local altDown = IsAltKeyDown and IsAltKeyDown()
    local ctrlDown = IsControlKeyDown and IsControlKeyDown()
    local shiftDown = IsShiftKeyDown and IsShiftKeyDown()

    if bindData.modifier == "ALT" then
        return altDown and not ctrlDown and not shiftDown
    elseif bindData.modifier == "CTRL" then
        return ctrlDown and not altDown and not shiftDown
    end

    return shiftDown and not altDown and not ctrlDown
end

local function GetBagnonFrame(frameType)
    if not IsBagnonLoaded() then return nil end

    local names
    if frameType == "bank" then
        names = { "BagnonFramebank", "BagnonBankFrame", "BagnonFrameBank", "BagnonFrame2" }
    elseif frameType == "guildbank" then
        names = { "BagnonFrameguildbank", "BagnonGuildBankFrame", "BagnonFrameGuildBank" }
    else
        names = { "BagnonFrameinventory", "BagnonInventoryFrame", "BagnonFrameInventory", "BagnonFrame1" }
    end

    for _, name in ipairs(names) do
        local frame = _G[name]
        if frame then
            return frame
        end
    end

    local bagnon = _G.Bagnon
    if bagnon and type(bagnon) == "table" then
        if bagnon.GetFrame then
            local frame = bagnon:GetFrame(frameType)
            if frame then
                return frame
            end
        end

        local frames = bagnon.frames or bagnon.Frames
        if frames then
            return frames[frameType] or frames[string.upper(frameType)] or frames[frameType == "bank" and 2 or 1]
        end
    end

    return nil
end

-- ============================================================================
-- SORTING ENGINE
-- ============================================================================

-- Bag group definitions
local PLAYER_BAGS = {}
for i = 0, NUM_BAG_SLOTS do
    tinsert(PLAYER_BAGS, i)
end
tinsert(PLAYER_BAGS, KEYRING_CONTAINER)

local BANK_BAGS = { BANK_CONTAINER }
for i = NUM_BAG_SLOTS + 1, NUM_BAG_SLOTS + NUM_BANKBAGSLOTS do
    tinsert(BANK_BAGS, i)
end

local ALL_BAGS = { BANK_CONTAINER }
for i = 0, NUM_BAG_SLOTS + NUM_BANKBAGSLOTS do
    tinsert(ALL_BAGS, i)
end
tinsert(ALL_BAGS, KEYRING_CONTAINER)

-- Internal caches
local bag_ids = {}
local bag_stacks = {}
local bag_maxstacks = {}
local item_cache = {}  -- keyed by itemID, stores GetItemInfo results
local moves = {}
local running = false
local bank_open = false
local guild_bank_open = false
local guildBankTabHookInstalled = false
local clickHooksInstalled = false
local hookedSlotButtons = {}
local lockVisualFrame
local bagnonSlotScanRequested = false
local bagnonSlotScanPasses = 0
local bagnonIntegrationHooked = false
local bagnonFrameHooksInstalled = false
local bagnonSortingHooked = false
local bagnonMoveHooked = false
local bagnonOriginalGetSpaces
local bagnonOriginalMove

-- Forward declarations
local StopSorting
local UpdateButtonVisibility

-- Encoding helpers
local function encode_bagslot(bag, slot) return (bag * 100) + slot end
local function decode_bagslot(int) return math.floor(int / 100), int % 100 end
local function encode_move(source, target) return (source * 10000) + target end
local function decode_move(move)
    local s = math.floor(move / 10000)
    local t = move % 10000
    s = (t > 9000) and (s + 1) or s
    t = (t > 9000) and (t - 10000) or t
    return s, t
end
local function link_to_id(link)
    return link and tonumber(string.match(link, "item:(%d+)"))
end

local function GetLockedSlotsTable()
    local cfg = GetModuleConfig()
    if not cfg then return nil end
    if type(cfg.lockedSlots) ~= "table" then
        cfg.lockedSlots = {}
    end
    return cfg.lockedSlots
end

local function MakeSlotKey(bag, slot)
    return tostring(bag) .. ":" .. tostring(slot)
end

local function IsSlotLocked(bag, slot)
    local locks = GetLockedSlotsTable()
    if not locks then return false end
    return locks[MakeSlotKey(bag, slot)] == true
end

local function SetSlotLocked(bag, slot, locked)
    local locks = GetLockedSlotsTable()
    if not locks then return false end
    local key = MakeSlotKey(bag, slot)
    if locked then
        locks[key] = true
    else
        locks[key] = nil
    end
    return true
end

local GetBagSlotFromButton

-- Guild bank item slots use `.tab` instead of a bag id; not a real bag/bank slot.
local function IsBagnonGuildBankSlot(widget)
    return widget.tab ~= nil and not (widget.GetBag or widget.GetBagID or widget.bag or widget.bagID or widget.bagId)
end

-- Bagnon's per-bag toggle icons; GetID() is a bag index, not a slot number.
local function IsBagnonBagToggleButton(widget)
    return type(widget.ToggleSlot) == "function" and type(widget.CanToggleSlot) == "function"
end

-- Lock icon texture, sized 12x12 and anchored to the slot's top-right corner.
local LOCK_MARKER_TEXTURE = "Interface\\AddOns\\DragonUI\\Textures\\UI\\BagSortLock"
local LOCK_MARKER_SIZE = 12
local LOCK_MARKER_OFFSET_X = -1
local LOCK_MARKER_OFFSET_Y = -1
local DEFAULT_LOCK_MARKER_COLOR = { 0.15, 0.80, 1.00, 0.95 }

-- Icon art is plain white so it can be tinted (Bags > Bag Sort > Lock Icon Color).
local function GetLockMarkerColor()
    local cfg = GetModuleConfig()
    local c = cfg and cfg.lock_color
    if type(c) == "table" and type(c[1]) == "number" and type(c[2]) == "number" and type(c[3]) == "number" then
        return c[1], c[2], c[3], type(c[4]) == "number" and c[4] or 1
    end
    return DEFAULT_LOCK_MARKER_COLOR[1], DEFAULT_LOCK_MARKER_COLOR[2], DEFAULT_LOCK_MARKER_COLOR[3], DEFAULT_LOCK_MARKER_COLOR[4]
end

local function EnsureLockMarker(button)
    if not button or button._dragonUISortLockMarker then return end
    -- No CreateTexture sub-level param on this client; last-created wins draw order.
    local marker = button:CreateTexture(nil, "OVERLAY")
    marker:SetTexture(LOCK_MARKER_TEXTURE)
    marker:SetSize(LOCK_MARKER_SIZE, LOCK_MARKER_SIZE)
    marker:ClearAllPoints()
    -- Top-right corner keeps it clear of the stack-count text (bottom-right).
    marker:SetPoint("TOPRIGHT", button, "TOPRIGHT", LOCK_MARKER_OFFSET_X, LOCK_MARKER_OFFSET_Y)
    marker:Hide()
    button._dragonUISortLockMarker = marker
end

local function UpdateButtonLockMarker(button)
    if not button then return end
    EnsureLockMarker(button)

    local marker = button._dragonUISortLockMarker
    if not marker then return end

    local bag, slot = GetBagSlotFromButton(button)
    if bag and slot and IsSlotLocked(bag, slot) then
        marker:SetVertexColor(GetLockMarkerColor())
        marker:Show()
    else
        marker:Hide()
    end
end

local function RefreshAllLockMarkers()
    for button, _ in pairs(hookedSlotButtons) do
        UpdateButtonLockMarker(button)
    end
end

local function HasLockedSlots()
    local locks = GetLockedSlotsTable()
    return locks ~= nil and next(locks) ~= nil
end

local BAGSTER_FRAME_COUNT = 3
local BAGNON_SLOT_FRAMES = { "inventory", "bank" }

-- Markers only render on visible slot buttons, and each button re-syncs its own marker on OnShow.
local function IsAnyBagUIVisible()
    if BankFrame and BankFrame:IsShown() then
        return true
    end
    for i = 1, NUM_CONTAINER_FRAMES do
        local frame = _G["ContainerFrame" .. i]
        if frame and frame:IsShown() then
            return true
        end
    end
    for i = 1, BAGSTER_FRAME_COUNT do
        local frame = _G["DragonUI_BagsterFrame" .. i]
        if frame and frame:IsShown() then
            return true
        end
    end
    for _, frameType in ipairs(BAGNON_SLOT_FRAMES) do
        local frame = GetBagnonFrame(frameType)
        if frame and frame.IsShown and frame:IsShown() then
            return true
        end
    end
    return false
end

local function ToggleSlotLockByBagSlot(bag, slot)
    local newState = not IsSlotLocked(bag, slot)
    SetSlotLocked(bag, slot, newState)
    if newState then
        DEFAULT_CHAT_FRAME:AddMessage(string.format("|cff00cc66DragonUI:|r " .. T("Slot locked (bag %d, slot %d).", "Slot locked (bag %d, slot %d)."), bag, slot), 0.4, 1, 0.4)
    else
        DEFAULT_CHAT_FRAME:AddMessage(string.format("|cff00cc66DragonUI:|r " .. T("Slot unlocked (bag %d, slot %d).", "Slot unlocked (bag %d, slot %d)."), bag, slot), 0.4, 1, 0.4)
    end

    RefreshAllLockMarkers()
end

GetBagSlotFromButton = function(btn)
    if not btn then return nil, nil end

    local bag, slot

    -- Neither is a real slot; falling through would misread it as bag 0.
    if IsBagnonGuildBankSlot(btn) or IsBagnonBagToggleButton(btn) then
        return nil, nil
    end

    -- Bagster item buttons expose GetBag/GetID.
    if btn.GetBag and btn.GetID then
        bag = btn:GetBag()
        slot = btn:GetID()
    end

    -- Bagnon variants commonly expose bag/slot as fields or GetBagID/GetSlotID methods.
    if (not bag) and btn.GetBagID and btn.GetSlotID then
        bag = btn:GetBagID()
        slot = btn:GetSlotID()
    end

    if (not bag) then
        bag = btn.bag or btn.bagID or btn.bagId or btn:GetParent() and (btn:GetParent().bag or btn:GetParent().bagID or btn:GetParent().bagId)
        slot = btn.slot or btn.slotID or btn.slotId or btn.id
    end

    -- Vanilla bank generic slots (BankFrameItem1..N).
    -- Must be checked BEFORE the parent-frame path: BankFrame:GetID() returns 0
    -- (truthy in Lua), which would cause the parent check to match and store the
    -- lock under bag=0 (backpack) instead of BANK_CONTAINER.
    if (not bag) and btn.GetName then
        local name = btn:GetName()
        if name then
            local bankSlot = tonumber(string.match(name, "^BankFrameItem(%d+)$"))
            if bankSlot then
                bag = BANK_CONTAINER
                slot = bankSlot
            end
        end
    end

    -- Vanilla container item buttons: bag id comes from parent frame.
    if (not bag) and btn.GetParent and btn.GetID then
        local parent = btn:GetParent()
        if parent and parent.GetID then
            bag = parent:GetID()
            slot = btn:GetID()
        end
    end

    if bag == nil or slot == nil then return nil, nil end
    bag = tonumber(bag)
    slot = tonumber(slot)
    if bag == nil or slot == nil then return nil, nil end
    if type(slot) ~= "number" or slot < 1 then return nil, nil end
    return bag, slot
end

local function GetHoveredBagSlot()
    if not GameTooltip or not GameTooltip:IsShown() then return nil, nil end
    local owner = GameTooltip:GetOwner()
    if not owner then return nil, nil end

    local bag, slot

    -- Neither is a real slot; falling through would misread it as bag 0.
    if IsBagnonGuildBankSlot(owner) or IsBagnonBagToggleButton(owner) then
        return nil, nil
    end

    -- Bagster item buttons expose GetBag/GetID.
    if owner.GetBag and owner.GetID then
        bag = owner:GetBag()
        slot = owner:GetID()
    end

    if (not bag) and owner.GetBagID and owner.GetSlotID then
        bag = owner:GetBagID()
        slot = owner:GetSlotID()
    end

    if (not bag) then
        bag = owner.bag or owner.bagID or owner.bagId or owner:GetParent() and (owner:GetParent().bag or owner:GetParent().bagID or owner:GetParent().bagId)
        slot = owner.slot or owner.slotID or owner.slotId or owner.id
    end

    -- Vanilla bank generic slots (BankFrameItem1..N).
    -- Must be checked BEFORE the parent-frame path for the same reason as
    -- GetBagSlotFromButton: BankFrame:GetID() returns 0 which is truthy.
    if (not bag) and owner.GetName then
        local name = owner:GetName()
        if name then
            local bankSlot = tonumber(string.match(name, "^BankFrameItem(%d+)$"))
            if bankSlot then
                bag = BANK_CONTAINER
                slot = bankSlot
            end
        end
    end

    -- Vanilla container item buttons: bag id is on parent frame.
    if (not bag) and owner.GetParent and owner.GetID then
        local parent = owner:GetParent()
        if parent and parent.GetID then
            bag = parent:GetID()
            slot = owner:GetID()
        end
    end

    if bag == nil or slot == nil then return nil, nil end
    bag = tonumber(bag)
    slot = tonumber(slot)
    if bag == nil or slot == nil then return nil, nil end
    if type(slot) ~= "number" or slot < 1 then return nil, nil end
    return bag, slot
end

local function ToggleHoveredSlotLock()
    local bag, slot = GetHoveredBagSlot()
    if not bag or not slot then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00cc66DragonUI:|r " .. T("Hover an item or slot, then type /sortlock.", "Hover an item or slot, then type /sortlock."), 1, 0.8, 0)
        return
    end

    ToggleSlotLockByBagSlot(bag, slot)
end

-- ============================================================================
-- BAGNON COMPATIBILITY: NATIVE SORT INTEGRATION
-- ============================================================================
-- Hooks Bagnon's own Sorting.GetSpaces so it respects DragonUI's locked slots.

-- Min delay between moves from Bagnon's own sort (avoids flooding high-latency realms).
local BAGNON_MOVE_THROTTLE = 0.15

local function GetBagnonFrameKind(itemFrame)
    if type(itemFrame) ~= "table" then return "unknown" end
    if type(itemFrame.GetVisibleBags) == "function" and type(itemFrame.GetBagSize) == "function" then
        return "bags" -- inventory or personal bank; both share this API
    end
    if type(itemFrame.GetCurrentTab) == "function" then
        return "guildbank"
    end
    return "unknown"
end

local function GetBagnonSpaces(sortModule, originalGetSpaces, ...)
    if type(originalGetSpaces) ~= "function" then return {} end

    local itemFrame = sortModule and sortModule.itemFrame
    if GetBagnonFrameKind(itemFrame) == "guildbank" then
        -- Not supported: skip the real GetSpaces entirely.
        return {}
    end

    local ok, spaces = pcall(originalGetSpaces, sortModule, ...)
    if not ok then
        -- Fail gracefully instead of propagating a Lua error to the user.
        return {}
    end
    if type(spaces) ~= "table" then
        return spaces
    end

    if not BagSortModule.applied then
        return spaces
    end

    local filteredSpaces = {}
    for _, space in ipairs(spaces) do
        if not (space and space.bag and space.slot and IsSlotLocked(space.bag, space.slot)) then
            if space then
                space.index = #filteredSpaces
                if space.item then
                    space.item.space = space
                end
                tinsert(filteredSpaces, space)
            end
        end
    end

    return filteredSpaces
end

local function InstallAltClickHooks()
    if clickHooksInstalled then return end
    clickHooksInstalled = true

    local function HookSlotButton(button)
        if not button or button._dragonUISortLockHooked then return end

        local objectType = button.GetObjectType and button:GetObjectType()
        if objectType ~= "Button" and objectType ~= "CheckButton" then
            return
        end

        button._dragonUISortLockHooked = true
        hookedSlotButtons[button] = true
        EnsureLockMarker(button)

        button:HookScript("OnShow", function(self)
            UpdateButtonLockMarker(self)
        end)

        button:HookScript("OnHide", function(self)
            if self._dragonUISortLockMarker then
                self._dragonUISortLockMarker:Hide()
            end
        end)

        local function HandleAltClick(self, mouseButton)
            if not BagSortModule.applied then return end
            if not IsLockHotkeyPressed(mouseButton) then return end
            local now = GetTime and GetTime() or 0
            if self._dragonUISortLockLastClick and now > 0 and (now - self._dragonUISortLockLastClick) < 0.15 then
                return
            end
            self._dragonUISortLockLastClick = now

            local bag, slot = GetBagSlotFromButton(self)
            if not bag or not slot then return end

            ToggleSlotLockByBagSlot(bag, slot)

            -- Cancel pickup side effect from default click handlers.
            if CursorHasItem() then
                PickupContainerItem(bag, slot)
                if CursorHasItem() then
                    ClearCursor()
                end
            end
        end

        button:HookScript("OnClick", HandleAltClick)
        button:HookScript("PostClick", HandleAltClick)
        button:HookScript("OnMouseUp", HandleAltClick)

        UpdateButtonLockMarker(button)
    end

    local function HookKnownSlotButtons()
        -- Vanilla container bag items
        for frameIndex = 1, NUM_CONTAINER_FRAMES do
            for slot = 1, 36 do
                local btn = _G["ContainerFrame" .. frameIndex .. "Item" .. slot]
                if btn then HookSlotButton(btn) end
            end
        end

        -- Vanilla bank main container slots
        for slot = 1, (NUM_BANKGENERIC_SLOTS or 28) do
            local btn = _G["BankFrameItem" .. slot]
            if btn then HookSlotButton(btn) end
        end

        -- Bagster item slots
        for idx = 1, 400 do
            local btn = _G["DragonUI_BagsterItem" .. idx]
            if btn then HookSlotButton(btn) end
        end
    end

    local function HookBagnonSlotButtons()
        local function HookBagnonItemFrame(itemFrame)
            if type(itemFrame) ~= "table" then return end

            -- Guild bank slots may reach here too; GetBagSlotFromButton() rejects them safely.
            if type(itemFrame.GetAllItemSlots) == "function" then
                for _, itemSlot in itemFrame:GetAllItemSlots() do
                    if itemSlot then
                        HookSlotButton(itemSlot)
                    end
                end
            elseif type(itemFrame.itemSlots) == "table" then
                for _, itemSlot in pairs(itemFrame.itemSlots) do
                    if itemSlot then
                        HookSlotButton(itemSlot)
                    end
                end
            end
        end

        local function HookBagnonFrameObject(frame)
            if type(frame) ~= "table" then return end
            if type(frame.GetItemFrame) == "function" then
                HookBagnonItemFrame(frame:GetItemFrame())
            end
            HookBagnonItemFrame(frame.itemFrame)
        end

        local function HookFrameChildren(frame, depth)
            if not frame or depth > 5 or not frame.GetChildren then return end
            local children = { frame:GetChildren() }
            for _, child in ipairs(children) do
                if GetBagSlotFromButton(child) then
                    HookSlotButton(child)
                end
                HookFrameChildren(child, depth + 1)
            end
        end

        local inventoryFrame = GetBagnonFrame("inventory")
        local bankFrame = GetBagnonFrame("bank")
        HookBagnonFrameObject(inventoryFrame)
        HookBagnonFrameObject(bankFrame)
        HookFrameChildren(inventoryFrame, 1)
        HookFrameChildren(bankFrame, 1)

        local bagnon = _G.Bagnon
        local frames = bagnon and (bagnon.frames or bagnon.Frames)
        if type(frames) == "table" then
            for _, frame in pairs(frames) do
                HookBagnonFrameObject(frame)
            end
        end
    end

    local function InstallBagnonIntegrationHooks()
        local bagnon = _G.Bagnon
        if not bagnon then return end

        if not bagnonSortingHooked and bagnon.Sorting and type(bagnon.Sorting.GetSpaces) == "function" then
            bagnonSortingHooked = true
            bagnonOriginalGetSpaces = bagnon.Sorting.GetSpaces
            bagnon.Sorting.GetSpaces = function(sortModule, ...)
                return GetBagnonSpaces(sortModule, bagnonOriginalGetSpaces, ...)
            end
        end

        -- Refusing a move here just leaves it unsorted; Bagnon retries shortly after.
        if not bagnonMoveHooked and bagnon.Sorting and type(bagnon.Sorting.Move) == "function" then
            bagnonMoveHooked = true
            bagnonOriginalMove = bagnon.Sorting.Move
            local lastBagnonMoveTime = 0
            bagnon.Sorting.Move = function(sortModule, ...)
                if not BagSortModule.applied then
                    return bagnonOriginalMove(sortModule, ...)
                end
                local now = GetTime and GetTime() or 0
                if lastBagnonMoveTime > 0 and (now - lastBagnonMoveTime) < BAGNON_MOVE_THROTTLE then
                    return false
                end
                lastBagnonMoveTime = now
                return bagnonOriginalMove(sortModule, ...)
            end
        end

        if not bagnonFrameHooksInstalled then
            bagnonFrameHooksInstalled = true

            local function RefreshBagnonIntegration()
                if not BagSortModule.applied then return end
                if addon.After then
                    addon:After(0.1, function()
                        if BagSortModule.applied then
                            UpdateButtonVisibility()
                            HookBagnonSlotButtons()
                        end
                    end)
                else
                    UpdateButtonVisibility()
                    HookBagnonSlotButtons()
                end
            end

            if type(bagnon.ShowFrame) == "function" then
                hooksecurefunc(bagnon, "ShowFrame", RefreshBagnonIntegration)
            end
            if type(bagnon.CreateFrame) == "function" then
                hooksecurefunc(bagnon, "CreateFrame", RefreshBagnonIntegration)
            end
        end

        if not bagnonIntegrationHooked then
            if type(bagnon.ItemFrame) == "table" and type(bagnon.ItemFrame.AddItemSlot) == "function" then
                bagnonIntegrationHooked = true
                hooksecurefunc(bagnon.ItemFrame, "AddItemSlot", function(itemFrame, bag, slot)
                    if not BagSortModule.applied or type(itemFrame) ~= "table" or type(itemFrame.GetItemSlot) ~= "function" then return end
                    local itemSlot = itemFrame:GetItemSlot(bag, slot)
                    if itemSlot then
                        HookSlotButton(itemSlot)
                        UpdateButtonLockMarker(itemSlot)
                    end
                end)
            elseif type(bagnon.Frame) == "table" and type(bagnon.Frame.CreateItemFrame) == "function" then
                bagnonIntegrationHooked = true
                hooksecurefunc(bagnon.Frame, "CreateItemFrame", function(frame)
                    if not BagSortModule.applied then return end
                    if type(frame) == "table" and type(frame.GetItemFrame) == "function" then
                        local itemFrame = frame:GetItemFrame()
                        if itemFrame then
                            HookBagnonSlotButtons()
                        end
                    end
                end)
            end
        end
    end

    local function RequestBagnonSlotScan()
        bagnonSlotScanRequested = true
        bagnonSlotScanPasses = 0
    end

    BagSortModule.RequestBagnonSlotScan = RequestBagnonSlotScan
    BagSortModule.ScanBagnonSlots = HookBagnonSlotButtons

    InstallBagnonIntegrationHooks()
    HookKnownSlotButtons()
    HookBagnonSlotButtons()
    RefreshAllLockMarkers()

    lockVisualFrame = CreateFrame("Frame")
    local elapsed = 0
    local bagnonElapsed = 0
    lockVisualFrame:SetScript("OnUpdate", function(self, dt)
        if not BagSortModule.applied then return end
        elapsed = elapsed + dt
        if bagnonSlotScanRequested then
            bagnonElapsed = bagnonElapsed + dt
            if bagnonElapsed >= 1 then
                bagnonElapsed = 0
                HookBagnonSlotButtons()
                bagnonSlotScanPasses = bagnonSlotScanPasses + 1
                if bagnonSlotScanPasses >= 4 then
                    bagnonSlotScanRequested = false
                end
            end
        end
        if elapsed < 0.4 then return end
        elapsed = 0
        InstallBagnonIntegrationHooks()
        -- Closed bags show no marker and create no slot button, so there is nothing to find.
        if not IsAnyBagUIVisible() then return end
        HookKnownSlotButtons()
        if HasLockedSlots() then
            RefreshAllLockMarkers()
        end
    end)
end

local function ClearAllLockedSlots()
    local locks = GetLockedSlotsTable()
    if not locks then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00cc66DragonUI:|r " .. T("Could not clear locks (config not ready).", "Could not clear locks (config not ready)."), 1, 0.4, 0.4)
        return
    end
    wipe(locks)
    DEFAULT_CHAT_FRAME:AddMessage("|cff00cc66DragonUI:|r " .. T("Cleared all sort-locked slots.", "Cleared all sort-locked slots."), 0.4, 1, 0.4)
    RefreshAllLockMarkers()
end



-- ============================================================================
-- GUILD BANK COMPATIBILITY: SYNTHETIC BAG IDS
-- ============================================================================
-- Guild bank tab N is treated as bag id (GUILDBANK_TAB_OFFSET + N), reusing
-- the whole scan/compress/sort/move pipeline instead of duplicating it.
local GUILDBANK_TAB_OFFSET = 50

local function IsGuildBankBag(bag)
    return bag > GUILDBANK_TAB_OFFSET
end

-- Returns 0 for tabs without full view+deposit+withdraw access.
local function GetGuildBankTabSlotCount(tab)
    if type(GetGuildBankTabInfo) ~= "function" then return 0 end
    local name, _, canView, canDeposit, numWithdrawals = GetGuildBankTabInfo(tab)
    -- numWithdrawals is negative when withdrawals are unlimited for this rank.
    if name and canView and canDeposit and numWithdrawals ~= 0 then
        return 98 -- MAX_GUILDBANK_SLOTS_PER_TAB; no reliable global constant for this in 3.3.5a
    end
    return 0
end

local function BagGetItemLink(bag, slot)
    if IsGuildBankBag(bag) then
        return GetGuildBankItemLink(bag - GUILDBANK_TAB_OFFSET, slot)
    end
    return GetContainerItemLink(bag, slot)
end

local function BagGetItemInfo(bag, slot)
    if IsGuildBankBag(bag) then
        return GetGuildBankItemInfo(bag - GUILDBANK_TAB_OFFSET, slot)
    end
    return GetContainerItemInfo(bag, slot)
end

local function BagPickupItem(bag, slot)
    if IsGuildBankBag(bag) then
        return PickupGuildBankItem(bag - GUILDBANK_TAB_OFFSET, slot)
    end
    return PickupContainerItem(bag, slot)
end

local function BagSplitItem(bag, slot, amount)
    if IsGuildBankBag(bag) then
        return SplitGuildBankItem(bag - GUILDBANK_TAB_OFFSET, slot, amount)
    end
    return SplitContainerItem(bag, slot, amount)
end

-- Bag iteration
local function IterateBags(baglist)
    local items = {}
    for _, bag in ipairs(baglist) do
        local numSlots = IsGuildBankBag(bag) and GetGuildBankTabSlotCount(bag - GUILDBANK_TAB_OFFSET) or GetContainerNumSlots(bag)
        for slot = 1, numSlots do
            tinsert(items, { bag = bag, slot = slot, bagslot = encode_bagslot(bag, slot) })
        end
    end
    local i = 0
    return function()
        i = i + 1
        if items[i] then
            return items[i].bag, items[i].slot, items[i].bagslot
        end
    end
end

-- Scan all items in given bags into cache
local function ScanBags(bags)
    for bag, slot, bagslot in IterateBags(bags) do
        local itemLink = BagGetItemLink(bag, slot)
        local itemid = link_to_id(itemLink)
        if itemid then
            bag_ids[bagslot] = itemid
            local _, count = BagGetItemInfo(bag, slot)
            bag_stacks[bagslot] = count or 0
            -- Cache GetItemInfo by itemID (not bagslot) so it's stable
            if not item_cache[itemid] then
                local name, _, rarity, level, _, itype, subType, maxStack, equipLoc = GetItemInfo(itemid)
                item_cache[itemid] = {
                    name = name or "",
                    rarity = rarity or 0,
                    level = level or 0,
                    itype = itype or "",
                    subType = subType or "",
                    maxStack = maxStack or 1,
                    equipLoc = equipLoc or "",
                }
            end
            bag_maxstacks[bagslot] = item_cache[itemid].maxStack
        end
    end
end

-- Bag family (0 = normal). Specialty bags (herb/enchant/…) sort in their own pool.
local function GetBagFamily(bag)
    if bag == BACKPACK_CONTAINER or bag == BANK_CONTAINER then
        return 0
    end
    -- Own pool (GetItemFamily 0x0100); never mix keys into normal/profession bags
    if bag == KEYRING_CONTAINER then
        return 0x0100
    end
    if IsGuildBankBag(bag) then
        return 0
    end
    local _, bagType = GetContainerNumFreeSlots(bag)
    return bagType or 0
end

-- Specialty families first, then normal (0), so profession bags never share a sort pool.
local function GroupBagsByFamily(bags)
    local groups, families = {}, {}
    for _, bag in ipairs(bags) do
        local family = GetBagFamily(bag)
        if not groups[family] then
            groups[family] = {}
            tinsert(families, family)
        end
        tinsert(groups[family], bag)
    end
    table.sort(families, function(a, b)
        if a == 0 then return false end
        if b == 0 then return true end
        return a > b
    end)
    return families, groups
end

-- Build sort order from auction item classes
local item_types, item_subtypes
local weapon_type, armor_type
local function BuildSortOrder()
    item_types = {}
    item_subtypes = {}
    local auction_types = { GetAuctionItemClasses() }
    weapon_type = auction_types[1]
    armor_type = auction_types[2]
    for i, itype in ipairs(auction_types) do
        item_types[itype] = i
        item_subtypes[itype] = {}
        for ii, istype in ipairs({ GetAuctionItemSubClasses(i) }) do
            item_subtypes[itype][istype] = ii
        end
    end
end

-- Equipment slot sort order
local EQUIP_SLOTS = {
    INVTYPE_AMMO = 0, INVTYPE_HEAD = 1, INVTYPE_NECK = 2, INVTYPE_SHOULDER = 3,
    INVTYPE_BODY = 4, INVTYPE_CHEST = 5, INVTYPE_ROBE = 5, INVTYPE_WAIST = 6,
    INVTYPE_LEGS = 7, INVTYPE_FEET = 8, INVTYPE_WRIST = 9, INVTYPE_HAND = 10,
    INVTYPE_FINGER = 11, INVTYPE_TRINKET = 12, INVTYPE_CLOAK = 13,
    INVTYPE_WEAPON = 14, INVTYPE_SHIELD = 15, INVTYPE_2HWEAPON = 16,
    INVTYPE_WEAPONMAINHAND = 18, INVTYPE_WEAPONOFFHAND = 19, INVTYPE_HOLDABLE = 20,
    INVTYPE_RANGED = 21, INVTYPE_THROWN = 22, INVTYPE_RANGEDRIGHT = 23,
    INVTYPE_RELIC = 24, INVTYPE_TABARD = 25,
}

-- Primary sort tiebreaker: level then name (uses cache, never GetItemInfo)
local function PrimeSort(a, b)
    local a_info = item_cache[bag_ids[a]]
    local b_info = item_cache[bag_ids[b]]
    local a_level = a_info and a_info.level or 0
    local b_level = b_info and b_info.level or 0
    if a_level == b_level then
        local a_name = a_info and a_info.name or ""
        local b_name = b_info and b_info.name or ""
        return a_name < b_name
    else
        return a_level > b_level
    end
end

-- Gray items are sold via the sell button, so they live at the end of the bags.
local function IsTrashItem(itemID)
    if not itemID then return false end
    local info = item_cache[itemID]
    return (info ~= nil and info.rarity == 0) or false
end

-- Main sorting comparator (uses cache, never GetItemInfo)
local function DefaultSorter(a, b)
    local a_id = bag_ids[a]
    local b_id = bag_ids[b]

    -- Empty slots to back
    if (not a_id) or (not b_id) then return a_id end

    -- Same item: sort by stack count
    if a_id == b_id then
        local a_count = bag_stacks[a]
        local b_count = bag_stacks[b]
        if a_count == b_count then
            return a < b
        else
            return a_count < b_count
        end
    end

    local a_info = item_cache[a_id]
    local b_info = item_cache[b_id]
    local a_rarity = a_info and a_info.rarity or 0
    local b_rarity = b_info and b_info.rarity or 0
    local a_type = a_info and a_info.itype or ""
    local b_type = b_info and b_info.itype or ""
    local a_subType = a_info and a_info.subType or ""
    local b_subType = b_info and b_info.subType or ""
    local a_equipLoc = a_info and a_info.equipLoc or ""
    local b_equipLoc = b_info and b_info.equipLoc or ""

    -- Junk (gray) to back
    if not (a_rarity == b_rarity) then
        if a_rarity == 0 then return false end
        if b_rarity == 0 then return true end
    end

    -- Soul shards to back
    if a_id == 6265 then return false end
    if b_id == 6265 then return true end

    -- Sort by item type
    if (item_types[a_type] or 99) == (item_types[b_type] or 99) then
        if a_rarity == b_rarity then
            if a_type == armor_type or a_type == weapon_type then
                local a_slot = EQUIP_SLOTS[a_equipLoc] or -1
                local b_slot = EQUIP_SLOTS[b_equipLoc] or -1
                if a_slot == b_slot then
                    return PrimeSort(a, b)
                else
                    return a_slot < b_slot
                end
            else
                if a_subType == b_subType then
                    return PrimeSort(a, b)
                else
                    return ((item_subtypes[a_type] or {})[a_subType] or 99) < ((item_subtypes[b_type] or {})[b_subType] or 99)
                end
            end
        else
            return a_rarity > b_rarity
        end
    else
        return (item_types[a_type] or 99) < (item_types[b_type] or 99)
    end
end

-- Update location cache after scheduling a move
local function UpdateLocation(from, to)
    if (bag_ids[from] == bag_ids[to]) and (bag_stacks[to] < bag_maxstacks[to]) then
        local stack_size = bag_maxstacks[to]
        if (bag_stacks[to] + bag_stacks[from]) > stack_size then
            bag_stacks[from] = bag_stacks[from] - (stack_size - bag_stacks[to])
            bag_stacks[to] = stack_size
        else
            bag_stacks[to] = bag_stacks[to] + bag_stacks[from]
            bag_stacks[from] = nil
            bag_ids[from] = nil
            bag_maxstacks[from] = nil
        end
    else
        bag_ids[from], bag_ids[to] = bag_ids[to], bag_ids[from]
        bag_stacks[from], bag_stacks[to] = bag_stacks[to], bag_stacks[from]
        bag_maxstacks[from], bag_maxstacks[to] = bag_maxstacks[to], bag_maxstacks[from]
    end
end

local function AddMove(source, destination)
    UpdateLocation(source, destination)
    tinsert(moves, 1, encode_move(source, destination))
end

-- Fill partial target stacks from source_bags (reverse iteration).
-- require_partial_source: same-bag compress skips full sources; cross-bag allows them.
local function StackBags(source_bags, target_bags, require_partial_source)
    local target_items = {}
    local target_slots = {}
    local source_used = {}

    for bag, slot, bagslot in IterateBags(target_bags) do
        if not IsSlotLocked(bag, slot) then
            local itemid = bag_ids[bagslot]
            if itemid and bag_stacks[bagslot] and bag_maxstacks[bagslot] and (bag_stacks[bagslot] ~= bag_maxstacks[bagslot]) then
                target_items[itemid] = (target_items[itemid] or 0) + 1
                tinsert(target_slots, bagslot)
            end
        end
    end

    local source_slots = {}
    for bag, slot, bagslot in IterateBags(source_bags) do
        if not IsSlotLocked(bag, slot) then
            tinsert(source_slots, bagslot)
        end
    end
    for si = #source_slots, 1, -1 do
        local source_slot = source_slots[si]
        local itemid = bag_ids[source_slot]
        local source_ok = itemid and target_items[itemid]
        if require_partial_source then
            source_ok = source_ok and (bag_maxstacks[source_slot] - bag_stacks[source_slot]) > 0
        end
        if source_ok then
            for ti = #target_slots, 1, -1 do
                local target_slot = target_slots[ti]
                if bag_ids[source_slot]
                    and bag_ids[target_slot] == itemid
                    and target_slot ~= source_slot
                    and not (bag_stacks[target_slot] == bag_maxstacks[target_slot])
                    and not source_used[target_slot]
                then
                    AddMove(source_slot, target_slot)
                    source_used[source_slot] = true
                    if bag_stacks[target_slot] == bag_maxstacks[target_slot] then
                        target_items[itemid] = (target_items[itemid] > 1) and (target_items[itemid] - 1) or nil
                    end
                    if bag_stacks[source_slot] == 0 then
                        target_items[itemid] = (target_items[itemid] > 1) and (target_items[itemid] - 1) or nil
                        break
                    end
                    if not target_items[itemid] then break end
                end
            end
        end
    end
end

local function CompressStacks(bags)
    StackBags(bags, bags, true)
end

local function StackBagsAcross(source_bags, target_bags)
    StackBags(source_bags, target_bags, false)
end

-- Check if a move actually needs to happen
local function ShouldActuallyMove(source, destination)
    if destination == source then return end
    if not bag_ids[source] then return end
    local sBag, sSlot = decode_bagslot(source)
    local dBag, dSlot = decode_bagslot(destination)
    if IsSlotLocked(sBag, sSlot) or IsSlotLocked(dBag, dSlot) then return end
    if bag_ids[source] == bag_ids[destination] and bag_stacks[source] == bag_stacks[destination] then return end
    return true
end

-- Update sorted array after scheduling a move
local function UpdateSorted(sorted, source, destination)
    for i, bs in pairs(sorted) do
        if bs == source then
            sorted[i] = destination
        elseif bs == destination then
            sorted[i] = source
        end
    end
end

-- Sort items in the given bags
local function SortItems(bags)
    if not item_types then BuildSortOrder() end

    -- Sort only unlocked slots; locked slots remain in-place and are never moved.
    local sources = {}
    local destinations = {}
    for bag, slot, bagslot in IterateBags(bags) do
        if not IsSlotLocked(bag, slot) then
            tinsert(sources, bagslot)
            tinsert(destinations, bagslot)
        end
    end

    table.sort(sources, DefaultSorter)

    -- Trash to the end, rest stays front: split the sorted slots into
    -- normal / empty / trash so gray items land on the last slots.
    -- Empty slots in the middle keep trash pinned last as new loot arrives.
    do
        local normalS, trashS, emptyS = {}, {}, {}
        for _, bs in ipairs(sources) do
            local id = bag_ids[bs]
            if not id then
                tinsert(emptyS, bs)
            elseif IsTrashItem(id) then
                tinsert(trashS, bs)
            else
                tinsert(normalS, bs)
            end
        end
        sources = {}
        for _, bs in ipairs(normalS) do tinsert(sources, bs) end
        for _, bs in ipairs(emptyS) do tinsert(sources, bs) end
        for _, bs in ipairs(trashS) do tinsert(sources, bs) end
    end

    -- When reverse_stack is enabled, items are placed at the end of each bag
    -- instead of the front. This leaves empty slots at the top of Bagster
    -- so new loot is immediately visible without scrolling.
    local cfg = GetModuleConfig()
    if cfg and cfg.reverse_stack then
        local reversed = {}
        for i = #destinations, 1, -1 do
            tinsert(reversed, destinations[i])
        end
        destinations = reversed
    end

    local bag_locked = {}
    local another_pass = true
    while another_pass do
        another_pass = false
        for i = 1, #destinations do
            local destination = destinations[i]
            local source = sources[i]
            if ShouldActuallyMove(source, destination) then
                if not (bag_locked[source] or bag_locked[destination]) then
                    AddMove(source, destination)
                    UpdateSorted(sources, source, destination)
                    bag_locked[source] = true
                    bag_locked[destination] = true
                else
                    another_pass = true
                end
            end
        end
        wipe(bag_locked)
    end
end

-- Compress + sort each bag family on its own (herb/enchant/… never mix with normal bags)
local function CompressAndSortBagGroups(bags)
    local families, groups = GroupBagsByFamily(bags)
    for i = 1, #families do
        local group = groups[families[i]]
        CompressStacks(group)
        SortItems(group)
    end
end

-- Move execution frame
local moveFrame = CreateFrame("Frame")
local moveTimer = 0
local sortStallTime = 0
local SORT_STALL_TIMEOUT = 8
local current_id, current_target
local current_source_bag, current_source_slot
local current_displaced = false
local current_return_attempted = false
local current_displaced_id, current_target_itemid
local current_target_count
local current_stack_size
local current_source_expected_id, current_source_expected_count
local current_source_initial_count, current_target_initial_count
local current_target_attempted = false
local current_action_wait = 0
local MOVE_UPDATE_WAIT = 1.0
local sortContext
local replanAttempts = 0
local MAX_REPLAN_ATTEMPTS = 4
local ReplanSorting

local function ResetCurrentMove()
    current_id = nil
    current_target = nil
    current_source_bag = nil
    current_source_slot = nil
    current_displaced = false
    current_return_attempted = false
    current_displaced_id = nil
    current_target_itemid = nil
    current_target_count = nil
    current_stack_size = nil
    current_source_expected_id = nil
    current_source_expected_count = nil
    current_source_initial_count = nil
    current_target_initial_count = nil
    current_target_attempted = false
    current_action_wait = 0
end
-- Transient cursor-state tolerance (see CURSOR_MISMATCH_TOLERANCE above).
local cursorMismatchTime = 0
local idleCursorTime = 0

local function CursorItemID()
    if not CursorHasItem() then return nil end
    local cursorType, _, cursorLink = GetCursorInfo()
    -- Right after a Pickup the cursor flag can be set a frame before
    -- GetCursorInfo() returns the link. Report "unknown" (false) instead
    -- of nil so callers wait instead of aborting with a false mismatch.
    if cursorLink == nil then return false end
    if cursorType ~= nil and cursorType ~= "item" then return false end
    local id = link_to_id(cursorLink)
    if id == nil then return false end
    return id
end

-- A swap is three pickups, not two: source -> cursor, target -> target
-- (displacing the old target item), then cursor -> source.  The last step
-- can need a retry while the client catches up with the bag update.
local function ReturnDisplacedItem(dt)
    if not current_displaced then return true end
    if not CursorHasItem() then
        current_displaced = false
        cursorMismatchTime = 0
        return true
    end

    local cursorID = CursorItemID()
    if cursorID == false then
        -- Cursor flag set but link not readable yet: transient, wait.
        return false
    end
    if current_displaced_id and cursorID ~= current_displaced_id then
        -- Possible external cursor change, but GetCursorInfo() can lag one
        -- frame behind CursorHasItem(). Only abort if it persists.
        cursorMismatchTime = (cursorMismatchTime or 0) + (dt or 0)
        if cursorMismatchTime < CURSOR_MISMATCH_TOLERANCE then
            return false
        end
        StopSorting("DragonUI: Sort interrupted.")
        return false
    end
    cursorMismatchTime = 0

    if not current_source_bag or not current_source_slot then
        return false
    end

    -- Do not click the source again until the first pickup has been reflected
    -- locally; otherwise a delayed update could undo the move.
    local _, _, source_locked = BagGetItemInfo(current_source_bag, current_source_slot)
    if source_locked then return false end
    if BagGetItemLink(current_source_bag, current_source_slot) then
        return false
    end

    -- Once the source is visibly empty, return a displaced item in the same
    -- update when possible. This keeps it off the cursor between rendered
    -- frames. Retries and guild-bank moves still respect pickup spacing.
    if (guildBankSortActive or current_return_attempted) and moveTimer < GetSortMoveInterval() then return false end
    moveTimer = 0
    current_return_attempted = true
    BagPickupItem(current_source_bag, current_source_slot)
    if CursorHasItem() then
        return false
    end

    current_displaced = false
    return true
end

moveFrame:SetScript("OnUpdate", function(self, elapsed)
    sortStallTime = sortStallTime + elapsed
    if sortStallTime >= SORT_STALL_TIMEOUT then
        if sortContext == "bags" and not CursorHasItem() and ReplanSorting and ReplanSorting() then
            return
        end
        if CursorHasItem() then
            StopSorting("DragonUI: Sort timed out; please check the item cursor.")
        else
            local location = ""
            if current_target then
                local target_bag, target_slot = decode_bagslot(current_target)
                location = string.format(" (bag %d slot %d -> bag %d slot %d)",
                    current_source_bag, current_source_slot, target_bag, target_slot)
            elseif #moves > 0 then
                local source, target = decode_move(moves[#moves])
                local source_bag, source_slot = decode_bagslot(source)
                local target_bag, target_slot = decode_bagslot(target)
                location = string.format(" (bag %d slot %d -> bag %d slot %d)",
                    source_bag, source_slot, target_bag, target_slot)
            end
            StopSorting("DragonUI: Sort timed out waiting for a bag update" .. location .. ".")
        end
        return
    end

    moveTimer = moveTimer + elapsed
    if current_target then current_action_wait = current_action_wait + elapsed end
    -- Poll locks, links and counts every frame. Start each move only after
    -- the configured interval; pickup and placement may share one tick so
    -- the item does not remain visibly attached to the cursor.
    local interval = GetSortMoveInterval()

    -- Finish the previous move before starting another one.  If the target
    -- was occupied, return its displaced item to the now-empty source slot.
    if current_target then
        local target_bag, target_slot = decode_bagslot(current_target)
        if CursorHasItem() then
            if current_displaced then
                if not ReturnDisplacedItem(elapsed) then return end
            else
                local cursor_itemid = CursorItemID()
                if cursor_itemid == false then
                    -- Cursor flag set but link not readable yet: transient, retry next tick.
                    cursorMismatchTime = 0
                    return
                end
                if cursor_itemid ~= current_id then
                    -- The target lookup may have raced the bag update. If the
                    -- cursor contains the known old target item, finish the
                    -- swap; otherwise this may be an external cursor change
                    -- or a 1-frame API race, so tolerate it briefly.
                    if current_target_itemid and cursor_itemid == current_target_itemid then
                        current_displaced = true
                        current_displaced_id = cursor_itemid
                        cursorMismatchTime = 0
                        if not ReturnDisplacedItem(elapsed) then return end
                    else
                        cursorMismatchTime = (cursorMismatchTime or 0) + elapsed
                        if cursorMismatchTime < CURSOR_MISMATCH_TOLERANCE then
                            return
                        end
                        StopSorting("DragonUI: Sort interrupted.")
                        return
                    end
                else
                    cursorMismatchTime = 0
                    -- A merge can fill the target while leaving a remainder
                    -- of the same item on the cursor. A full target can also
                    -- swap two stacks of the same item. In either case the
                    -- target count, rather than the item ID, identifies the
                    -- cursor item as the one to return to the source.
                    local _, target_count, target_locked = BagGetItemInfo(target_bag, target_slot)
                    if target_locked then return end
                    if current_target_itemid == current_id
                        and current_target_attempted
                        and target_count == current_target_count
                        and link_to_id(BagGetItemLink(target_bag, target_slot)) == current_id
                    then
                        current_displaced = true
                        current_displaced_id = current_id
                        if not ReturnDisplacedItem(elapsed) then return end
                    else
                        -- The source item is still on the cursor; retry the
                        -- target while its bag update catches up.
                        if current_target_attempted and current_action_wait < MOVE_UPDATE_WAIT then return end
                        if current_target_attempted
                            and (target_count ~= current_target_initial_count
                                or link_to_id(BagGetItemLink(target_bag, target_slot)) ~= current_target_itemid)
                        then return end
                        -- Clicking: respect pickup spacing.
                        if moveTimer < interval then return end
                        moveTimer = 0
                        current_target_attempted = true
                        current_action_wait = 0
                        BagPickupItem(target_bag, target_slot)
                        if CursorHasItem() then return end
                    end
                end
            end
        end

        if CursorHasItem() then
            return
        end

        -- A pickup may be rejected before the cursor ever changes. Only
        -- retry when both slots still match the state before this move.
        if not guildBankSortActive and current_action_wait >= MOVE_UPDATE_WAIT then
            local _, source_count, source_locked = BagGetItemInfo(current_source_bag, current_source_slot)
            local _, target_count, target_locked = BagGetItemInfo(target_bag, target_slot)
            if not source_locked and not target_locked
                and source_count == current_source_initial_count
                and target_count == current_target_initial_count
                and link_to_id(BagGetItemLink(current_source_bag, current_source_slot)) == current_id
                and link_to_id(BagGetItemLink(target_bag, target_slot)) == current_target_itemid
                and moveTimer >= interval
            then
                current_target_attempted = false
                moveTimer = 0
                current_action_wait = 0
                if current_target_itemid == current_id and target_count
                    and target_count < current_stack_size and target_count + source_count > current_stack_size
                then
                    BagSplitItem(current_source_bag, current_source_slot, current_stack_size - target_count)
                else
                    BagPickupItem(current_source_bag, current_source_slot)
                end
            end
        end
        if not current_target_attempted then return end

        -- Wait for the complete destination update before allowing another
        -- move. The count check matters for partial-stack moves where the
        -- item link stays unchanged.
        local _, confirmed_source_count, source_locked = BagGetItemInfo(current_source_bag, current_source_slot)
        local _, confirmed_target_count, target_locked = BagGetItemInfo(target_bag, target_slot)
        local confirmed_target_id = link_to_id(BagGetItemLink(target_bag, target_slot))
        if source_locked or target_locked
            or confirmed_target_id ~= current_id
            or (current_target_count and confirmed_target_count ~= current_target_count)
            or (not guildBankSortActive and (
                link_to_id(BagGetItemLink(current_source_bag, current_source_slot)) ~= current_source_expected_id
                or (current_source_expected_id and confirmed_source_count ~= current_source_expected_count)))
        then
            if sortContext == "bags" and current_action_wait >= 2
                and not source_locked and not target_locked
                and (confirmed_target_id ~= current_target_itemid
                    or confirmed_target_count ~= current_target_initial_count)
                and ReplanSorting and ReplanSorting()
            then
                return
            end
            return
        end

        ResetCurrentMove()
        replanAttempts = 0
        sortStallTime = 0
        cursorMismatchTime = 0
        idleCursorTime = 0
    elseif CursorHasItem() then
        -- There is no active move that could own this cursor item. This can
        -- still be a 1-frame race (cursor flag set before GetCursorInfo, or
        -- a stale flag right after a place). Wait briefly instead of
        -- aborting with a false "item on cursor".
        idleCursorTime = (idleCursorTime or 0) + elapsed
        if idleCursorTime < CURSOR_MISMATCH_TOLERANCE then
            return
        end
        StopSorting("DragonUI: Sort interrupted.")
        return
    else
        idleCursorTime = 0
    end

    if #moves > 0 then
        for i = #moves, 1, -1 do
            if CursorHasItem() then return end
            local source, target = decode_move(moves[i])
            local source_bag, source_slot = decode_bagslot(source)
            local target_bag, target_slot = decode_bagslot(target)
            local _, source_count, source_locked = BagGetItemInfo(source_bag, source_slot)
            local _, target_count, target_locked = BagGetItemInfo(target_bag, target_slot)

            if source_locked or target_locked then return end

            local source_link = BagGetItemLink(source_bag, source_slot)
            local source_itemid = link_to_id(source_link)
            if not source_itemid then
                StopSorting("DragonUI: Sort confused, stopping.")
                return
            end
            local target_link = BagGetItemLink(target_bag, target_slot)
            local target_itemid = link_to_id(target_link)
            if not source_count or source_count < 1 or (target_itemid and not target_count) then return end

            -- Clicking: respect pickup spacing (the lock reads above poll every frame).
            if moveTimer < interval then return end
            moveTimer = 0

            tremove(moves, i)

            local cached_info = item_cache[source_itemid]
            local stack_size = select(8, GetItemInfo(source_itemid)) or (cached_info and cached_info.maxStack) or 1
            if stack_size < 1 then stack_size = 1 end
            current_stack_size = stack_size
            current_target = target
            current_id = source_itemid
            current_source_bag = source_bag
            current_source_slot = source_slot
            current_displaced = false
            current_return_attempted = false
            current_displaced_id = nil
            current_source_initial_count = source_count
            current_target_initial_count = target_count
            current_target_attempted = false
            current_action_wait = 0
            cursorMismatchTime = 0
            idleCursorTime = 0
            sortStallTime = 0

            current_target_itemid = target_itemid
            if target_itemid == source_itemid then
                if (target_count or 0) < stack_size then
                    current_target_count = math.min(stack_size, (target_count or 0) + (source_count or 0))
                    current_source_expected_count = math.max(0, (target_count or 0) + (source_count or 0) - stack_size)
                    current_source_expected_id = current_source_expected_count > 0 and source_itemid or nil
                else
                    -- PickupContainerItem swaps stacks when the target is full.
                    current_target_count = source_count or 0
                    current_source_expected_id = target_itemid
                    current_source_expected_count = target_count
                end
            else
                current_target_count = source_count or 0
                current_source_expected_id = target_itemid
                current_source_expected_count = target_count
            end

            if (source_itemid == target_itemid) and target_count and (target_count ~= stack_size) and ((target_count + (source_count or 0)) > stack_size) then
                BagSplitItem(source_bag, source_slot, stack_size - target_count)
            else
                BagPickupItem(source_bag, source_slot)
            end
            local isGuildBankMove = IsGuildBankBag(source_bag)
            if isGuildBankMove or CursorHasItem() then
                current_target_attempted = true
                BagPickupItem(target_bag, target_slot)
            else
                -- The pickup has not appeared on the cursor yet. Place it on
                -- a later tick once the client reports it.
                return
            end

            -- If target was occupied, the second pickup leaves that old item
            -- on the cursor. Return it to source to complete the swap.
            if CursorHasItem() then
                local cursor_itemid = CursorItemID()
                if cursor_itemid == false then
                    -- Link not readable yet this tick; retry next tick.
                    return
                end
                -- A same-item merge or swap can leave a cursor item with the
                -- same ID as the source; the target count is checked above on
                -- the next tick before returning it.
                current_displaced = target_itemid ~= nil and target_itemid ~= source_itemid and cursor_itemid == target_itemid
                if current_displaced then
                    current_displaced_id = target_itemid
                    cursorMismatchTime = 0
                    if not ReturnDisplacedItem(elapsed) then return end
                elseif not isGuildBankMove then
                    if cursor_itemid ~= current_id then
                        cursorMismatchTime = (cursorMismatchTime or 0) + elapsed
                        if cursorMismatchTime < CURSOR_MISMATCH_TOLERANCE then
                            return
                        end
                        StopSorting("DragonUI: Sort interrupted.")
                        return
                    end
                    cursorMismatchTime = 0
                    -- Target was empty but the source item is still held;
                    -- leave it for the retry path at the next tick.
                    return
                end
            end

            -- One guild-bank move per tick: state doesn't update predictively like bags.
            if isGuildBankMove then return end

            -- Never start a second move until this move's destination has
            -- been confirmed on a later update tick.
            return
        end
    end

    DEFAULT_CHAT_FRAME:AddMessage("|cff00cc66DragonUI:|r " .. T("Sort complete.", "Sort complete."), 0.4, 1, 0.4)
    StopSorting()
end)
moveFrame:Hide()

StopSorting = function(message)
    running = false
    guildBankSortActive = false
    sortContext = nil
    replanAttempts = 0
    ResetCurrentMove()
    sortStallTime = 0
    cursorMismatchTime = 0
    idleCursorTime = 0
    moveTimer = 0
    wipe(moves)
    wipe(bag_maxstacks)
    wipe(item_cache)
    moveFrame:Hide()
    if addon.RefreshButtonGrid then addon.RefreshButtonGrid() end
    if not InCombatLockdown() and addon.RefreshAllHotkeys then addon.RefreshAllHotkeys() end
    if message then
        DEFAULT_CHAT_FRAME:AddMessage(message, 1, 0.4, 0.4)
    end
end

local function StartSorting()
    -- There is no previous move to protect on the first tick.
    moveTimer = GetSortMoveInterval()
    sortStallTime = 0
    cursorMismatchTime = 0
    idleCursorTime = 0
    -- Keep item metadata until the queue finishes so stack sizes remain
    -- available even when GetItemInfo temporarily returns nil.
    wipe(bag_maxstacks)
    wipe(bag_stacks)
    wipe(bag_ids)
    if #moves == 0 then wipe(item_cache) end

    if #moves > 0 then
        running = true
        moveFrame:Show()
    end
end

ReplanSorting = function()
    if sortContext ~= "bags" or replanAttempts >= MAX_REPLAN_ATTEMPTS or CursorHasItem() then
        return false
    end
    -- CursorHasItem can briefly lag GetCursorInfo; never replan while an
    -- item may still be held by the client.
    local cursorType = GetCursorInfo()
    if cursorType == "item" then return false end

    if current_target then
        if not current_target_attempted then return false end
        local target_bag, target_slot = decode_bagslot(current_target)
        local _, _, source_locked = BagGetItemInfo(current_source_bag, current_source_slot)
        local _, _, target_locked = BagGetItemInfo(target_bag, target_slot)
        if source_locked or target_locked then return false end
    end

    replanAttempts = replanAttempts + 1
    ResetCurrentMove()
    wipe(moves)
    wipe(bag_ids)
    wipe(bag_stacks)
    wipe(bag_maxstacks)
    wipe(item_cache)
    ScanBags(ALL_BAGS)
    CompressAndSortBagGroups(PLAYER_BAGS)
    StartSorting()
    return true
end

-- ============================================================================
-- PUBLIC SORT FUNCTIONS
-- ============================================================================

local function SortCursorIsOccupied()
    if not CursorHasItem() then return false end
    DEFAULT_CHAT_FRAME:AddMessage("|cff00cc66DragonUI:|r " .. T("Put away the item on your cursor before sorting.", "Put away the item on your cursor before sorting."), 1, 0.8, 0)
    return true
end

local function SortPlayerBags()
    if running then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00cc66DragonUI:|r " .. T("Sort already in progress.", "Sort already in progress."), 1, 0.8, 0)
        return
    end
    if SortCursorIsOccupied() then return end

    ScanBags(ALL_BAGS)
    CompressAndSortBagGroups(PLAYER_BAGS)
    sortContext = "bags"
    replanAttempts = 0
    StartSorting()

    if #moves == 0 then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00cc66DragonUI:|r " .. T("Bags already sorted!", "Bags already sorted!"), 0.4, 1, 0.4)
    end
end

local function SortBankBags()
    if running then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00cc66DragonUI:|r " .. T("Sort already in progress.", "Sort already in progress."), 1, 0.8, 0)
        return
    end
    if SortCursorIsOccupied() then return end
    if not bank_open then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00cc66DragonUI:|r " .. T("You must be at the bank.", "You must be at the bank."), 1, 0.4, 0.4)
        return
    end

    ScanBags(ALL_BAGS)
    sortContext = nil

    -- Debug: print what ScanBags found for bank items
    if addon.debugMode then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00cc66" .. T("=== BANK SCAN DEBUG ===", "=== BANK SCAN DEBUG ===") .. "|r")
        for bag, slot, bagslot in IterateBags(BANK_BAGS) do
            local id = bag_ids[bagslot]
            if id then
                local info = item_cache[id]
                DEFAULT_CHAT_FRAME:AddMessage(string.format("  [%d] bag%d/s%d: %s (id=%d r=%d lv=%d t=%s st=%s eq=%s x%d)",
                    bagslot, bag, slot,
                    info and info.name or "NIL_NAME",
                    id,
                    info and info.rarity or -1,
                    info and info.level or -1,
                    info and info.itype or "NIL",
                    info and info.subType or "NIL",
                    info and info.equipLoc or "NIL",
                    bag_stacks[bagslot] or 0))
            end
        end
    end

    if IsBankFillFromBagsEnabled() then
        local fillBags = {}
        for _, bag in ipairs(PLAYER_BAGS) do
            if bag ~= KEYRING_CONTAINER then
                tinsert(fillBags, bag)
            end
        end
        StackBagsAcross(fillBags, BANK_BAGS)
    end
    CompressAndSortBagGroups(BANK_BAGS)

    -- Debug: print sorted order and moves
    if addon.debugMode then
        DEFAULT_CHAT_FRAME:AddMessage(string.format("|cff00cc66=== %d MOVES ===|r", #moves))
        for i = #moves, 1, -1 do
            local s, t = decode_move(moves[i])
            DEFAULT_CHAT_FRAME:AddMessage(string.format("  move: [%d]->  [%d]", s, t))
        end
    end

    StartSorting()

    if #moves == 0 then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00cc66DragonUI:|r " .. T("Bank already sorted!", "Bank already sorted!"), 0.4, 1, 0.4)
    end
end

-- ============================================================================
-- GUILD BANK SORTING (single tab only, never crosses tabs)
-- ============================================================================
-- Crossing tabs would spend withdrawal allowance on both ends just to reorder.

local function PerformGuildBankSort()
    if running then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00cc66DragonUI:|r " .. T("Sort already in progress.", "Sort already in progress."), 1, 0.8, 0)
        return
    end
    if SortCursorIsOccupied() then return end
    if not guild_bank_open then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00cc66DragonUI:|r " .. T("You must be at the guild bank.", "You must be at the guild bank."), 1, 0.4, 0.4)
        return
    end
    if type(GetCurrentGuildBankTab) ~= "function" then
        return
    end

    local tab = GetCurrentGuildBankTab()
    if not tab or tab < 1 then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00cc66DragonUI:|r " .. T("Could not determine the current guild bank tab.", "Could not determine the current guild bank tab."), 1, 0.4, 0.4)
        return
    end

    if GetGuildBankTabSlotCount(tab) == 0 then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00cc66DragonUI:|r " .. T("You need full deposit and withdraw access to this tab to sort it.", "You need full deposit and withdraw access to this tab to sort it."), 1, 0.4, 0.4)
        return
    end

    local tabBags = { GUILDBANK_TAB_OFFSET + tab }
    ScanBags(tabBags)
    sortContext = nil
    CompressStacks(tabBags)
    SortItems(tabBags)

    if #moves == 0 then
        StartSorting() -- still wipes the scratch scan caches
        DEFAULT_CHAT_FRAME:AddMessage("|cff00cc66DragonUI:|r " .. T("This guild bank tab is already sorted!", "This guild bank tab is already sorted!"), 0.4, 1, 0.4)
        return
    end

    guildBankSortActive = true
    StartSorting()
end

StaticPopupDialogs["DRAGONUI_CONFIRM_GUILDBANK_SORT"] = {
    text = T("Sort this guild bank tab? Depending on your server, this may be logged and count against your guild's shared withdrawal allowance, the same as moving items by hand.", "Sort this guild bank tab? Depending on your server, this may be logged and count against your guild's shared withdrawal allowance, the same as moving items by hand."),
    button1 = T("Sort", "Sort"),
    button2 = CANCEL,
    OnAccept = PerformGuildBankSort,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

local function SortGuildBankTab()
    if running then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00cc66DragonUI:|r " .. T("Sort already in progress.", "Sort already in progress."), 1, 0.8, 0)
        return
    end
    if not guild_bank_open then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00cc66DragonUI:|r " .. T("You must be at the guild bank.", "You must be at the guild bank."), 1, 0.4, 0.4)
        return
    end
    StaticPopup_Show("DRAGONUI_CONFIRM_GUILDBANK_SORT")
end

local function HandleSortLockCommand(msg)
    local command = msg and string.lower(string.gsub(msg, "^%s*(.-)%s*$", "%1")) or ""
    if command == "clear" or command == "reset" then
        ClearAllLockedSlots()
        return
    end
    ToggleHoveredSlotLock()
end

-- ============================================================================
-- BUTTON CREATION HELPERS
-- ============================================================================

-- Retail INV_Pet_Broom, the art behind retail's bag cleanup button; the 3.3.5a client has no broom icon.
local SORT_ICON_TEXTURE = "Interface\\AddOns\\DragonUI\\Textures\\UI\\BagSortBroom"

local function CreateActionButton(name, parent, onClick, tooltipTitle, scale, iconPath, tooltipLines)
    scale = scale or 1.0
    local size = 32 * scale
    local btn = CreateFrame("Button", name, parent)
    btn:SetSize(size, size)
    btn:EnableMouse(true)
    btn:SetFrameLevel(parent:GetFrameLevel() + 10)

    -- Icon fills the button
    local icon = btn:CreateTexture(name .. "Icon", "ARTWORK")
    icon:SetAllPoints()
    icon:SetTexture(iconPath or SORT_ICON_TEXTURE)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    btn.icon = icon

    -- Square border (action button style)
    local border = btn:CreateTexture(name .. "Border", "OVERLAY")
    border:SetSize(size * 62/36, size * 62/36)
    border:SetPoint("CENTER", 0, 0)
    border:SetTexture("Interface\\Buttons\\UI-Quickslot2")
    btn.border = border

    -- Highlight
    local highlight = btn:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
    highlight:SetBlendMode("ADD")
    btn.highlight = highlight

    -- Pushed feedback
    btn:SetScript("OnMouseDown", function(self)
        self.icon:SetTexCoord(0.12, 0.88, 0.12, 0.88)
    end)
    btn:SetScript("OnMouseUp", function(self)
        self.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    end)

    -- Tooltip
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(tooltipTitle or T("Sort Items", "Sort Items"))
        local lines = tooltipLines
        if type(lines) == "function" then
            lines = lines()
        end
        if type(lines) == "table" then
            for _, line in ipairs(lines) do
                GameTooltip:AddLine(line, 1, 1, 1, true)
            end
        elseif type(lines) == "string" then
            GameTooltip:AddLine(lines, 1, 1, 1, true)
        end
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    -- Click handler
    btn:SetScript("OnClick", function()
        if onClick then onClick() end
    end)

    return btn
end

local function CreateSortButton(name, parent, onClick, tooltipText, scale)
    local function BuildTooltipLines()
        return {
            T("Click to sort items by type, rarity, and name.", "Click to sort items by type, rarity, and name."),
            string.format(T("%s any bag slot (item or empty) to lock or unlock it.", "%s any bag slot (item or empty) to lock or unlock it."), GetLockHotkeyLabel()),
            T("Click the lock-clear button to remove all locked slots.", "Click the lock-clear button to remove all locked slots.")
        }
    end

    return CreateActionButton(
        name,
        parent,
        onClick,
        tooltipText,
        scale,
        SORT_ICON_TEXTURE,
        BuildTooltipLines
    )
end

local function CreateClearLocksButton(name, parent, scale)
    local function BuildTooltipLines()
        return {
            T("Click to clear all locked bag slots.", "Click to clear all locked bag slots."),
            string.format(T("%s any bag slot (item or empty) to lock or unlock it.", "%s any bag slot (item or empty) to lock or unlock it."), GetLockHotkeyLabel())
        }
    end

    return CreateActionButton(
        name,
        parent,
        ClearAllLockedSlots,
        T("Clear Locked Slots", "Clear Locked Slots"),
        scale,
        "Interface\\Icons\\INV_Misc_Key_14",
        BuildTooltipLines
    )
end

-- ============================================================================
-- SELL SCRAP
-- ============================================================================

local function FormatMoney(copper)
    local gold = math.floor(copper / 10000)
    local silver = math.floor((copper % 10000) / 100)
    local copperRem = copper % 100
    if gold > 0 then
        return string.format("|cffffd700%dg|r |cffc0c0c0%ds|r |cffeda55f%dc|r", gold, silver, copperRem)
    elseif silver > 0 then
        return string.format("|cffc0c0c0%ds|r |cffeda55f%dc|r", silver, copperRem)
    else
        return string.format("|cffeda55f%dc|r", copperRem)
    end
end

local function SellScrapItems()
    if not MerchantFrame or not MerchantFrame:IsShown() then
        print("|cffff9900DragonUI|r: " .. T("Open a merchant window first to sell scrap items.", "Open a merchant window first to sell scrap items."))
        return
    end

    local soldCount = 0
    local totalValue = 0

    for bag = 0, 4 do
        for slot = 1, GetContainerNumSlots(bag) do
            local itemID = GetContainerItemID(bag, slot)
            if itemID then
                local _, _, quality, _, iType, _, _, _, _, _, sellPrice = GetItemInfo(itemID)
                if quality == 0 and iType and iType ~= "Quest" and sellPrice and sellPrice > 0 then
                    local stackCount = select(2, GetContainerItemInfo(bag, slot)) or 1
                    UseContainerItem(bag, slot)
                    soldCount = soldCount + 1
                    totalValue = totalValue + (sellPrice * stackCount)
                end
            end
        end
    end

    if soldCount > 0 then
        print("|cffff9900DragonUI|r: " .. string.format(T("Sold %d scrap item(s) for %s.", "Sold %d scrap item(s) for %s."), soldCount, FormatMoney(totalValue)))
    else
        print("|cffff9900DragonUI|r: " .. T("No scrap items to sell.", "No scrap items to sell."))
    end
end

local function CreateSellScrapButton(name, parent, scale)
    local function BuildTooltipLines()
        return {
            T("Click to sell all gray (poor) items to vendor.", "Click to sell all gray (poor) items to vendor."),
            T("A merchant window must be open.", "A merchant window must be open.")
        }
    end

    return CreateActionButton(
        name,
        parent,
        SellScrapItems,
        T("Sell Scrap", "Sell Scrap"),
        scale,
        "Interface\\Icons\\INV_Misc_Coin_01",
        BuildTooltipLines
    )
end

-- ============================================================================
-- BAGSTER BUTTON INTEGRATION
-- ============================================================================

local bagsterBagSortBtn, bagsterBankSortBtn
local bagsterBagClearBtn, bagsterBankClearBtn
local bagsterBagSellScrapBtn, bagsterBankSellScrapBtn
local bagnonBagSortBtn, bagnonBankSortBtn
local bagnonBagClearBtn, bagnonBankClearBtn
local vanillaGuildBankSortBtn, bagnonGuildBankSortBtn

local function GetBagsterFrame(index)
    return _G["DragonUI_BagsterFrame" .. index]
end

local function AttachBagsterButtons(frame, sortRef, clearRef, sellScrapRef, sortFunc, sortBtnName, clearBtnName, sellScrapBtnName, tooltipText)
    if sortRef and clearRef and (not sellScrapBtnName or sellScrapRef) then
        return sortRef, clearRef, sellScrapRef
    end

    local frameName = frame:GetName()
    local searchBox = _G[frameName .. "Search"]
    local bagToggle = _G[frameName .. "BagToggle"]

    local sortBtn = sortRef or CreateSortButton(sortBtnName, frame, sortFunc, tooltipText, 0.55)
    local clearBtn = clearRef or CreateClearLocksButton(clearBtnName, frame, 0.55)
    local sellScrapBtn = sellScrapRef
    if sellScrapBtnName and not sellScrapRef then
        sellScrapBtn = CreateSellScrapButton(sellScrapBtnName, frame, 0.55)
    end

    -- Dragonflight action-button chrome for the header buttons (same recipe as buttons.lua)
    local function StyleHeaderButton(b)
        if not b or b._bagsterStyled then return end
        b._bagsterStyled = true
        b:SetSize(22, 22)
        b.icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
        b.border:SetTexture(addon._dir .. "ActionBars\\uiactionbariconframe")
        b.border:ClearAllPoints()
        b.border:SetPoint("TOPRIGHT", b, "TOPRIGHT", 2.2, 2.3)
        b.border:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", -2.2, -2.2)
        if b.highlight then
            b.highlight:SetTexture(addon._dir .. "ActionBars\\uiactionbariconframehighlight")
            b.highlight:ClearAllPoints()
            b.highlight:SetAllPoints(b.border)
        end
        b:SetScript("OnMouseDown", function(self)
            self.icon:SetTexCoord(0.1, 0.9, 0.1, 0.9)
        end)
        b:SetScript("OnMouseUp", function(self)
            self.icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
        end)
    end
    StyleHeaderButton(sortBtn)
    StyleHeaderButton(clearBtn)
    StyleHeaderButton(sellScrapBtn)

    -- Single header row: [ searchBox ][ sellScrap ][ clearBtn ][ sortBtn ][ bagToggle ]
    if bagToggle then
        bagToggle:ClearAllPoints()
        bagToggle:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -18, -30)
    end

    sortBtn:ClearAllPoints()
    if bagToggle then
        sortBtn:SetPoint("RIGHT", bagToggle, "LEFT", -6, 0)
    else
        sortBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -44, -32)
    end

    clearBtn:ClearAllPoints()
    clearBtn:SetPoint("RIGHT", sortBtn, "LEFT", -4, 0)

    if sellScrapBtn then
        sellScrapBtn:ClearAllPoints()
        sellScrapBtn:SetPoint("RIGHT", clearBtn, "LEFT", -4, 0)
    end

    -- Search box is fixed-width on the left; nothing to shrink anymore

    sortBtn:Show()
    clearBtn:Show()
    if sellScrapBtn then sellScrapBtn:Show() end
    return sortBtn, clearBtn, sellScrapBtn
end

local function CreateBagsterSortButtons()
    local inventoryFrame = GetBagsterFrame(1)
    local bankFrame = GetBagsterFrame(2)

    if inventoryFrame and (not bagsterBagSortBtn or not bagsterBagClearBtn or not bagsterBagSellScrapBtn) then
        bagsterBagSortBtn, bagsterBagClearBtn, bagsterBagSellScrapBtn = AttachBagsterButtons(
            inventoryFrame, bagsterBagSortBtn, bagsterBagClearBtn, bagsterBagSellScrapBtn,
            SortPlayerBags, "DragonUI_BagsterBagSortBtn", "DragonUI_BagsterBagClearBtn", "DragonUI_BagsterBagSellScrapBtn",
            T("Sort Bags", "Sort Bags")
        )
        BagSortModule.frames.bagsterBagSortBtn = bagsterBagSortBtn
        BagSortModule.frames.bagsterBagClearBtn = bagsterBagClearBtn
        BagSortModule.frames.bagsterBagSellScrapBtn = bagsterBagSellScrapBtn
    end

    if bankFrame and (not bagsterBankSortBtn or not bagsterBankClearBtn) then
        bagsterBankSortBtn, bagsterBankClearBtn = AttachBagsterButtons(
            bankFrame, bagsterBankSortBtn, bagsterBankClearBtn, nil,
            SortBankBags, "DragonUI_BagsterBankSortBtn", "DragonUI_BagsterBankClearBtn", nil,
            T("Sort Bank", "Sort Bank")
        )
        BagSortModule.frames.bagsterBankSortBtn = bagsterBankSortBtn
        BagSortModule.frames.bagsterBankClearBtn = bagsterBankClearBtn
    end
end

local function AttachBagnonButtons(frame, sortRef, clearRef, sortFunc, sortBtnName, clearBtnName, tooltipText)
    if not frame then return sortRef, clearRef end

    local sortBtn = sortRef
    local clearBtn = clearRef or CreateClearLocksButton(clearBtnName, frame, 0.62)

    if sortBtn then
        sortBtn:SetParent(frame)
        sortBtn:SetFrameStrata("HIGH")
        sortBtn:Hide()
    end
    clearBtn:SetParent(frame)
    clearBtn:ClearAllPoints()
    clearBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -58, -10)
    -- Bagnon's title bar keeps re-raising itself; a higher strata always wins.
    clearBtn:SetFrameStrata("HIGH")
    clearBtn:SetFrameLevel(frame:GetFrameLevel() + 20)
    clearBtn:Show()

    return sortBtn, clearBtn
end

local function CreateBagnonSortButtons()
    if not IsBagnonLoaded() then return end

    local inventoryFrame = GetBagnonFrame("inventory")
    local bankFrame = GetBagnonFrame("bank")

    if inventoryFrame and (bagnonBagSortBtn or not bagnonBagClearBtn) then
        bagnonBagSortBtn, bagnonBagClearBtn = AttachBagnonButtons(
            inventoryFrame, bagnonBagSortBtn, bagnonBagClearBtn,
            SortPlayerBags, "DragonUI_BagnonBagSortBtn", "DragonUI_BagnonBagClearBtn", T("Sort Bags", "Sort Bags")
        )
        BagSortModule.frames.bagnonBagSortBtn = bagnonBagSortBtn
        BagSortModule.frames.bagnonBagClearBtn = bagnonBagClearBtn
    end

    if bankFrame and (bagnonBankSortBtn or not bagnonBankClearBtn) then
        bagnonBankSortBtn, bagnonBankClearBtn = AttachBagnonButtons(
            bankFrame, bagnonBankSortBtn, bagnonBankClearBtn,
            SortBankBags, "DragonUI_BagnonBankSortBtn", "DragonUI_BagnonBankClearBtn", T("Sort Bank", "Sort Bank")
        )
        BagSortModule.frames.bagnonBankSortBtn = bagnonBankSortBtn
        BagSortModule.frames.bagnonBankClearBtn = bagnonBankClearBtn
    end
end

-- ============================================================================
-- GUILD BANK BUTTON INTEGRATION
-- ============================================================================
-- No "Clear Locks" button here -- guild bank slots are never lockable.

local function CreateGuildBankSortButton(name, parent)
    local function BuildTooltipLines()
        return {
            T("Click to sort items in the currently open guild bank tab.", "Click to sort items in the currently open guild bank tab."),
            T("Never moves items between tabs.", "Never moves items between tabs."),
        }
    end

    return CreateActionButton(
        name,
        parent,
        SortGuildBankTab,
        T("Sort Guild Bank Tab", "Sort Guild Bank Tab"),
        0.61,
        SORT_ICON_TEXTURE,
        BuildTooltipLines
    )
end

local function CreateVanillaGuildBankSortButton()
    if vanillaGuildBankSortBtn then return end
    local frame = _G.GuildBankFrame
    if not frame then return end

    vanillaGuildBankSortBtn = CreateGuildBankSortButton("DragonUI_VanillaGuildBankSortBtn", frame)
    vanillaGuildBankSortBtn:ClearAllPoints()
    vanillaGuildBankSortBtn:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -212.5, 38)
    BagSortModule.frames.vanillaGuildBankSortBtn = vanillaGuildBankSortBtn
end

local bagsterGuildSortBtn
local function CreateBagsterGuildBankSortButton()
    if bagsterGuildSortBtn then return end
    local frame = _G["DragonUI_BagsterFrame3"]
    if not frame or not frame.itemFrame then return end

    -- Parented to the item grid so it auto-hides on the Log/Money/Info mode tabs
    bagsterGuildSortBtn = CreateGuildBankSortButton("DragonUI_BagsterGuildSortBtn", frame.itemFrame)
    bagsterGuildSortBtn:SetSize(22, 22)
    bagsterGuildSortBtn.icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
    bagsterGuildSortBtn.border:SetTexture(addon._dir .. "ActionBars\\uiactionbariconframe")
    bagsterGuildSortBtn.border:ClearAllPoints()
    bagsterGuildSortBtn.border:SetPoint("TOPRIGHT", bagsterGuildSortBtn, "TOPRIGHT", 2.2, 2.3)
    bagsterGuildSortBtn.border:SetPoint("BOTTOMLEFT", bagsterGuildSortBtn, "BOTTOMLEFT", -2.2, -2.2)
    if bagsterGuildSortBtn.highlight then
        bagsterGuildSortBtn.highlight:SetTexture(addon._dir .. "ActionBars\\uiactionbariconframehighlight")
        bagsterGuildSortBtn.highlight:ClearAllPoints()
        bagsterGuildSortBtn.highlight:SetAllPoints(bagsterGuildSortBtn.border)
    end
    bagsterGuildSortBtn:ClearAllPoints()
    bagsterGuildSortBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -16, -31)
    BagSortModule.frames.bagsterGuildSortBtn = bagsterGuildSortBtn
end

local function CreateBagnonGuildBankSortButton()
    if bagnonGuildBankSortBtn then return end
    local frame = GetBagnonFrame("guildbank")
    if not frame then return end

    bagnonGuildBankSortBtn = CreateGuildBankSortButton("DragonUI_BagnonGuildBankSortBtn", frame)
    bagnonGuildBankSortBtn:SetParent(frame)
    -- See AttachBagnonButtons: needs its own strata to stay reliably clickable.
    bagnonGuildBankSortBtn:SetFrameStrata("HIGH")
    bagnonGuildBankSortBtn:ClearAllPoints()
    bagnonGuildBankSortBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -57, -9)
    bagnonGuildBankSortBtn:SetFrameLevel(frame:GetFrameLevel() + 20)
    BagSortModule.frames.bagnonGuildBankSortBtn = bagnonGuildBankSortBtn
end

-- ============================================================================
-- VANILLA FRAME BUTTON INTEGRATION
-- ============================================================================

local vanillaBagSortBtn, vanillaBankSortBtn
local vanillaBagClearBtn, vanillaBankClearBtn
local vanillaBagSellScrapBtn

local function CreateVanillaBagSortButton()
    if vanillaBagSortBtn then return end

    vanillaBagSortBtn = CreateSortButton(
        "DragonUI_VanillaBagSortBtn",
        UIParent,
        SortPlayerBags,
        T("Sort Bags", "Sort Bags"),
        0.63
    )
    vanillaBagClearBtn = CreateClearLocksButton("DragonUI_VanillaBagClearBtn", UIParent, 0.63)
    vanillaBagSellScrapBtn = CreateSellScrapButton("DragonUI_VanillaBagSellScrapBtn", UIParent, 0.63)
    vanillaBagSortBtn:Hide()
    vanillaBagClearBtn:Hide()
    vanillaBagSellScrapBtn:Hide()
    BagSortModule.frames.vanillaBagSortBtn = vanillaBagSortBtn
    BagSortModule.frames.vanillaBagClearBtn = vanillaBagClearBtn
    BagSortModule.frames.vanillaBagSellScrapBtn = vanillaBagSellScrapBtn
end

-- Find which ContainerFrame is currently showing bag 0 (backpack)
local function GetBackpackFrame()
    for i = 1, NUM_CONTAINER_FRAMES do
        local frame = _G["ContainerFrame" .. i]
        if frame and frame:IsShown() and frame:GetID() == 0 then
            return frame
        end
    end
end

local function UpdateVanillaBagSortButton()
    if not vanillaBagSortBtn or not vanillaBagClearBtn then return end
    local backpack = GetBackpackFrame()
    if backpack then
        vanillaBagSortBtn:SetParent(backpack)
        vanillaBagClearBtn:SetParent(backpack)
        vanillaBagSellScrapBtn:SetParent(backpack)
        vanillaBagSortBtn:ClearAllPoints()
        vanillaBagClearBtn:ClearAllPoints()
        vanillaBagSellScrapBtn:ClearAllPoints()
        local titleAnchor = _G[backpack:GetName() .. "Name"]
        local skinChrome = backpack._dragonuiBagChrome
        if addon:IsModuleEnabled("bags_skin")
            and skinChrome and skinChrome.title and skinChrome.title:IsShown()
        then
            titleAnchor = skinChrome.title
        end
        vanillaBagSortBtn:SetPoint("TOP", titleAnchor, "BOTTOM", 70.5, -6.5)
        vanillaBagClearBtn:SetPoint("RIGHT", vanillaBagSortBtn, "LEFT", -3, 0)
        vanillaBagSellScrapBtn:SetPoint("RIGHT", vanillaBagClearBtn, "LEFT", -3, 0)
        vanillaBagSortBtn:SetFrameLevel(backpack:GetFrameLevel() + 10)
        vanillaBagClearBtn:SetFrameLevel(backpack:GetFrameLevel() + 10)
        vanillaBagSellScrapBtn:SetFrameLevel(backpack:GetFrameLevel() + 10)
        vanillaBagSortBtn:Show()
        vanillaBagClearBtn:Show()
        vanillaBagSellScrapBtn:Show()
    else
        vanillaBagSortBtn:Hide()
        vanillaBagClearBtn:Hide()
        vanillaBagSellScrapBtn:Hide()
    end
end

local function CreateVanillaBankSortButton()
    if vanillaBankSortBtn then return end

    local bankFrameUI = BankFrame
    if not bankFrameUI then return end

    vanillaBankSortBtn = CreateSortButton(
        "DragonUI_VanillaBankSortBtn",
        bankFrameUI,
        SortBankBags,
        T("Sort Bank", "Sort Bank"),
        0.70
    )
    vanillaBankClearBtn = CreateClearLocksButton("DragonUI_VanillaBankClearBtn", bankFrameUI, 0.70)
    -- Position near top-right, to the left of the close button
    local closeBtn = _G["BankCloseButton"]
    if closeBtn then
        vanillaBankSortBtn:SetPoint("RIGHT", closeBtn, "LEFT", 1, -33)
        vanillaBankClearBtn:SetPoint("RIGHT", vanillaBankSortBtn, "LEFT", -2, 0)
    else
        vanillaBankSortBtn:SetPoint("TOPRIGHT", bankFrameUI, "TOPRIGHT", -60, -8)
        vanillaBankClearBtn:SetPoint("RIGHT", vanillaBankSortBtn, "LEFT", -2, 0)
    end
    vanillaBankSortBtn:Show()
    vanillaBankClearBtn:Show()
    BagSortModule.frames.vanillaBankSortBtn = vanillaBankSortBtn
    BagSortModule.frames.vanillaBankClearBtn = vanillaBankClearBtn
end

-- ============================================================================
-- BUTTON VISIBILITY MANAGEMENT
-- ============================================================================

UpdateButtonVisibility = function()
    local bagsterActive = IsBagsterEnabled()
    local bagsterApplied = GetBagsterFrame(1) ~= nil

    if bagsterActive and bagsterApplied then
        CreateBagsterSortButtons()
        if bagsterBagSortBtn then bagsterBagSortBtn:Show() end
        if bagsterBagClearBtn then bagsterBagClearBtn:Show() end
        if bagsterBagSellScrapBtn then bagsterBagSellScrapBtn:Show() end
        if bagsterBankSortBtn then bagsterBankSortBtn:Show() end
        if bagsterBankClearBtn then bagsterBankClearBtn:Show() end
        if bagnonBagSortBtn then bagnonBagSortBtn:Hide() end
        if bagnonBagClearBtn then bagnonBagClearBtn:Hide() end
        if bagnonBankSortBtn then bagnonBankSortBtn:Hide() end
        if bagnonBankClearBtn then bagnonBankClearBtn:Hide() end
        if vanillaBagSortBtn then vanillaBagSortBtn:Hide() end
        if vanillaBagClearBtn then vanillaBagClearBtn:Hide() end
        if vanillaBagSellScrapBtn then vanillaBagSellScrapBtn:Hide() end
        if vanillaBankSortBtn then vanillaBankSortBtn:Hide() end
        if vanillaBankClearBtn then vanillaBankClearBtn:Hide() end
    elseif IsBagnonLoaded() then
        CreateBagnonSortButtons()
        if bagnonBagSortBtn then bagnonBagSortBtn:Hide() end
        if bagnonBagClearBtn then bagnonBagClearBtn:Show() end
        if bagnonBankSortBtn then bagnonBankSortBtn:Hide() end
        if bagnonBankClearBtn then bagnonBankClearBtn:Show() end
        if vanillaBagSortBtn then vanillaBagSortBtn:Hide() end
        if vanillaBagClearBtn then vanillaBagClearBtn:Hide() end
        if vanillaBagSellScrapBtn then vanillaBagSellScrapBtn:Hide() end
        if vanillaBankSortBtn then vanillaBankSortBtn:Hide() end
        if vanillaBankClearBtn then vanillaBankClearBtn:Hide() end
        if bagsterBagSortBtn then bagsterBagSortBtn:Hide() end
        if bagsterBagClearBtn then bagsterBagClearBtn:Hide() end
        if bagsterBagSellScrapBtn then bagsterBagSellScrapBtn:Hide() end
        if bagsterBankSortBtn then bagsterBankSortBtn:Hide() end
        if bagsterBankClearBtn then bagsterBankClearBtn:Hide() end
    else
        CreateVanillaBagSortButton()
        CreateVanillaBankSortButton()
        UpdateVanillaBagSortButton()
        if vanillaBankSortBtn then vanillaBankSortBtn:Show() end
        if vanillaBankClearBtn then vanillaBankClearBtn:Show() end
        if bagnonBagSortBtn then bagnonBagSortBtn:Hide() end
        if bagnonBagClearBtn then bagnonBagClearBtn:Hide() end
        if bagnonBankSortBtn then bagnonBankSortBtn:Hide() end
        if bagnonBankClearBtn then bagnonBankClearBtn:Hide() end
        if bagsterBagSortBtn then bagsterBagSortBtn:Hide() end
        if bagsterBagClearBtn then bagsterBagClearBtn:Hide() end
        if bagsterBagSellScrapBtn then bagsterBagSellScrapBtn:Hide() end
        if bagsterBankSortBtn then bagsterBankSortBtn:Hide() end
        if bagsterBankClearBtn then bagsterBankClearBtn:Hide() end
    end

    CreateVanillaGuildBankSortButton()
    CreateBagnonGuildBankSortButton()
    CreateBagsterGuildBankSortButton()
    if bagsterGuildSortBtn then
        if guild_bank_open and IsBagsterEnabled() then
            bagsterGuildSortBtn:Show()
        else
            bagsterGuildSortBtn:Hide()
        end
    end
    if vanillaGuildBankSortBtn then
        -- Only "bank" mode shows item slots (vs. log/money log/info sub-tabs).
        if guild_bank_open and _G.GuildBankFrame and _G.GuildBankFrame.mode == "bank" then
            vanillaGuildBankSortBtn:Show()
        else
            vanillaGuildBankSortBtn:Hide()
        end
    end
    if bagnonGuildBankSortBtn then
        if guild_bank_open then bagnonGuildBankSortBtn:Show() else bagnonGuildBankSortBtn:Hide() end
    end
end

-- Hook into frame show events for lazy/reliable button creation
local hooksInstalled = false
local function InstallShowHooks()
    if hooksInstalled then return end
    hooksInstalled = true

    -- Hook bagster frames if they exist (they show/hide dynamically)
    local cFrame1 = GetBagsterFrame(1)
    local cFrame2 = GetBagsterFrame(2)
    if cFrame1 then
        hooksecurefunc(cFrame1, "Show", function()
            if BagSortModule.applied and not bagsterBagSortBtn then
                UpdateButtonVisibility()
            end
        end)
    end
    if cFrame2 then
        hooksecurefunc(cFrame2, "Show", function()
            if BagSortModule.applied and not bagsterBankSortBtn then
                UpdateButtonVisibility()
            end
        end)
    end

    -- Hook vanilla ContainerFrame open/close for backpack-only sort button
    if not IsBagsterEnabled() then
        for i = 1, NUM_CONTAINER_FRAMES do
            local frame = _G["ContainerFrame" .. i]
            if frame then
                frame:HookScript("OnShow", function()
                    if BagSortModule.applied then UpdateVanillaBagSortButton() end
                end)
                frame:HookScript("OnHide", function()
                    if BagSortModule.applied then UpdateVanillaBagSortButton() end
                end)
            end
        end
    end

    -- Hook BankFrame OnShow
    if BankFrame then
        hooksecurefunc(BankFrame, "Show", function()
            if BagSortModule.applied and not vanillaBankSortBtn and not IsBagsterEnabled() then
                UpdateButtonVisibility()
            end
        end)
    end

    for _, frameType in ipairs({ "inventory", "bank" }) do
        local frame = GetBagnonFrame(frameType)
        if frame and frame.HookScript then
            frame:HookScript("OnShow", function()
                if BagSortModule.applied then
                    UpdateButtonVisibility()
                    if BagSortModule.RequestBagnonSlotScan then
                        BagSortModule.RequestBagnonSlotScan()
                    end
                end
            end)
        end
    end
end

-- ============================================================================
-- EVENT HANDLING
-- ============================================================================

local eventFrame = CreateFrame("Frame")

-- ============================================================================
-- APPLY / RESTORE SYSTEM
-- ============================================================================

-- Forward declaration
local ApplyBagSortSystem

ApplyBagSortSystem = function()
    if BagSortModule.applied then return end

    -- Register bank events
    eventFrame:SetScript("OnEvent", function(self, event)
        if event == "BANKFRAME_OPENED" then
            bank_open = true
            UpdateButtonVisibility()
        elseif event == "BANKFRAME_CLOSED" then
            bank_open = false
        elseif event == "GUILDBANKFRAME_OPENED" then
            guild_bank_open = true
            -- Guild bank UI loads on demand; this function doesn't exist at startup.
            if not guildBankTabHookInstalled and type(GuildBankFrameTab_OnClick) == "function" then
                guildBankTabHookInstalled = true
                hooksecurefunc("GuildBankFrameTab_OnClick", function()
                    if BagSortModule.applied then
                        UpdateButtonVisibility()
                    end
                end)
            end
            UpdateButtonVisibility()
            -- Second pass: the Bagster guild frame may be created lazily by this same event
            addon:After(0.3, function()
                if BagSortModule.applied and guild_bank_open then
                    UpdateButtonVisibility()
                end
            end)
        elseif event == "GUILDBANKFRAME_CLOSED" then
            guild_bank_open = false
        end
    end)
    eventFrame:RegisterEvent("BANKFRAME_OPENED")
    eventFrame:RegisterEvent("BANKFRAME_CLOSED")
    eventFrame:RegisterEvent("GUILDBANKFRAME_OPENED")
    eventFrame:RegisterEvent("GUILDBANKFRAME_CLOSED")
    BagSortModule.registeredEvents["BANKFRAME_OPENED"] = true
    BagSortModule.registeredEvents["BANKFRAME_CLOSED"] = true
    BagSortModule.registeredEvents["GUILDBANKFRAME_OPENED"] = true
    BagSortModule.registeredEvents["GUILDBANKFRAME_CLOSED"] = true

    -- Register slash commands
    SlashCmdList["DRAGONUI_SORT"] = SortPlayerBags
    SLASH_DRAGONUI_SORT1 = "/sort"
    SLASH_DRAGONUI_SORT2 = "/sortbags"

    SlashCmdList["DRAGONUI_SORTBANK"] = SortBankBags
    SLASH_DRAGONUI_SORTBANK1 = "/sortbank"

    SlashCmdList["DRAGONUI_SORTGUILDBANK"] = SortGuildBankTab
    SLASH_DRAGONUI_SORTGUILDBANK1 = "/sortguildbank"

    SlashCmdList["DRAGONUI_SORTLOCK"] = HandleSortLockCommand
    SLASH_DRAGONUI_SORTLOCK1 = "/sortlock"
    SLASH_DRAGONUI_SORTLOCK2 = "/sortignore"

    -- Delay button creation to ensure bagster frames are ready, then install hooks
    InstallAltClickHooks()

    if addon.After then
        addon:After(0.5, function()
            if BagSortModule.applied then
                UpdateButtonVisibility()
                InstallShowHooks()
            end
        end)
    else
        UpdateButtonVisibility()
        InstallShowHooks()
    end

    BagSortModule.applied = true
end

local function RestoreBagSortSystem()
    if not BagSortModule.applied then return end

    -- Stop any running sort
    StopSorting()

    -- Unregister events
    eventFrame:UnregisterAllEvents()
    eventFrame:SetScript("OnEvent", nil)
    wipe(BagSortModule.registeredEvents)

    -- Hide and clean up buttons
    if bagsterBagSortBtn then bagsterBagSortBtn:Hide() end
    if bagsterBagClearBtn then bagsterBagClearBtn:Hide() end
    if bagsterBankSortBtn then bagsterBankSortBtn:Hide() end
    if bagsterBankClearBtn then bagsterBankClearBtn:Hide() end
    if bagnonBagSortBtn then bagnonBagSortBtn:Hide() end
    if bagnonBagClearBtn then bagnonBagClearBtn:Hide() end
    if bagnonBankSortBtn then bagnonBankSortBtn:Hide() end
    if bagnonBankClearBtn then bagnonBankClearBtn:Hide() end
    if vanillaBagSortBtn then vanillaBagSortBtn:Hide() end
    if vanillaBagClearBtn then vanillaBagClearBtn:Hide() end
    if vanillaBagSellScrapBtn then vanillaBagSellScrapBtn:Hide() end
    if vanillaBankSortBtn then vanillaBankSortBtn:Hide() end
    if vanillaBankClearBtn then vanillaBankClearBtn:Hide() end
    if vanillaGuildBankSortBtn then vanillaGuildBankSortBtn:Hide() end
    if bagnonGuildBankSortBtn then bagnonGuildBankSortBtn:Hide() end
    if bagsterGuildSortBtn then bagsterGuildSortBtn:Hide() end

    -- Remove slash commands
    SlashCmdList["DRAGONUI_SORT"] = nil
    SlashCmdList["DRAGONUI_SORTBANK"] = nil
    SlashCmdList["DRAGONUI_SORTGUILDBANK"] = nil
    SlashCmdList["DRAGONUI_SORTLOCK"] = nil

    if lockVisualFrame then
        lockVisualFrame:SetScript("OnUpdate", nil)
        lockVisualFrame:Hide()
        lockVisualFrame = nil
    end

    for button, _ in pairs(hookedSlotButtons) do
        if button and button._dragonUISortLockMarker then
            button._dragonUISortLockMarker:Hide()
        end
    end

    -- Undo the Sorting hooks so a disabled module stops intercepting Bagnon's native sort.
    local bagnon = _G.Bagnon
    if bagnon and bagnon.Sorting then
        if bagnonOriginalGetSpaces then
            bagnon.Sorting.GetSpaces = bagnonOriginalGetSpaces
            bagnonOriginalGetSpaces = nil
        end
        if bagnonOriginalMove then
            bagnon.Sorting.Move = bagnonOriginalMove
            bagnonOriginalMove = nil
        end
    end
    bagnonSortingHooked = false
    bagnonMoveHooked = false

    BagSortModule.applied = false
end

-- ============================================================================
-- MODULE LIFECYCLE
-- ============================================================================

-- Profile change callbacks (handled via ADDON_LOADED registration)
local function OnProfileChanged()
    if IsModuleEnabled() then
        if not BagSortModule.applied then
            ApplyBagSortSystem()
        else
            UpdateButtonVisibility()
        end
    else
        if addon:ShouldDeferModuleDisable("bagsort", BagSortModule) then
            return
        end
        RestoreBagSortSystem()
    end
end

-- Initialization via events
local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("ADDON_LOADED")
initFrame:RegisterEvent("PLAYER_ENTERING_WORLD")

initFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == "DragonUI" then
        if not IsModuleEnabled() then return end

        -- Register profile callbacks after DB is ready
        -- Use After to ensure DB is fully initialized
        if addon.After then
            addon:After(0.6, function()
                if addon.db and addon.db.RegisterCallback then
                    -- Use a unique callback object to avoid overwriting other modules
                    local callbackObj = {}
                    addon.db.RegisterCallback(callbackObj, "OnProfileChanged", OnProfileChanged)
                    addon.db.RegisterCallback(callbackObj, "OnProfileCopied", OnProfileChanged)
                    addon.db.RegisterCallback(callbackObj, "OnProfileReset", OnProfileChanged)
                end
            end)
        end

    elseif event == "PLAYER_ENTERING_WORLD" then
        if not IsModuleEnabled() then return end
        ApplyBagSortSystem()
    end
end)

-- Registry lifecycle resolves these off `addon` via lifecyclePrefix "BagSort".
addon.ApplyBagSortSystem = ApplyBagSortSystem
addon.RestoreBagSortSystem = RestoreBagSortSystem

-- Expose sort functions for other modules/macros
addon.SortPlayerBags = SortPlayerBags
addon.SortBankBags = SortBankBags
addon.SortGuildBankTab = SortGuildBankTab
-- Lets the options panel re-tint visible lock icons live when the color changes.
addon.RefreshBagSortLockMarkers = RefreshAllLockMarkers
addon.BagSortDefaultLockColor = DEFAULT_LOCK_MARKER_COLOR
