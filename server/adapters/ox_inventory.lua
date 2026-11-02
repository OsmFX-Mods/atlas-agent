-- ox_inventory adapter: listens through ox_inventory hooks (built against 2.45.0).
-- Hooks: run before the action happens, so they never wait and always return true to allow it.

local cfg = AtlasConfig
local inv = AtlasLib.inventory
local NAME = 'ox_inventory'

local accountItems = { money = true } -- accountItems: money kept as items (inventory:accounts)

--- Account item: money kept as an item mirrors a framework account, so the framework's money events already cover it.
local function isAccountItem(name)
    if accountItems[name] then return true end
    local list = Atlas.framework and Atlas.framework.inventoryAccounts
    for i = 1, list and #list or 0 do
        if list[i] == name then return true end
    end
    return false
end

--- Hook wrapper: runs the body, never raises an error and always returns true.
--- A hook fires before the action finishes, so the daily item census corrects any difference.
local function hook(fn)
    return function(payload)
        if not Atlas.enabled then return true end
        local ok, err = pcall(fn, payload)
        if not ok then
            Atlas.drop('ox_hook_error')
            Atlas.debug('ox_inventory hook error: %s', tostring(err))
        end
        return true
    end
end

local function srcOf(v)
    v = tonumber(v)
    return (v and Atlas.players[v]) and v or nil
end

local ledger = Atlas.itemLedger

--- Note move: tells the item ledger about one side of a move that holds a player, so it is not counted as unexplained.
local function noteSide(holder, item, delta)
    if holder.kind ~= 'player' then return end
    local s = Atlas.charToSrc[holder.id] or tonumber(holder.id)
    if s then ledger.note(s, item, delta) end
end

local onSwap = hook(function(p)
    local moves = inv.mapSwap(p, Atlas.charOf)
    if not moves then return end
    local src = srcOf(p.source)
    for i = 1, #moves do
        local m = moves[i]
        noteSide(m.from, m.item, -m.count)
        noteSide(m.to, m.item, m.count)
        Atlas.emit('item.move', m, src)
    end
end)

local onBuy = hook(function(p)
    local data = inv.mapBuy(p)
    if not data then return end
    local src = srcOf(p.source)
    if src then ledger.note(src, data.item, data.count) end
    Atlas.emit('item.buy', data, src)
end)

local onCraft = hook(function(p)
    local data = inv.mapCraft(p)
    if not data then return end
    local src = srcOf(p.source)
    if src then
        for _, o in ipairs(data.out) do ledger.note(src, o[1], o[2]) end
        for _, i in ipairs(data['in']) do ledger.note(src, i[1], -i[2]) end
    end
    Atlas.emit('item.craft', data, src)
end)

local using = {} -- using[src]: what the player started using; it only counts once the game says it finished

-- Using: fires when a use starts, and the player can still cancel it, so nothing is counted yet.
local onUse = hook(function(p)
    local item = type(p.item) == 'table' and p.item.name
    local src = srcOf(p.source)
    if type(item) ~= 'string' or not src then return end
    using[src] = { item = item, consume = tonumber(p.consume) or 1 }
end)

-- Used: the use finished. Consume: item count consumed, or a fraction for durability items.
AddEventHandler('ox_inventory:usedItem', function(playerId, name)
    if not Atlas.enabled or not Atlas.adapterActive(NAME) then return end
    local src = srcOf(playerId)
    local u = src and using[src]
    if src then using[src] = nil end
    if not src or type(name) ~= 'string' then return end
    local consume = u and u.item == name and u.consume or 1
    if consume >= 1 then ledger.note(src, name, -consume) end
    Atlas.emit('item.use', { item = name, count = consume }, src)
end)

Atlas.onDrop(function(p) if p.src then using[p.src] = nil end end)

--- Made elsewhere: an item made for a shop purchase or a craft has its own event, and a bridge only converts an old inventory.
local function isCounted(frames)
    for _, f in ipairs(frames) do
        if f.res == NAME and (f.path:find('modules/shops/', 1, true) or f.path:find('modules/crafting/', 1, true) or f.path:find('modules/bridge/', 1, true)) then
            return true
        end
    end
    return false
end

-- Created: an item that came out of nothing; the stack names the script that asked for it, or a staff command.
local onCreate = hook(function(p)
    local item = type(p.item) == 'table' and p.item.name
    if type(item) ~= 'string' or isAccountItem(item) then return end
    local frames = Atlas.attribution.frames()
    if isCounted(frames) then return end
    local res, origin, kind = Atlas.attribution.pick(frames)
    local id = p.inventoryId
    local where = inv.kindFromId(id)
    local count = tonumber(p.count) or 1
    local src = where == 'player' and srcOf(id) or nil
    if src then ledger.note(src, item, count) end
    Atlas.emit('item.create', {
        item = item,
        count = count,
        to = inv.ref(where, id or '?', Atlas.charOf),
        origin = origin,
        caller = kind,
    }, src, { res = res or (type(p.resource) == 'string' and p.resource) or nil })
end)

--- Items of a player: what they hold now, by item name, for the item ledger.
local function readItems(src)
    local items = exports.ox_inventory:GetInventoryItems(src)
    if type(items) ~= 'table' then return nil end
    local counts = {}
    for _, it in pairs(items) do
        if type(it) == 'table' and type(it.name) == 'string' then
            counts[it.name] = (counts[it.name] or 0) + (tonumber(it.count) or 0)
        end
    end
    return counts
end

local onOpenShop = hook(function(p)
    local ref = 'shop:' .. tostring(p.shopType or '?')
    if p.shopId then ref = ref .. ':' .. tostring(p.shopId) end
    Atlas.emit('place.visit', { place_ref = ref, kind = 'shop' }, srcOf(p.source))
end)

local onOpenStash = hook(function(p)
    Atlas.emit('place.visit', { place_ref = 'stash:' .. tostring(p.inventoryId), kind = 'stash' }, srcOf(p.source))
end)

--- Catalog: items.catalog sends item names, labels and weights, on attach and on ox_inventory restart.
local function itemsCatalog()
    local ok, list = pcall(function() return exports.ox_inventory:Items() end)
    if not ok or type(list) ~= 'table' then
        Atlas.debug('items.catalog: ox_inventory Items() unavailable')
        return
    end
    local entries = {}
    for name, item in pairs(list) do
        if type(name) == 'string' and type(item) == 'table' then
            entries[#entries + 1] = {
                name,
                type(item.label) == 'string' and item.label or name,
                tonumber(item.weight) or 0,
            }
        end
    end
    table.sort(entries, function(a, b) return a[1] < b[1] end)
    for i = 1, #entries, 500 do
        Atlas.emit('items.catalog', { entries = { table.unpack(entries, i, math.min(i + 499, #entries)) } })
    end
end

Atlas.registerAdapter({
    name = NAME,
    resources = { 'ox_inventory' },
    attach = function()
        local ox = exports.ox_inventory
        -- Money items: the framework mirrors accounts as items after every money change, so money.change already covers them
        accountItems = { money = true }
        for name in GetConvar('inventory:accounts', '["money"]'):gmatch('"([^"]+)"') do accountItems[name] = true end

        -- Re-attach: removes any hooks of ours left by a partial attempt
        ox:removeHooks()

        local opts = { print = false }
        ox:registerHook('swapItems', onSwap, opts)
        ox:registerHook('buyItem', onBuy, opts)
        ox:registerHook('craftItem', onCraft, opts)
        ox:registerHook('usingItem', onUse, opts)
        if cfg.oxCreateItem then ox:registerHook('createItem', onCreate, opts) end
        if cfg.placeVisits then
            ox:registerHook('openShop', onOpenShop, opts)
            -- typeFilter: lets ox_inventory skip the call for other inventory types
            ox:registerHook('openInventory', onOpenStash, { print = false, typeFilter = { stash = true } })
        end

        Atlas.attribution.addCore(NAME, 'inventory')
        Atlas.inventory = NAME
        ledger.use(readItems, isAccountItem)

        CreateThread(itemsCatalog)
    end,
    detach = function()
        if Atlas.inventory == NAME then Atlas.inventory = nil end
        ledger.use(nil)
    end,
})
