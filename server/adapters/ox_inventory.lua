-- ox_inventory adapter: registers hooks through exports.ox_inventory:registerHook (built against 2.45.0).
-- Hooks: run synchronously before the action applies, so callbacks never yield and return true to avoid cancelling it.

local cfg = AtlasConfig
local inv = AtlasLib.inventory
local NAME = 'ox_inventory'

local accountItems = { money = true } -- accountItems: money-as-item accounts (inventory:accounts)

--- Hook wrapper: runs the body, never throws, always returns true.
--- Accuracy: a hook means the action was allowed, not completed; the daily item census reconciles totals.
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

local onSwap = hook(function(p)
    local moves = inv.mapSwap(p, Atlas.charOf)
    if not moves then return end
    local src = srcOf(p.source)
    for i = 1, #moves do Atlas.emit('item.move', moves[i], src) end
end)

local onBuy = hook(function(p)
    local data = inv.mapBuy(p)
    if data then Atlas.emit('item.buy', data, srcOf(p.source)) end
end)

local onCraft = hook(function(p)
    local data = inv.mapCraft(p)
    if data then Atlas.emit('item.craft', data, srcOf(p.source)) end
end)

local onUse = hook(function(p)
    local item = type(p.item) == 'table' and p.item.name
    if type(item) ~= 'string' then return end
    -- Consume: item count consumed, or a fraction for durability items
    Atlas.emit('item.use', { item = item, count = tonumber(p.consume) or 1 }, srcOf(p.source))
end)

local onCreate = hook(function(p)
    local item = type(p.item) == 'table' and p.item.name
    if type(item) ~= 'string' or accountItems[item] then return end
    local id = p.inventoryId
    local kind = inv.kindFromId(id)
    Atlas.emit('item.create', {
        item = item,
        count = tonumber(p.count) or 1,
        to = inv.ref(kind, id or '?', Atlas.charOf),
    }, kind == 'player' and srcOf(id) or nil)
end)

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
        -- Money items: qbx mirrors accounts as items after every money change, so money.change already covers them
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
        -- typeFilter: lets ox skip the cross-resource call for other inventory types
            ox:registerHook('openInventory', onOpenStash, { print = false, typeFilter = { stash = true } })
        end

        CreateThread(itemsCatalog)
    end,
})
