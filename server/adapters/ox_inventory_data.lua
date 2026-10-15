-- ox_inventory data: stash census, shop places and shop prices, which are the same on every framework.

local sandbox = AtlasLib.sandbox
local db = Atlas.db

--- Shops: the shop definitions of ox_inventory, read from its data file.
local function shops()
    local list = Atlas.loadConfig('ox_inventory', 'data/shops.lua')
    return type(list) == 'table' and list or nil
end

-- Stashes: owner is NULL or '' for shared stashes.
Atlas.registerSource('census', {
    name = 'ox_stashes',
    resources = { 'ox_inventory' },
    kind = 'stash', order = 20, delta = true,
    count = function(since)
        return db.scalar('SELECT COUNT(*) FROM ox_inventory' .. (since and ' WHERE lastupdated >= FROM_UNIXTIME(?)' or ''), since and { since } or {})
    end,
    page = function(since, cursor, per)
        local params = since and { since } or {}
        params[#params + 1] = cursor and cursor[1] or ''
        params[#params + 1] = cursor and cursor[2] or ''
        local rows = db.query(([[SELECT COALESCE(owner, '') AS o, name, data FROM ox_inventory
            WHERE %s (COALESCE(owner, ''), name) > (?, ?) ORDER BY COALESCE(owner, ''), name LIMIT %d]]):format(
            since and 'lastupdated >= FROM_UNIXTIME(?) AND' or '', per), params)
        if type(rows) ~= 'table' then return nil end
        local out = {}
        for i = 1, #rows do
            local r = rows[i]
            out[i] = { r.o == '' and r.name or (r.name .. ':' .. r.o), r.data or '[]' }
        end
        local l = rows[#rows]
        return out, l and { l.o, l.name }, #rows
    end,
})

Atlas.registerSource('places', {
    name = 'ox_shops',
    resources = { 'ox_inventory' },
    read = function(add)
        local list = shops()
        if not list then return end
        for id, shop in pairs(list) do
            if type(shop) == 'table' then
                local name = type(shop.name) == 'string' and shop.name or tostring(id)
                if type(shop.locations) == 'table' then
                    for _, loc in sandbox.items(shop.locations) do add(name, 'shop', loc) end
                elseif type(shop.targets) == 'table' then
                    for _, t in sandbox.items(shop.targets) do add(name, 'shop', type(t) == 'table' and (t.loc or t.coords)) end
                end
            end
        end
    end,
})

Atlas.registerSource('prices', {
    name = 'ox_shops',
    resources = { 'ox_inventory' },
    read = function(emit)
        local list = shops()
        if not list then return end
        local entries, seen = {}, {}
        for shopType, shop in pairs(list) do
            if type(shop) == 'table' and type(shop.inventory) == 'table' then
                for _, it in sandbox.items(shop.inventory) do
                    if type(it) == 'table' and type(it.name) == 'string' and tonumber(it.price) then
                        local key = it.name .. '@' .. shopType
                        if not seen[key] then
                            seen[key] = true
                            entries[#entries + 1] = { it.name, '', tonumber(it.price), tostring(shopType) }
                        end
                    end
                end
            end
        end
        emit('item', entries)
    end,
})
