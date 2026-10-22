-- QBCore adapter: turns qb-core events into Atlas events (built against qb-core 1.3.0, checked against the 2022 to 2025 releases).
-- Versions: 1.3.0 reports each change through QBCore:Server:OnPlayerUpdated; older releases send the whole PlayerData through
-- QBCore:Player:SetPlayerData before every money, job and metadata change. Both are read, and both fire the classic job events.
-- Money: qb-core fires the money event itself, so it never names the script that paid; money.change has no script either.
-- Data: the database readers for snapshots, and the places, prices and accounts of qb resources, are in qbcore_data.lua.

local cfg = AtlasConfig
local C, M = Atlas.characters, Atlas.money
local NAME = 'qbcore'
local STATE_KEYS = { 'inlaststand', 'isdead', 'ishandcuffed', 'injail' } -- STATE_KEYS: in the order a combined update is read

local data = Atlas.frameworkData.qbcore

local function active() return Atlas.enabled and Atlas.adapterActive(NAME) end

local accountChars = {} -- accountChars[src]: the account's characters as citizenid to name, used to name deleted characters
local dropping = {}     -- dropping[src]: set by QBCore:Server:PlayerDropped, so the unload that follows counts as a drop
local latest = {}       -- latest[src]: { money, at } the money table qb-core sent just before its money event, in the same tick

--- Job: name, grade and pay of a PlayerData.job table; pay sits in the grade, with the job's own pay as the fallback.
local function jobOf(job)
    if type(job) ~= 'table' then return nil end
    local grade = type(job.grade) == 'table' and job.grade or {}
    return job.name, tonumber(grade.level), job.onduty == true, tonumber(grade.payment) or tonumber(job.payment)
end

local function gangOf(gang)
    local name = type(gang) == 'table' and gang.name
    return (type(name) == 'string' and name ~= 'none') and name or nil
end

--- State value: a metadata flag as Atlas reports it; jail is a number of months, the others true or false.
local function stateValue(key, v)
    if key == 'injail' then return tonumber(v) or 0 end
    return v == true
end

--- Character start: reads the character facts Atlas needs and hands them to the shared character pipeline.
local function charStart(src, pd, resumed)
    local job, grade, duty, payment = jobOf(pd.job)
    local md = type(pd.metadata) == 'table' and pd.metadata or {}
    local state = {}
    for _, key in ipairs(STATE_KEYS) do state[key] = stateValue(key, md[key]) end
    local p = C.load(src, {
        char = pd.citizenid,
        name = Atlas.qb.charName(pd),
        job = job,
        grade = grade,
        duty = duty,
        jobPayment = payment,
        gang = gangOf(pd.gang),
        money = data.balances(pd.money),
        dead = state.isdead or state.inlaststand,
        -- New character: one made this session comes from the creation screen, not the database, so it has no row id yet
        isNew = pd.id == nil and pd.last_updated == nil,
        resumed = resumed,
    })
    if not p then return end
    p.state = state
    if accountChars[src] then accountChars[src][p.char] = p.charName or '' end
end

-- PlayerLoaded: runs after login; sends session.char_start, plus character.create for new characters.
AddEventHandler('QBCore:Server:PlayerLoaded', function(player)
    if not active() or type(player) ~= 'table' then return end
    local pd = player.PlayerData
    if type(pd) ~= 'table' or not pd.source or not pd.citizenid then return end
    local src = tonumber(pd.source)
    local p = Atlas.players[src]
    if p and p.char == pd.citizenid then return end
    if p and p.char then C.unload(p, 'switch') end
    charStart(src, pd, false)
end)

-- PlayerDropped: qb-core fires it, then OnPlayerUnload, when a player leaves.
AddEventHandler('QBCore:Server:PlayerDropped', function(src)
    src = tonumber(src)
    if src then dropping[src] = true end
end)

-- OnPlayerUnload: a logout to the character screen, or the second half of a drop; emits session.char_end.
AddEventHandler('QBCore:Server:OnPlayerUnload', function(src)
    src = tonumber(src)
    local drop = src and dropping[src]
    if src then dropping[src] = nil end
    if not active() then return end
    local p = Atlas.players[src]
    if p then C.unload(p, drop and 'drop' or 'logout') end
end)

Atlas.onDrop(function(p)
    accountChars[p.src], dropping[p.src], latest[p.src] = nil, nil, nil
end)

--- Metadata: compares the medical and restraint flags with what is known and reports the ones that changed.
local function onMetadata(src, md)
    local p = Atlas.players[src]
    if not p or not p.char or type(md) ~= 'table' then return end
    for _, key in ipairs(STATE_KEYS) do C.setState(src, key, stateValue(key, md[key])) end
end

--- Player data: a changed part of PlayerData; money is kept for the money event that follows in the same tick.
local function onUpdate(src, key, value)
    if key == 'money' then
        latest[src] = { money = value, at = GetGameTimer() }
    elseif key == 'metadata' then
        onMetadata(src, value)
    elseif key == 'all' and type(value) == 'table' then
        latest[src] = { money = value.money, at = GetGameTimer() }
        onMetadata(src, value.metadata)
    end
end

-- OnPlayerUpdated: qb-core 1.3.0 reports each change of PlayerData with the key that changed.
AddEventHandler('QBCore:Server:OnPlayerUpdated', function(src, key, value)
    if not active() then return end
    src = tonumber(src)
    if src and Atlas.players[src] then onUpdate(src, key, value) end
end)

-- SetPlayerData: older releases send the whole PlayerData before every change; 1.3.0 still sends it for full updates.
AddEventHandler('QBCore:Player:SetPlayerData', function(pd)
    if not active() or type(pd) ~= 'table' then return end
    local src = tonumber(pd.source)
    local p = src and Atlas.players[src]
    if p and p.char == pd.citizenid then onUpdate(src, 'all', pd) end
end)

-- OnMoneyChange: fired after the balance changed; emits money.change for online players.
-- Balance: read from the money table sent just before; without one it follows from the last known balance.
AddEventHandler('QBCore:Server:OnMoneyChange', function(src, mtype, amount, action, reason)
    if not active() or type(mtype) ~= 'string' then return end
    src, amount = tonumber(src), tonumber(amount)
    if not src or not amount then return end
    local kind = data.moneyType(mtype)
    local p = Atlas.players[src]
    local l = latest[src]
    latest[src] = nil
    local balance = l and l.at == GetGameTimer() and type(l.money) == 'table' and tonumber(l.money[mtype:lower()]) or nil
    if balance == nil and p then
        local known = p.money[kind]
        if action == 'set' then balance = amount
        elseif known and action == 'add' then balance = known + amount
        elseif known and action == 'remove' then balance = known - amount end
    end
    M.change(src, kind, action, amount, balance, reason)
end)

-- OnJobUpdate: job or grade changes, and duty changes of the same job (SetJobDuty fires it too); emits job.change or duty.change.
AddEventHandler('QBCore:Server:OnJobUpdate', function(src, job)
    if not active() or type(job) ~= 'table' then return end
    src = tonumber(src)
    local p = Atlas.players[src]
    if not p or not p.char then return end
    local name, grade, duty, payment = jobOf(job)
    if p.job == name and p.grade == grade then C.setDuty(src, duty) end
    C.setJob(src, name, grade, duty, payment)
end)

-- SetDuty: fired by the duty toggle; emits duty.change.
AddEventHandler('QBCore:Server:SetDuty', function(src, onDuty)
    if not active() then return end
    C.setDuty(tonumber(src), onDuty)
end)

-- OnGangUpdate: gang changes; emits gang.change.
AddEventHandler('QBCore:Server:OnGangUpdate', function(src, gang)
    if not active() or type(gang) ~= 'table' then return end
    C.setGang(tonumber(src), gangOf(gang))
end)

-- Character deletion: qb-core logs every deletion through qb-log once the rows are gone, whether or not qb-log runs.
-- Check: the character's row must be gone; a server-side event is the only kind this resource receives for it.
local function fetchAccountChars(src)
    local set = Atlas.qb.accountChars(cfg.qbcore.tables.characters, Atlas.players[src])
    if set then accountChars[src] = set end
end

Atlas.onJoin(function(p)
    if Atlas.adapterActive(NAME) then CreateThread(function() fetchAccountChars(p.src) end) end
end)

local checking = {} -- checking: characters being checked, so repeated log lines cost one query

local function onDeleted(citizenId)
    if checking[citizenId] then return end
    checking[citizenId] = true
    CreateThread(function()
        local gone = Atlas.qb.gone(cfg.qbcore.tables.characters, citizenId)
        checking[citizenId] = nil
        if not gone then return end
        local owner, name -- owner: the online player whose account held the character
        for src, chars in pairs(accountChars) do
            if chars[citizenId] ~= nil then owner, name = src, chars[citizenId] chars[citizenId] = nil break end
        end
        Atlas.emit('character.delete', { char = citizenId, char_name = name ~= '' and name or nil }, owner)
    end)
end

AddEventHandler('qb-log:server:CreateLog', function(name, title, _, message)
    if not active() or name ~= 'joinleave' or type(message) ~= 'string' then return end
    if title ~= 'Character Deleted' and title ~= 'Character Force Deleted' then return end
    local s = source
    if s ~= nil and s ~= '' and tonumber(s) ~= 0 then return end -- Clients: only qb-core's own server-side line counts
    local citizenId -- citizenId: the last bold part of the line names the character
    for part in message:gmatch('%*%*([^*]+)%*%*') do citizenId = part end
    if citizenId and citizenId:find('^[%w]+$') then onDeleted(citizenId) end
end)

Atlas.registerFramework({
    name = NAME,
    resources = { 'qb-core' },
    -- qbx_core: Qbox also answers to the qb-core name, and has its own adapter
    displacedBy = { 'qbx_core' },
    -- Staff rank: releases before 2022 keep it as a name; later ones use the ACE permissions in staffAces
    staffRole = function(src)
        local perm = data.core().Functions.GetPermission(src)
        if type(perm) == 'string' and perm ~= 'user' then return perm end
    end,
    -- Selftest: setting the bank to its current balance reaches the money hook without changing anything
    selftestMoney = function(src)
        return pcall(function()
            local player = data.core().Functions.GetPlayer(src)
            player.Functions.SetMoney('bank', player.PlayerData.money.bank, 'atlas_selftest')
        end)
    end,
    attach = function()
        -- Probe: a qb-core that is not ready fails the check, which makes detect.lua retry
        local core = data.core()
        assert(type(core) == 'table' and type(core.Functions) == 'table' and core.Functions.GetPlayer, 'qb-core is not ready')
        -- Loaded characters: picks up characters already loaded when the agent starts
        CreateThread(function()
            for _, s in ipairs(GetPlayers()) do
                local src = tonumber(s)
                local ok, player = pcall(core.Functions.GetPlayer, src)
                local pd = ok and type(player) == 'table' and player.PlayerData
                if type(pd) == 'table' and pd.citizenid then
                    local p = Atlas.players[src]
                    if not (p and p.char == pd.citizenid) then charStart(src, pd, true) end
                end
                fetchAccountChars(src)
            end
        end)
    end,
})
