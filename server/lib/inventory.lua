-- Inventory: turns ox_inventory hook data into item events.
-- Checked against ox_inventory 2.45.0.

AtlasLib = AtlasLib or {}
local M = {}

-- Holder kind: maps the ox_inventory type to the kind used in events
local KIND = {
    player = 'player', stash = 'stash', trunk = 'trunk', glovebox = 'glovebox',
    drop = 'drop', newdrop = 'drop', container = 'container', shop = 'shop',
    crafting = 'crafting', policeevidence = 'stash', dumpster = 'stash',
}

function M.kind(oxType)
    if type(oxType) ~= 'string' then return 'unknown' end
    return KIND[oxType] or oxType:sub(1, 24)
end

--- Holder kind from id: guesses the kind from the inventory id, since createItem only gives the id.
function M.kindFromId(id)
    if type(id) == 'number' then return 'player' end
    if type(id) ~= 'string' then return 'unknown' end
    if id:find('^trunk') then return 'trunk' end
    if id:find('^glove') then return 'glovebox' end
    if id:find('^drop') then return 'drop' end
    return 'stash'
end

--- Holder: { kind, id }; players use their character id when known, otherwise the server id.
local function ref(kind, id, charOf)
    if kind == 'player' and type(id) == 'number' then
        return { kind = kind, id = charOf(id) or tostring(id) }
    end
    return { kind = kind, id = tostring(id) }
end
M.ref = ref

--- Census inventory: a stored inventory in the form the daemon reads, which is a list of items or a table of slots.
--- ESX's own inventory is a { name = count } table, so it becomes a list; any other form goes as stored.
--- @param raw string? stored inventory text
--- @param json table { decode, encode }
--- @return string
function M.census(raw, json)
    if type(raw) ~= 'string' or raw == '' then return '[]' end
    if not raw:find('^%s*{') then return raw end
    local ok, map = pcall(json.decode, raw)
    if not ok or type(map) ~= 'table' then return '[]' end
    local list = {}
    for name, count in pairs(map) do
        if type(count) ~= 'number' then return raw end
        if count > 0 then list[#list + 1] = { name = tostring(name), count = count } end
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return json.encode(list)
end

--- Swap items: turns a swapItems payload (move, stack, swap, give) into 0, 1 or 2 item.move tables.
--- Moves inside one inventory are ignored.
--- @param p table hook payload
--- @param charOf fun(src: integer): string?
--- @return table[]? moves
function M.mapSwap(p, charOf)
    if type(p) ~= 'table' then return nil end
    local fromId, toId = p.fromInventory, p.toInventory
    if fromId == toId then return nil end
    local fs = p.fromSlot
    if type(fs) ~= 'table' or type(fs.name) ~= 'string' then return nil end

    local fromKind, toKind = M.kind(p.fromType), M.kind(p.toType)
    if toId == 'newdrop' then toId = p.dropId or 'newdrop' end

    local action
    if p.action == 'give' then action = 'give'
    elseif toKind == 'drop' then action = 'drop'
    elseif fromKind == 'drop' then action = 'pickup'
    elseif p.action == 'swap' then action = 'swap'
    else action = 'move' end

    local from, to = ref(fromKind, fromId, charOf), ref(toKind, toId, charOf)

    -- Other player: set for a give, or a move to or from another player's inventory
    local counterparty
    local src = p.source
    if toKind == 'player' and toId ~= src and type(toId) == 'number' then counterparty = charOf(toId)
    elseif fromKind == 'player' and fromId ~= src and type(fromId) == 'number' then counterparty = charOf(fromId) end

    -- A swap exchanges whole slots; otherwise `count` is what moved
    local count = (p.action == 'swap' and tonumber(fs.count)) or tonumber(p.count) or tonumber(fs.count) or 1

    local moves = { { item = fs.name, count = count, from = from, to = to, action = action, counterparty_char = counterparty } }

    local ts = p.toSlot
    if p.action == 'swap' and type(ts) == 'table' and type(ts.name) == 'string' then
        moves[2] = {
            item = ts.name, count = tonumber(ts.count) or 1, from = to, to = from,
            action = 'swap', counterparty_char = counterparty,
        }
    end
    return moves
end

--- Buy item: converts a buyItem payload into item.buy data.
function M.mapBuy(p)
    if type(p) ~= 'table' or type(p.itemName) ~= 'string' then return nil end
    local shop = tostring(p.shopType or '?')
    if p.shopId then shop = shop .. ':' .. tostring(p.shopId) end
    return {
        item = p.itemName,
        count = tonumber(p.count) or 1,
        shop = shop,
        price_each = tonumber(p.price) or 0,
        currency = type(p.currency) == 'string' and p.currency or 'money',
    }
end

--- Craft item: turns a craftItem payload into item.craft data.
function M.mapCraft(p)
    if type(p) ~= 'table' or type(p.recipe) ~= 'table' then return nil end
    local r = p.recipe
    if type(r.name) ~= 'string' then return nil end
    local ins = {}
    if type(r.ingredients) == 'table' then
        for name, n in pairs(r.ingredients) do
            ins[#ins + 1] = { tostring(name), tonumber(n) or 0 }
        end
        table.sort(ins, function(a, b) return a[1] < b[1] end)
    end
    return {
        recipe = tostring(p.benchId or '?') .. ':' .. r.name,
        out = { { r.name, tonumber(r.count) or 1 } },
        ['in'] = ins,
    }
end

AtlasLib.inventory = M
return M
