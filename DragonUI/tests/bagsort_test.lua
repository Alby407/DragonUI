-- Standalone Lua 5.1 regression tests; run from Interface/AddOns:
-- lua DragonUI/tests/bagsort_test.lua
local modulePath = "DragonUI/modules/bagsort.lua"
local tests = 0

local function newInventory(options)
    options = options or {}
    local env = setmetatable({}, { __index = _G })
    env._G = env
    local bags, frames, messages = {}, {}, {}
    local now, cursor, beforePickup = 0, nil, options.beforePickup
    local locks = {}
    local function slots(bag)
        if not bags[bag] then bags[bag] = {} end
        return bags[bag]
    end
    local function link(item)
        return item and ("item:" .. item.id .. ":0:0:0")
    end
    env.NUM_BAG_SLOTS, env.NUM_BANKBAGSLOTS = 4, 7
    env.KEYRING_CONTAINER, env.BANK_CONTAINER, env.BACKPACK_CONTAINER = -2, -1, 0
    env.NUM_CONTAINER_FRAMES = 0
    env.tinsert, env.tremove = table.insert, table.remove
    env.wipe = function(t) for k in pairs(t) do t[k] = nil end end
    env.StaticPopupDialogs, env.SlashCmdList = {}, {}
    env.DEFAULT_CHAT_FRAME = { AddMessage = function(_, message) table.insert(messages, message) end }
    env.CreateFrame = function()
        local frame = { scripts = {}, shown = true }
        function frame:SetScript(event, callback) self.scripts[event] = callback end
        function frame:Show() self.shown = true end
        function frame:Hide() self.shown = false end
        function frame:RegisterEvent() end
        table.insert(frames, frame)
        return frame
    end
    env.GetTime = function() return now end
    env.InCombatLockdown = function() return false end
    env.CursorHasItem = function() return cursor ~= nil end
    env.GetCursorInfo = function()
        if cursor then return "item", cursor.id, not options.noCursorLink and link(cursor) or nil end
    end
    env.GetContainerNumSlots = function(bag)
        if options.bagSizes then return options.bagSizes[bag] or 0 end
        return (bag == 0 or (options.bank and bag == -1)) and 4 or 0
    end
    env.GetContainerNumFreeSlots = function() return 0, 0 end
    env.GetContainerItemLink = function(bag, slot) return link(slots(bag)[slot]) end
    env.GetContainerItemInfo = function(bag, slot)
        local item = slots(bag)[slot]
        local locked = (locks[bag .. ":" .. slot] or 0) > now
        return item and "texture", item and item.count or (options.emptyCount or nil), locked
    end
    env.GetItemInfo = function(id)
        return string.format("Item %05d", id), "item:" .. id, 1, 1, 1, "Trade Goods", "Other", 20, ""
    end
    env.GetAuctionItemClasses = function() return "Trade Goods" end
    env.GetAuctionItemSubClasses = function() return "Other" end
    env.PickupContainerItem = function(bag, slot)
        if beforePickup and beforePickup(bags, bag, slot, cursor, now) then return end
        if (locks[bag .. ":" .. slot] or 0) > now then return end
        local item = slots(bag)[slot]
        if cursor and item and cursor.id == item.id and item.count < 20 then
            local amount = math.min(20 - item.count, cursor.count)
            item.count, cursor.count = item.count + amount, cursor.count - amount
            if cursor.count == 0 then cursor = nil end
        else
            cursor, slots(bag)[slot] = item, cursor
        end
        if options.lockDelay then locks[bag .. ":" .. slot] = now + options.lockDelay end
    end
    env.SplitContainerItem = function(bag, slot, count)
        assert(not cursor, "split with occupied cursor")
        local item = assert(slots(bag)[slot])
        assert(count > 0 and count < item.count, "invalid split")
        cursor = { id = item.id, count = count }
        item.count = item.count - count
    end
    local config = { lockedSlots = options.lockedSlots or {}, bank_fill_from_bags = false }
    local addon = {
        GetModuleConfig = function() return config end,
        IsModuleEnabled = function(_, name) return name == "bagsort" end,
    }
    local chunk = assert(loadfile(modulePath))
    setfenv(chunk, env)
    chunk("DragonUI", addon)
    if options.bank then
        -- Applying the UI is unnecessary for engine tests; the bank flag is
        -- private state on SortBankBags, so set just that upvalue.
        for i = 1, 100 do
            local name = debug.getupvalue(addon.SortBankBags, i)
            if not name then break end
            if name == "bank_open" then debug.setupvalue(addon.SortBankBags, i, true) end
        end
    end
    return {
        bags = bags, addon = addon, messages = messages, locks = locks,
        put = function(bag, slot, id, count) slots(bag)[slot] = { id = id, count = count or 1 } end,
        run = function(limit)
            local moveFrame = frames[1]
            for _ = 1, (limit or 1500) do
                if not moveFrame.shown then break end
                now = now + 0.02
                moveFrame.scripts.OnUpdate(moveFrame, 0.02)
            end
            assert(not moveFrame.shown, "sort did not finish")
            assert(not cursor, "item left on cursor")
            for _, message in ipairs(messages) do
                assert(not message:find("timed out") and not message:find("confused")
                    and not message:find("interrupted"), message)
            end
        end,
    }
end

local function test(name, callback)
    callback()
    tests = tests + 1
    print("PASS " .. name)
end

local function expectItem(inv, bag, slot, id, count)
    local item = inv.bags[bag] and inv.bags[bag][slot]
    assert(item and item.id == id and item.count == (count or 1), "unexpected slot " .. bag .. ":" .. slot)
end

test("swap with numeric cursor ID but no hyperlink", function()
    local inv = newInventory({ noCursorLink = true, lockDelay = 0.25 })
    inv.put(0, 1, 200)
    inv.put(0, 2, 100)
    inv.addon.SortPlayerBags()
    inv.run()
    expectItem(inv, 0, 1, 100)
    expectItem(inv, 0, 2, 200)
end)

test("ordinary swaps and delayed unlocks", function()
    local inv = newInventory({ lockDelay = 0.4 })
    inv.put(0, 1, 300)
    inv.put(0, 2, 200)
    inv.put(0, 4, 100)
    inv.addon.SortPlayerBags()
    inv.run()
    expectItem(inv, 0, 1, 100)
    expectItem(inv, 0, 2, 200)
    expectItem(inv, 0, 3, 300)
end)

test("bag 3 slot 12 to backpack slot 14 with slow item locks", function()
    local inv = newInventory({ noCursorLink = true, lockDelay = 1.5, bagSizes = { [0] = 16, [3] = 12 } })
    for slot = 1, 13 do inv.put(0, slot, 100 + slot) end
    inv.put(0, 14, 200)
    inv.put(3, 12, 114)
    inv.addon.SortPlayerBags()
    inv.run()
    expectItem(inv, 0, 14, 114)
    expectItem(inv, 0, 15, 200)
end)

test("complete and partial stack merges", function()
    local inv = newInventory()
    inv.put(0, 1, 100, 13)
    inv.put(0, 2, 100, 12)
    inv.put(0, 3, 100, 8)
    inv.addon.SortPlayerBags()
    inv.run()
    expectItem(inv, 0, 1, 100, 13)
    expectItem(inv, 0, 2, 100, 20)
    assert(not inv.bags[0][3] and not inv.bags[0][4])
end)

test("rejected pickup with changed bag state replans", function()
    local rejected = false
    local inv = newInventory({ beforePickup = function(bags, bag, slot, cursor)
        if not rejected and not cursor then
            rejected = true
            bags[bag][4], bags[bag][slot] = bags[bag][slot], nil
            return true
        end
    end })
    inv.put(0, 2, 100)
    inv.addon.SortPlayerBags()
    inv.run()
    expectItem(inv, 0, 1, 100)
    assert(not inv.bags[0][4])
end)

test("retry accepts empty-slot count changing from nil to zero", function()
    local rejected = false
    local opts = {}
    opts.beforePickup = function(_, _, _, cursor)
        if not rejected and not cursor then
            rejected = true
            opts.emptyCount = 0
            return true
        end
    end
    local inv = newInventory(opts)
    inv.put(0, 2, 100)
    inv.addon.SortPlayerBags()
    inv.run()
    expectItem(inv, 0, 1, 100)
end)

test("rejected target placement is retried without losing the cursor item", function()
    local rejected = false
    local inv = newInventory({ beforePickup = function(_, _, _, cursor)
        if cursor and not rejected then rejected = true; return true end
    end })
    inv.put(0, 2, 100)
    inv.addon.SortPlayerBags()
    inv.run()
    expectItem(inv, 0, 1, 100)
end)

test("bank sorting can recover a rejected pickup too", function()
    local rejected = false
    local inv = newInventory({ bank = true, beforePickup = function(bags, bag, slot, cursor)
        if not rejected and not cursor then
            rejected = true
            bags[bag][4], bags[bag][slot] = bags[bag][slot], nil
            return true
        end
    end })
    inv.put(-1, 2, 100)
    inv.addon.SortBankBags()
    inv.run()
    expectItem(inv, -1, 1, 100)
end)

test("sort-locked slots stay untouched", function()
    local inv = newInventory({ lockedSlots = { ["0:1"] = true } })
    inv.put(0, 1, 300)
    inv.put(0, 3, 100)
    inv.addon.SortPlayerBags()
    inv.run()
    expectItem(inv, 0, 1, 300)
    expectItem(inv, 0, 2, 100)
end)

test("replan finding no moves finishes and allows a new sort", function()
    local rejected = false
    local inv = newInventory({ beforePickup = function(bags, bag, slot, cursor)
        if not rejected and not cursor then
            rejected = true
            bags[bag][1], bags[bag][slot] = bags[bag][slot], nil
            return true
        end
    end })
    inv.put(0, 2, 100)
    inv.addon.SortPlayerBags()
    inv.run()
    expectItem(inv, 0, 1, 100)
    inv.addon.SortPlayerBags()
    assert(not inv.messages[#inv.messages]:find("already in progress"))
end)

test("randomized stacks preserve every item and finish sorted", function()
    math.randomseed(335)
    for _ = 1, 100 do
        local inv = newInventory({ lockDelay = 0.2 })
        local totals = {}
        for slot = 1, 4 do
            if math.random(4) > 1 then
                local id, count = math.random(3) * 100, math.random(20)
                inv.put(0, slot, id, count)
                totals[id] = (totals[id] or 0) + count
            end
        end
        inv.addon.SortPlayerBags()
        inv.run()
        local lastID, lastCount = 0, 0
        local empty = false
        for slot = 1, 4 do
            local item = inv.bags[0] and inv.bags[0][slot]
            if item then
                assert(not empty, "gap before sorted items")
                assert(item.id >= lastID, "items out of order")
                if item.id == lastID then assert(item.count >= lastCount, "stacks out of order") end
                lastID, lastCount = item.id, item.count
                totals[item.id] = totals[item.id] - item.count
            else
                empty = true
            end
        end
        for _, count in pairs(totals) do assert(count == 0, "item count changed") end
    end
end)

print(string.format("%d bagsort tests passed", tests))
