-- Item ledger: finds what scripts did to an online player's items without telling anyone.
-- Why: an inventory only reports part of an item's life. ox_inventory has no event at all for RemoveItem, so a script that
-- takes an item leaves no trace, and an item's net count drifts away from the truth.
-- How: an inventory adapter gives `read(src)`; adapters report the changes they saw with `note`; each player is read once per
-- interval, and what the count did beyond the notes is sent as item.create or item.remove marked `inferred`.
-- Budget: one player read at a time, spread over the interval, never inside a hook.

local cfg = AtlasConfig

local L = {}
Atlas.itemLedger = L

local reader     -- reader: function(src) returning { item = count }, or nil when the player's items cannot be read
local isSkipped  -- isSkipped: function(item) returning true for items the ledger leaves alone (money kept as items)
local state = {} -- state[src]: { char, counts, seen } where seen is what adapters reported since the last read

--- Use: sets the source of a player's item counts; nil turns the ledger off.
function L.use(read, skip)
    reader, isSkipped = read, skip
    state = {}
end

--- Note: an adapter saw this player's count of an item change by delta; ignored until the player has been read once.
function L.note(src, item, delta)
    local s = state[src]
    if s and type(item) == 'string' and delta then s.seen[item] = (s.seen[item] or 0) + delta end
end

--- Difference: what a read shows beyond the notes, per item; only whole units count, since a fraction is durability.
--- @return table residual { item = whole count }
function L.residual(before, after, seen)
    local out = {}
    local function check(item)
        local d = (after[item] or 0) - (before[item] or 0) - (seen[item] or 0)
        d = d >= 0 and math.floor(d + 0.5) or math.ceil(d - 0.5)
        if d ~= 0 then out[item] = d end
    end
    for item in pairs(after) do check(item) end
    for item in pairs(before) do if after[item] == nil then check(item) end end
    return out
end

--- Check: reads one player and reports the changes no adapter saw; a new character only sets the starting point.
function L.check(src)
    if not reader then return end
    local p = Atlas.players[src]
    if not p or not p.char then state[src] = nil return end
    local ok, counts = pcall(reader, src)
    if not ok or type(counts) ~= 'table' then return end
    local s = state[src]
    if not s or s.char ~= p.char then
        state[src] = { char = p.char, counts = counts, seen = {} }
        return
    end
    local gaps = L.residual(s.counts, counts, s.seen)
    s.counts, s.seen = counts, {}
    for item, d in pairs(gaps) do
        if not (isSkipped and isSkipped(item)) then
            local holder = { kind = 'player', id = p.char }
            if d > 0 then
                Atlas.emit('item.create', { item = item, count = d, to = holder, inferred = true }, src)
            else
                Atlas.emit('item.remove', { item = item, count = -d, from = holder, inferred = true }, src)
            end
        end
    end
end

Atlas.onDrop(function(p) if p.src then state[p.src] = nil end end)

-- Loop: goes through the online players in turn, spread over the interval.
CreateThread(function()
    if cfg.itemLedgerSec <= 0 then return end
    local turn = 0
    while true do
        local list = Atlas.playerList
        local count = #list
        Wait(math.max(50, math.floor(cfg.itemLedgerSec * 1000 / math.max(count, 1))))
        if reader and Atlas.enabled and count > 0 then
            turn = turn % #list + 1
            local src = list[turn]
            if src then L.check(src) end
        end
    end
end)
