-- ESX adapter: maps es_extended events to Atlas events (built against ESX Legacy 1.16.0, checked against 1.13 to 1.15).
-- Source: signals verified in es_extended server/modules/player, server/classes/player and the ox_inventory override.
-- Events: esx:playerLoaded, esx:playerDropped, esx:setJob and the three account events keep their arguments from 1.9.4 on.
-- Data: the database readers for snapshots, and the places and prices ESX resources provide, are in esx_data.lua.
-- Not covered: character deletion and vehicle purchases have no server event in ESX, so snapshots pick them up instead.

local cfg = AtlasConfig
local C, M = Atlas.characters, Atlas.money
local NAME = 'esx'
local SYNC_REASON = 'Sync account with item' -- SYNC_REASON: what ESX reports when it copies an ox_inventory money item into an account

local data = Atlas.frameworkData.esx
local ESX -- ESX: the shared object of es_extended, read when the adapter attaches
local static = false -- static: true when es_extended can run one xPlayer method by export (newer versions, 1.13 on at least)

local function active() return Atlas.enabled and Atlas.adapterActive(NAME) end

--- Player: the live xPlayer of a source, or nil.
local function playerOf(src)
    local ok, x = pcall(ESX.GetPlayerFromId, src)
    return ok and type(x) == 'table' and x or nil
end

--- Balances: the account balances of an xPlayer by money type.
local function balances(xPlayer)
    local ok, accounts = pcall(xPlayer.getAccounts, true)
    if not ok or type(accounts) ~= 'table' then return nil end
    return data.slots(accounts)
end

--- Live balances: the current balances of a source by money type; the export avoids copying the whole xPlayer on every money event.
local function liveBalances(src)
    if not static then
        local xPlayer = playerOf(src)
        return xPlayer and balances(xPlayer)
    end
    local ok, accounts = pcall(function() return exports.es_extended:RunStaticPlayerMethod(src, 'getAccounts', true) end)
    if not ok or type(accounts) ~= 'table' then return nil end
    return data.slots(accounts)
end

local function isDead(src)
    local ok, dead = pcall(function() return Player(src).state.isDead end)
    return ok and dead == true
end

-- Identity: reads character, job and balances from the xPlayer.
local function charNameOf(xPlayer)
    local vars = type(xPlayer.variables) == 'table' and xPlayer.variables or {}
    if type(vars.firstName) == 'string' and vars.firstName ~= '' then
        return ('%s %s'):format(vars.firstName, type(vars.lastName) == 'string' and vars.lastName or '')
    end
end

local function charStart(src, xPlayer, isNew, resumed)
    local identifier = xPlayer.identifier
    if type(identifier) ~= 'string' or identifier == '' then return end
    local ok, job = pcall(xPlayer.getJob)
    if not ok or type(job) ~= 'table' then job = {} end
    C.load(src, {
        char = identifier,
        name = charNameOf(xPlayer),
        job = job.name,
        grade = tonumber(job.grade),
        duty = job.onDuty == true,
        money = balances(xPlayer),
        dead = isDead(src),
        isNew = isNew == true,
        resumed = resumed,
    })
end

-- playerLoaded: server-side after login or character selection; emits session.char_start, plus character.create for new characters.
AddEventHandler('esx:playerLoaded', function(src, xPlayer, isNew)
    if not active() or type(xPlayer) ~= 'table' then return end
    src = tonumber(src)
    if not src then return end
    local p = Atlas.players[src]
    if p and p.char == xPlayer.identifier then return end
    if p and p.char then C.unload(p, 'switch') end
    charStart(src, xPlayer, isNew, false)
end)

-- playerDropped: fired for a disconnect and for a logout to the character screen; emits session.char_end.
-- Reason: 'esx_player_logout' is the logout, anything else is a disconnect.
AddEventHandler('esx:playerDropped', function(src, reason)
    if not active() then return end
    local p = Atlas.players[tonumber(src)]
    if p then C.unload(p, reason == 'esx_player_logout' and 'logout' or 'drop') end
end)

-- setJob: primary job or grade changes, and duty changes of the same job; emits job.change or duty.change.
AddEventHandler('esx:setJob', function(src, job)
    if not active() or type(job) ~= 'table' then return end
    src = tonumber(src)
    local p = Atlas.players[src]
    if not p or not p.char then return end
    local grade = tonumber(job.grade)
    local duty -- duty: left as it is for versions that do not send it
    if job.onDuty ~= nil then duty = job.onDuty == true end
    if duty ~= nil and p.job == job.name and p.grade == grade then
        C.setDuty(src, duty)
    end
    C.setJob(src, job.name, grade, duty)
end)

-- Money: ESX reports every change after it has been applied, with the account name, amount and reason.
-- Reason: ESX fills in 'Unknown' when a script gives none.
local function reasonOf(reason)
    if type(reason) ~= 'string' or reason == '' or reason:lower() == 'unknown' then return 'unknown' end
    return reason
end

-- Sync: with ox_inventory on ESX 1.16 a money change is reported twice, first as a set with SYNC_REASON and then as the real add or remove.
-- Older versions update the account first, so the sync set only comes for changes made in the inventory itself.
-- Held: the set waits one frame; the real event with the same balance replaces it, otherwise it is sent as it was.
local held = {} -- held: held[src][account] = the set event waiting for its real event

local function release(src, account)
    local h = held[src] and held[src][account]
    if not h then return end
    held[src][account] = nil
    M.emit(src, Atlas.players[src], h.slot, 'set', h.amount, h.delta, h.balance, h.reason, h.at)
end

M.onFlush(function(src)
    for account in pairs(held[src] or {}) do release(src, account) end
    held[src] = nil
end)

local function onMoney(action)
    return function(src, account, amount, reason)
        if not active() then return end
        src, amount = tonumber(src), tonumber(amount)
        if not src or not amount or type(account) ~= 'string' then return end
        account = account:lower()
        local slot = cfg.esx.accounts[account] -- slot: the money type this account counts as
        if type(slot) ~= 'string' or slot == '' then return end

        local p = Atlas.players[src]
        local live = liveBalances(src)
        local balance = live and live[slot] or nil
        reason = reasonOf(reason)

        if action == 'set' and reason == SYNC_REASON then
            release(src, account)
            local prev = p and p.money[slot]
            local h = {
                slot = slot, amount = amount, balance = balance, reason = reason, at = Atlas.now(), prev = prev,
                delta = M.apply(p, slot, 'set', amount, balance),
            }
            held[src] = held[src] or {}
            held[src][account] = h
            CreateThread(function()
                Wait(0)
                if held[src] and held[src][account] == h then release(src, account) end
            end)
            return
        end

        local last -- last: the balance before a held set moved it, so a set that follows is measured from the right start
        local h = held[src] and held[src][account]
        if h then
            if balance ~= nil and h.balance == balance then
                held[src][account] = nil
                last = h.prev
            else
                release(src, account)
            end
        end
        local delta = M.apply(p, slot, action, amount, balance, last)
        M.emit(src, p, slot, action, amount, delta, balance, reason)
    end
end

AddEventHandler('esx:addAccountMoney', onMoney('add'))
AddEventHandler('esx:removeAccountMoney', onMoney('remove'))
AddEventHandler('esx:setAccountMoney', onMoney('set'))

-- Items: ESX without ox_inventory keeps item names in the items table; with it, the ox adapter sends the catalog.
-- ox_inventory: ESX switches to it whenever it is installed, even when it starts later, so the same check is used here.
local function itemsCatalog()
    if GetResourceState('ox_inventory') ~= 'missing' or not Atlas.db.available() then return end
    local name = AtlasLib.common.sqlName(cfg.esx.tables.items)
    if not name then return Atlas.warn('config: esx.tables.items is not a valid table name') end
    local rows = Atlas.db.query(('SELECT name, label, weight FROM %s ORDER BY name'):format(name))
    if type(rows) ~= 'table' then return end
    local entries = {}
    for i = 1, #rows do
        local r = rows[i]
        if type(r.name) == 'string' then
            entries[#entries + 1] = { r.name, type(r.label) == 'string' and r.label or r.name, tonumber(r.weight) or 0 }
        end
    end
    for i = 1, #entries, 500 do
        Atlas.emit('items.catalog', { entries = { table.unpack(entries, i, math.min(i + 499, #entries)) } })
    end
end

Atlas.registerFramework({
    name = NAME,
    resources = { 'es_extended' },
    -- Inventory accounts: ESX mirrors these accounts as ox_inventory items, so the item census leaves them out
    inventoryAccounts = { 'money', 'black_money' },
    -- Selftest: setting the bank to its current balance reaches the money hook without changing anything
    selftestMoney = function(src)
        return pcall(function()
            local xPlayer = playerOf(src)
            xPlayer.setAccountMoney('bank', xPlayer.getAccount('bank').money, 'atlas_selftest')
        end)
    end,
    attach = function()
        -- Probe: an ESX that is not ready fails the check, which makes detect.lua retry
        ESX = data.shared()
        assert(type(ESX) == 'table' and ESX.GetPlayerFromId, 'es_extended is not ready')
        -- Static export: a call for a source with no player returns nothing, and a missing export throws
        static = pcall(function() return exports.es_extended:RunStaticPlayerMethod(0, 'getAccounts', true) end)
        -- Loaded characters: picks up characters already loaded when the agent starts
        CreateThread(function()
            for _, s in ipairs(GetPlayers()) do
                local src = tonumber(s)
                local xPlayer = playerOf(src)
                if xPlayer then
                    local p = Atlas.players[src]
                    if not (p and p.char == xPlayer.identifier) then charStart(src, xPlayer, false, true) end
                end
            end
            itemsCatalog()
        end)
    end,
})
