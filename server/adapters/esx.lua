-- ESX adapter: maps es_extended events to Atlas events (built against ESX Legacy 1.16.0, checked against 1.13 to 1.15).
-- Source: signals verified in es_extended server/modules/player, server/classes/player and the ox_inventory override.
-- Events: esx:playerLoaded, esx:playerDropped, esx:setJob and the three account events keep their arguments from 1.9.4 on.
-- Data: the database readers for snapshots, and the places and prices ESX resources provide, are in esx_data.lua.
-- Characters: keyed as esx_data.lua describes; deletions are confirmed against the database after esx_multicharacter's request.
-- Not covered: vehicle purchases have no server event in ESX, so snapshots pick them up instead.

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

local idents = {}  -- idents[src]: the identifier of the character loaded or being loaded for a player
local pending = {} -- pending[src]: { identifier, calls } while a character's key is read; calls are money changes that came meanwhile
local owned = {}   -- owned[src]: the account's characters as identifier to { key, name }, used to confirm deletions

local function charStart(src, xPlayer, key, isNew, resumed)
    local ok, job = pcall(xPlayer.getJob)
    if not ok or type(job) ~= 'table' then job = {} end
    local p = C.load(src, {
        char = key,
        name = charNameOf(xPlayer),
        job = job.name,
        grade = tonumber(job.grade),
        duty = job.onDuty == true,
        money = balances(xPlayer),
        dead = isDead(src),
        isNew = isNew == true,
        resumed = resumed,
    })
    if p and owned[src] then owned[src][xPlayer.identifier] = { key = p.char, name = p.charName or '' } end
end

local process -- process: handles one money change; defined with the money events below

--- Begin: starts a character once its key is known; plain identifiers start at once, timed keys after one database read.
local function begin(src, xPlayer, isNew, resumed)
    local identifier = xPlayer.identifier
    if type(identifier) ~= 'string' or identifier == '' then return end
    idents[src] = identifier
    if data.keys.timed(true) == false or not Atlas.db.available() then return charStart(src, xPlayer, identifier, isNew, resumed) end
    local job = { identifier = identifier, calls = {} }
    pending[src] = job
    CreateThread(function()
        local key
        for _ = 1, cfg.esx.keyTries do
            key = data.keys.of(identifier)
            if key or pending[src] ~= job then break end
            Wait(1000)
        end
        if pending[src] ~= job then return end
        pending[src] = nil
        local fresh = playerOf(src)
        if not fresh or fresh.identifier ~= identifier then idents[src] = nil return end
        if not key then
            Atlas.warn('esx: could not read the key of %s, so it is sent by its identifier', identifier)
            key = identifier
        end
        charStart(src, fresh, key, isNew, resumed)
        for _, call in ipairs(job.calls) do process(table.unpack(call, 1, 7)) end
    end)
end

--- End: the character left, or its load was cancelled before the key was read.
local function finish(src, reason)
    pending[src], idents[src] = nil, nil
    local p = Atlas.players[src]
    if p and p.char then C.unload(p, reason) end
end

-- playerLoaded: server-side after login or character selection; emits session.char_start, plus character.create for new characters.
AddEventHandler('esx:playerLoaded', function(src, xPlayer, isNew)
    if not active() or type(xPlayer) ~= 'table' then return end
    src = tonumber(src)
    if not src or idents[src] == xPlayer.identifier then return end
    finish(src, 'switch')
    begin(src, xPlayer, isNew, false)
end)

-- playerDropped: fired for a disconnect and for a logout to the character screen; emits session.char_end.
-- Reason: 'esx_player_logout' is the logout, anything else is a disconnect.
AddEventHandler('esx:playerDropped', function(src, reason)
    if not active() then return end
    src = tonumber(src)
    if src then finish(src, reason == 'esx_player_logout' and 'logout' or 'drop') end
end)

Atlas.onDrop(function(p)
    pending[p.src], idents[p.src], owned[p.src] = nil, nil, nil
end)

-- Character deletion: esx_multicharacter deletes every row of the slot's identifier, after which the slot can be filled again.
-- Check: the character must belong to the player's account, and after a short wait its row must be gone or hold another character.
local function fetchOwned(src)
    local p = Atlas.players[src]
    if not p or not Atlas.db.available() then return end
    local full = p.ids[GetConvar('esx:identifier', 'license')]
    local list = type(full) == 'string' and data.keys.account(full:match(':(.+)$'))
    if list then owned[src] = list end
end

Atlas.onJoin(function(p)
    if Atlas.adapterActive(NAME) then CreateThread(function() fetchOwned(p.src) end) end
end)

local checking = {} -- checking: identifiers being checked, so repeated requests cost one query

local function onDeleteRequest(src, slot)
    slot = tonumber(slot)
    local chars = owned[src]
    if not active() or not slot or not chars then return end
    local identifier, char -- identifier: the account character in the requested slot
    for id, c in pairs(chars) do
        if tonumber(id:match('^.-(%d+):[^:]+$')) == slot then identifier, char = id, c break end
    end
    if not identifier or checking[identifier] then return end
    local player = Atlas.players[src] -- player: compared after the wait, since the id can be reused by someone else
    checking[identifier] = true
    CreateThread(function()
        Wait(cfg.deleteCheckMs)
        local key = data.keys.current(identifier) -- key: false once the slot is empty, nil after a database error
        checking[identifier] = nil
        if key == nil or key == char.key or chars[identifier] ~= char then return end
        chars[identifier] = nil
        Atlas.emit('character.delete', { char = char.key, char_name = char.name ~= '' and char.name or nil }, Atlas.players[src] == player and src or nil)
    end)
end

RegisterNetEvent('esx_multicharacter:DeleteCharacter', function(slot) onDeleteRequest(source, slot) end)
RegisterNetEvent('__xLib_cb_esx_multicharacter:deleteCharacter', function(_, _, slot) onDeleteRequest(source, slot) end)
RegisterNetEvent('__ox_cb_esx_multicharacter:deleteCharacter', function(_, _, slot) onDeleteRequest(source, slot) end)

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

--- Process: records one money change; `at` stamps a change that waited for its character's key.
function process(action, src, account, amount, reason, balance, at)
    local slot = cfg.esx.accounts[account] -- slot: the money type this account counts as
    local p = Atlas.players[src]
    if action == 'set' and reason == SYNC_REASON then
        release(src, account)
        local prev = p and p.money[slot]
        local h = {
            slot = slot, amount = amount, balance = balance, reason = reason, at = at or Atlas.now(), prev = prev,
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
    M.emit(src, p, slot, action, amount, delta, balance, reason, at)
end

local function onMoney(action)
    return function(src, account, amount, reason)
        if not active() then return end
        src, amount = tonumber(src), tonumber(amount)
        if not src or not amount or type(account) ~= 'string' then return end
        account = account:lower()
        local slot = cfg.esx.accounts[account]
        if type(slot) ~= 'string' or slot == '' then return end
        local live = liveBalances(src)
        local balance = live and live[slot] or nil
        reason = reasonOf(reason)
        -- Pending: a change made while the character's key is read waits for it, with the balance and time it had
        local job = pending[src]
        if job then
            job.calls[#job.calls + 1] = { action, src, account, amount, reason, balance, Atlas.now() }
            return
        end
        process(action, src, account, amount, reason, balance)
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

-- Group: /setgroup changes the group in the state bag; the rank is read again once the change has been applied.
AddStateBagChangeHandler('group', nil, function(bag)
    if not active() then return end
    local src = GetPlayerFromStateBagName(bag)
    if not src or src == 0 then return end
    CreateThread(function()
        Wait(0)
        Atlas.staff.check(src)
    end)
end)

Atlas.registerFramework({
    name = NAME,
    resources = { 'es_extended' },
    -- Inventory accounts: ESX mirrors these accounts as ox_inventory items, so the item census leaves them out
    inventoryAccounts = { 'money', 'black_money' },
    -- Staff rank: ESX keeps the player's group in their state bag; user is everyone without a rank
    staffRole = function(src)
        local group = Player(src).state.group
        if type(group) == 'string' and group ~= 'user' then return group end
    end,
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
            -- Columns: read once here, so later logins know at once whether keys are timed
            if Atlas.db.available() then data.keys.timed() end
            for _, s in ipairs(GetPlayers()) do
                local src = tonumber(s)
                local xPlayer = playerOf(src)
                if xPlayer and idents[src] ~= xPlayer.identifier then begin(src, xPlayer, false, true) end
                fetchOwned(src)
            end
            itemsCatalog()
        end)
    end,
})
