-- qb-inventory adapter: item events through qb-inventory listeners (built against 2.2.3; listeners came with it in 2026).
-- Listeners: run after the action, so they report what happened; older qb-inventory versions and forks have none,
-- and on those servers only the daily census counts items.
-- Holders: trunks and gloveboxes are named by a hash of the plate, as in the census, never by the plate.

local cfg = AtlasConfig
local NAME = 'qb_inventory'
local GIVE_TO = '^Item given to ID #(%d+)' -- GIVE_TO: qb-inventory's reason when a player hands an item to another
local SKIP_ADDED = { ['shop-purchase'] = true } -- SKIP_ADDED: item additions already sent as item.buy

local registered = {} -- registered: { event, index } of each listener, removed again before a new attach

local function active() return Atlas.enabled and Atlas.adapterActive(NAME) and Atlas.adapterActive('qbcore') end

local function srcOf(v)
    v = tonumber(v)
    return (v and Atlas.players[v]) and v or nil
end

--- Holder: an inventory as { kind, id }; a player is named by character, other inventories by their qb-inventory name.
local function holder(kind, id)
    if kind == 'player' or type(id) == 'number' then
        local n = tonumber(id) or tonumber(tostring(id):match('^otherplayer%-(%d+)$'))
        return { kind = 'player', id = n and (Atlas.charOf(n) or tostring(n)) or tostring(id) }
    end
    if kind == 'drop' then return { kind = 'drop', id = tostring(id) } end
    local k, hid = Atlas.frameworkData.qbcore.holder(id)
    return { kind = k, id = hid }
end

--- Listener wrapper: runs the body and never raises an error, since qb-inventory calls it inside its own action.
local function listen(fn)
    return function(kind, data)
        if not active() or type(data) ~= 'table' then return end
        local ok, err = pcall(fn, kind, data)
        if not ok then
            Atlas.drop('qb_inventory_listener_error')
            Atlas.debug('qb-inventory listener error: %s', tostring(err))
        end
    end
end

--- Slot item: the item in a slot of an inventory snapshot, read after the move.
local function slotItem(inv, slot)
    local items = type(inv) == 'table' and inv.items
    local it = type(items) == 'table' and (items[slot] or items[tostring(slot)])
    return type(it) == 'table' and type(it.name) == 'string' and it or nil
end

-- Moved: moves, stacks, splits and swaps between two inventories; a swap also sends the item that went the other way.
local onMoved = listen(function(moveType, d)
    if moveType == 'given' then return end -- Give: sent from ItemRemoved, which names the item
    if d.fromId == d.toId then return end
    local from, to = holder(d.fromType, d.fromId), holder(d.toType, d.toId)
    local action = (to.kind == 'drop' and 'drop') or (from.kind == 'drop' and 'pickup') or (moveType == 'swapped' and 'swap') or 'move'
    local src = srcOf(from.kind == 'player' and d.fromId) or srcOf(to.kind == 'player' and d.toId)
    local moved = slotItem(d.toInventory, d.toSlot)
    if not moved then return end
    local count = moveType == 'swapped' and tonumber(moved.amount) or tonumber(d.amount) or tonumber(moved.amount) or 1
    Atlas.emit('item.move', { item = moved.name, count = count, from = from, to = to, action = action }, src)
    local back = moveType == 'swapped' and slotItem(d.fromInventory, d.fromSlot)
    if back then
        Atlas.emit('item.move', { item = back.name, count = tonumber(back.amount) or 1, from = to, to = from, action = 'swap' }, src)
    end
end)

-- Dropped: an item put on the ground from the player's inventory.
local onDropped = listen(function(_, d)
    local it = type(d.item) == 'table' and d.item
    if not it or type(it.name) ~= 'string' then return end
    local src = srcOf(d.source)
    Atlas.emit('item.move', {
        item = it.name, count = tonumber(d.amount) or tonumber(it.amount) or 1,
        from = holder('player', d.source), to = { kind = 'drop', id = 'ground' }, action = 'drop',
    }, src)
end)

-- Removed: a give between players is told only here, with the receiving player's id in the reason.
local onRemoved = listen(function(_, d)
    local target = type(d.reason) == 'string' and tonumber(d.reason:match(GIVE_TO))
    local it = type(d.item) == 'table' and d.item
    if not target or not it or type(it.name) ~= 'string' then return end
    local from, to = holder('player', d.fromId), holder('player', target)
    Atlas.emit('item.move', {
        item = it.name, count = tonumber(d.amount) or 1, from = from, to = to, action = 'give',
        counterparty_char = Atlas.charOf(target),
    }, srcOf(d.fromId))
end)

-- Added: items a script creates; fires for every AddItem, so it is off unless enabled.
local onAdded = listen(function(_, d)
    local it = type(d.item) == 'table' and d.item
    if not it or type(it.name) ~= 'string' then return end
    local reason = type(d.reason) == 'string' and d.reason or ''
    if SKIP_ADDED[reason] or reason:find('^Item given from ID #') then return end
    local to = holder(d.toType, d.toId)
    Atlas.emit('item.create', { item = it.name, count = tonumber(d.amount) or 1, to = to }, to.kind == 'player' and srcOf(d.toId) or nil)
end)

local onUsed = listen(function(_, d)
    local it = type(d.item) == 'table' and d.item
    if not it or type(it.name) ~= 'string' then return end
    Atlas.emit('item.use', { item = it.name, count = 1 }, srcOf(d.source))
end)

local onBought = listen(function(shopType, d)
    local it = type(d.item) == 'table' and d.item
    if not it or type(it.name) ~= 'string' then return end
    local shop = type(d.shop) == 'table' and d.shop.name or shopType
    local count = tonumber(d.amount) or 1
    Atlas.emit('item.buy', {
        item = it.name, count = count, shop = tostring(shop or '?'),
        price_each = tonumber(it.price) or ((tonumber(d.totalPrice) or 0) / count), currency = 'money',
    }, srcOf(d.toId))
end)

local onShopOpened = listen(function(shopType, d)
    local shop = type(d.shop) == 'table' and d.shop.name or shopType
    Atlas.emit('place.visit', { place_ref = 'shop:' .. tostring(shop or '?'), kind = 'shop' }, srcOf(d.source))
end)

local onOpened = listen(function(kind, d)
    if kind ~= 'inventory' or type(d.inventoryId) ~= 'string' then return end
    Atlas.emit('place.visit', { place_ref = 'stash:' .. d.inventoryId, kind = 'stash' }, srcOf(d.source))
end)

--- Catalog: items.catalog sends item names, labels and weights from qb-core's shared items.
local function itemsCatalog()
    local ok, list = pcall(function() return exports['qb-core']:GetShared('Items') end)
    if not ok or type(list) ~= 'table' then
        local core = Atlas.frameworkData.qbcore.core()
        list = core and type(core.Shared) == 'table' and core.Shared.Items
    end
    if type(list) ~= 'table' then return end
    local entries = {}
    for name, item in pairs(list) do
        if type(name) == 'string' and type(item) == 'table' then
            entries[#entries + 1] = { name, type(item.label) == 'string' and item.label or name, tonumber(item.weight) or 0 }
        end
    end
    table.sort(entries, function(a, b) return a[1] < b[1] end)
    for i = 1, #entries, 500 do
        Atlas.emit('items.catalog', { entries = { table.unpack(entries, i, math.min(i + 499, #entries)) } })
    end
end

Atlas.registerAdapter({
    name = NAME,
    resources = { 'qb-core', 'qb-inventory' },
    attach = function()
        local inv = exports['qb-inventory']
        for _, r in ipairs(registered) do pcall(function() inv:RemoveListener(r[1], r[2]) end) end
        registered = {}
        local function add(event, fn)
            local ok, idx = pcall(function() return inv:AddListener(event, fn) end)
            if ok and idx then registered[#registered + 1] = { event, idx } end
            return ok
        end
        -- Listeners: a version without them throws on the first call, which leaves only the census
        if not add('ItemMoved', onMoved) then
            Atlas.log('qb-inventory has no listeners in this version, so only the daily census counts items')
        else
            add('ItemDropped', onDropped)
            add('ItemRemoved', onRemoved)
            add('ItemUsed', onUsed)
            add('ItemBought', onBought)
            if cfg.qbCreateItem then add('ItemAdded', onAdded) end
            if cfg.placeVisits then
                add('ShopOpened', onShopOpened)
                add('InventoryOpened', onOpened)
            end
        end
        CreateThread(function()
            -- Catalog: sent once the QBCore adapter holds the framework, which may attach a moment later
            for _ = 1, 30 do
                if Atlas.adapterActive('qbcore') then return itemsCatalog() end
                Wait(1000)
            end
        end)
    end,
})
