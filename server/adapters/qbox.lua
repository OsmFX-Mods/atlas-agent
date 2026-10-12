-- Qbox adapter: maps qbx_core events and callbacks to Atlas events (built against qbx_core 1.23.0).
-- Source: signals verified in qbx_core/server/player.lua and server/events.lua.

local NAME = 'qbox'
local qbx = exports.qbx_core

local STATE_KEYS = { isdead = true, inlaststand = true, ishandcuffed = true, injail = true }

local function active() return Atlas.enabled and Atlas.adapterActive(NAME) end

local accountChars = {} -- accountChars: character names per citizenid per src, used to verify deletions

-- Identity: reads character, job and gang facts from PlayerData.
local function charNameOf(pd)
    local ci = pd.charinfo
    if type(ci) == 'table' and ci.firstname then
        return ('%s %s'):format(ci.firstname, ci.lastname or '')
    end
end

--- Identity load: copies the PlayerData facts Atlas needs into the identity cache.
local function loadIdentity(src, pd)
    local p = Atlas.ensurePlayer(src)
    if not p then return nil end
    local job = type(pd.job) == 'table' and pd.job or {}
    local gang = type(pd.gang) == 'table' and pd.gang or {}
    p.job = job.name
    p.grade = type(job.grade) == 'table' and job.grade.level or nil
    p.duty = job.onduty == true
    -- Paycheck: qbx sends paychecks with reason 'unknown', so money.change carries job_payment to identify them
    p.jobPayment = tonumber(job.payment)
    p.gang = (gang.name and gang.name ~= 'none') and gang.name or nil
    p.money = {}
    if type(pd.money) == 'table' then
        for k, v in pairs(pd.money) do p.money[k] = tonumber(v) end
    end
    local md = type(pd.metadata) == 'table' and pd.metadata or {}
    p.state = {
        isdead = md.isdead == true,
        inlaststand = md.inlaststand == true,
        ishandcuffed = md.ishandcuffed == true,
        injail = md.injail,
    }
    p.dead = p.state.isdead or p.state.inlaststand
    p.down = p.dead
    Atlas.setChar(src, pd.citizenid, charNameOf(pd))
    return p
end

local function charStart(src, pd, resumed)
    local p = loadIdentity(src, pd)
    if not p then return end
    -- New character: qbx sets lastLoggedOut on every save, so a character without it was never saved
    local isNew = (not resumed) and pd.lastLoggedOut == nil
    if isNew then
        Atlas.emit('character.create', { char = p.char, char_name = p.charName }, src)
    end
    Atlas.emit('session.char_start', {
        session_id = p.sessionId,
        char = p.char,
        char_name = p.charName,
        job = p.job,
        gang = p.gang,
        is_new_char = isNew,
        resumed = resumed or nil,
    }, src, { fresh = true })
    if not resumed then
        Atlas.emit('teleport.known', { reason = 'spawn' }, src)
    end
    if accountChars[src] and p.char then accountChars[src][p.char] = p.charName end
end

local function charEnd(p, reason)
    if not p.char then return end
    Atlas.emit('session.char_end', { session_id = p.sessionId, char = p.char, reason = reason }, p.src, { fresh = true })
    p.job, p.grade, p.duty, p.gang, p.jobPayment = nil, nil, nil, nil, nil
    p.money, p.state, p.dead, p.down, p.respawned = {}, nil, false, false, false
    Atlas.setChar(p.src, nil, nil)
end

-- PlayerLoaded: server-side after login; emits session.char_start, plus character.create for new characters.
AddEventHandler('QBCore:Server:PlayerLoaded', function(player)
    if not active() or type(player) ~= 'table' then return end
    local pd = player.PlayerData
    if type(pd) ~= 'table' or not pd.source or not pd.citizenid then return end
    local src = tonumber(pd.source)
    local p = Atlas.players[src]
    if p and p.char == pd.citizenid then return end
    if p and p.char then charEnd(p, 'switch') end
    charStart(src, pd, false)
end)

-- OnPlayerUnload: fired by Logout(); emits session.char_end with reason 'logout'.
AddEventHandler('QBCore:Server:OnPlayerUnload', function(src)
    if not active() then return end
    local p = Atlas.players[tonumber(src)]
    if p then charEnd(p, 'logout') end
end)

Atlas.onDrop(function(p)
    accountChars[p.src] = nil
    if Atlas.adapterActive(NAME) and p.char then charEnd(p, 'drop') end
end)

-- OnMoneyChange: emits money.change for online players only.
AddEventHandler('QBCore:Server:OnMoneyChange', function(src, mtype, amount, action, reason)
    if not active() then return end
    src = tonumber(src)
    local p = Atlas.players[src]
    amount = tonumber(amount) or 0

    -- Balance: qbx has already applied the change when this event fires
    local ok, bal = pcall(qbx.GetMoney, qbx, src, mtype)
    local balance = ok and tonumber(bal) or nil

    local delta
    if action == 'add' then delta = amount
    elseif action == 'remove' then delta = -amount
    else -- 'set': amount is the new balance, so delta is the new balance minus the last known one
        local last = p and p.money[mtype]
        local new = balance or amount
        delta = last and (new - last) or nil
    end
    if p and (balance or action == 'set') then p.money[mtype] = balance or amount end
    if reason == 'atlas_selftest' then Atlas.selftestMoneySeen = true end

    Atlas.emit('money.change', {
        mtype = mtype,
        action = action,
        amount = amount,
        delta = delta,
        balance_after = balance,
        reason = type(reason) == 'string' and reason:sub(1, 128) or 'unknown',
        job_payment = p and p.jobPayment or nil,
    }, src, { fresh = true })
end)

-- OnJobUpdate: primary job or grade changes; emits job.change.
AddEventHandler('QBCore:Server:OnJobUpdate', function(src, job)
    if not active() or type(job) ~= 'table' then return end
    local p = Atlas.players[tonumber(src)]
    if not p or not p.char then return end
    local toJob = job.name
    local toGrade = type(job.grade) == 'table' and job.grade.level or nil
    local fromJob, fromGrade = p.job, p.grade
    p.jobPayment = tonumber(job.payment) or p.jobPayment
    local duty = job.onduty == true
    if fromJob == toJob and fromGrade == toGrade and duty == p.duty then return end
    p.job, p.grade, p.duty = toJob, toGrade, duty
    Atlas.rebuildActor(p)
    -- Edits: the event also fires when a job definition is edited, so only real moves are emitted
    if fromJob ~= toJob or fromGrade ~= toGrade then
        Atlas.emit('job.change', { from = { job = fromJob, grade = fromGrade }, to = { job = toJob, grade = toGrade } }, p.src)
    end
end)

-- SetDuty: fired by SetJobDuty(); emits duty.change.
AddEventHandler('QBCore:Server:SetDuty', function(src, onDuty)
    if not active() then return end
    local p = Atlas.players[tonumber(src)]
    if not p or not p.char then return end
    onDuty = onDuty == true
    if p.duty == onDuty then return end
    p.duty = onDuty
    Atlas.rebuildActor(p)
    Atlas.emit('duty.change', { job = p.job, on = onDuty }, p.src)
end)

-- OnGangUpdate: primary gang changes; emits gang.change.
AddEventHandler('QBCore:Server:OnGangUpdate', function(src, gang)
    if not active() or type(gang) ~= 'table' then return end
    local p = Atlas.players[tonumber(src)]
    if not p or not p.char then return end
    local to = (gang.name and gang.name ~= 'none') and gang.name or nil
    if to == p.gang then return end
    local from = p.gang
    p.gang = to
    Atlas.rebuildActor(p)
    Atlas.emit('gang.change', { from = from, to = to }, p.src)
end)

-- onSetMetaData: emits player.state, combat.death and medical.revive.
AddEventHandler('qbx_core:server:onSetMetaData', function(key, old, value, src)
    if not active() or not STATE_KEYS[key] then return end
    src = tonumber(src)
    local p = Atlas.players[src]
    if not p or not p.char then return end
    if key == 'injail' then
        if (tonumber(old) or 0) == (tonumber(value) or 0) then return end
    elseif old == value then
        return
    end
    p.state = p.state or {}
    p.state[key] = value
    p.dead = p.state.isdead == true or p.state.inlaststand == true

    Atlas.emit('player.state', { key = key, value = value }, src, { fresh = true })

    -- Down: one combat.death per down, either last stand or death without last stand
    if (key == 'isdead' or key == 'inlaststand') and value == true and not p.down then
        p.down = true
        local data = { state = key == 'isdead' and 'dead' or 'laststand', cause = 'unknown' }
        local l = Atlas.lastLethal[src]
        if l and GetGameTimer() - l.gt < 10000 and l.src ~= src then
            data.cause = 'player'
            data.killer_char = l.char
            data.killer_src = l.src
            data.weapon = l.weapon
        end
        Atlas.lastLethal[src] = nil
        p.respawned = false
        Atlas.emit('combat.death', data, src)
    elseif not p.dead then
        -- Revive: qbx_medical revives only send a client event, so this state flip is all the server sees.
        -- Respawn: a hospital respawn flips it too but announces itself first (p.respawned), so it is skipped.
        if p.down and (key == 'isdead' or key == 'inlaststand') then
            local respawned = p.respawned
            p.respawned = false
            if not respawned then Atlas.emit('medical.revive', {}, src, { fresh = true }) end
        end
        p.down = false
    end
end)

-- Character deletion: qbx_core exposes it only as an ox_lib callback and a deprecated net event.
-- Validation: only ids owned by the requesting account count, and the row must be gone before character.delete is sent.
local function fetchAccountChars(src)
    local p = Atlas.players[src]
    if not p or not Atlas.db.available() then return end
    local l2, l1 = p.ids.license2 or '', p.ids.license or ''
    local rows = Atlas.db.query([[SELECT citizenid, CONCAT_WS(' ', JSON_UNQUOTE(JSON_EXTRACT(charinfo, '$.firstname')),
        JSON_UNQUOTE(JSON_EXTRACT(charinfo, '$.lastname'))) AS n FROM players WHERE license = ? OR license = ?]], { l2, l1 })
    if type(rows) ~= 'table' then return end
    local set = {}
    for i = 1, #rows do set[rows[i].citizenid] = rows[i].n or '' end
    accountChars[src] = set
end

Atlas.onJoin(function(p)
    if Atlas.adapterActive(NAME) then CreateThread(function() fetchAccountChars(p.src) end) end
end)

local checking = {} -- checking: citizen ids with a deletion check in flight, so repeated requests cost one query

local function onDeleteRequest(src, citizenId)
    if not active() or type(citizenId) ~= 'string' or checking[citizenId] then return end
    local owned = accountChars[src]
    if not owned or owned[citizenId] == nil then return end -- owned: kept by reference, so a drop during the wait still records it
    local name = owned[citizenId]
    local player = Atlas.players[src] -- player: compared after the wait, since the id can be reused by someone else
    checking[citizenId] = true
    CreateThread(function()
        Wait(3000)
        -- Error: a failed query also returns nil, which must not be read as "row is gone"
        local exists, err = Atlas.db.scalar('SELECT 1 FROM players WHERE citizenid = ?', { citizenId })
        checking[citizenId] = nil
        if exists == nil and err == nil and owned[citizenId] ~= nil then
            owned[citizenId] = nil
            Atlas.emit('character.delete', { char = citizenId, char_name = name ~= '' and name or nil }, Atlas.players[src] == player and src or nil)
        end
    end)
end

RegisterNetEvent('__ox_cb_qbx_core:server:deleteCharacter', function(_, _, citizenId)
    onDeleteRequest(source, citizenId)
end)

RegisterNetEvent('qbx_core:server:deleteCharacter', function(citizenId)
    onDeleteRequest(source, citizenId)
end)

-- Group lists: job and gang names, used to classify Renewed-Banking accounts.
function Atlas.qbxGroups()
    if not Atlas.adapterActive(NAME) then return nil, nil end
    local jobs, gangs = {}, {}
    local ok, j = pcall(qbx.GetJobs, qbx)
    if ok and type(j) == 'table' then for name in pairs(j) do jobs[name] = true end end
    local ok2, g = pcall(qbx.GetGangs, qbx)
    if ok2 and type(g) == 'table' then for name in pairs(g) do gangs[name] = true end end
    return jobs, gangs
end

--- Online balances: live balances of online characters, overriding money.snapshot.
function Atlas.onlineBalances()
    local out = {}
    for _, p in pairs(Atlas.players) do
        if p.char and p.money and p.money.bank then out[p.char] = p.money end
    end
    return out
end

Atlas.registerAdapter({
    name = NAME,
    resources = { 'qbx_core' },
    attach = function()
        -- Probe: a missing export throws, which makes detect.lua retry
        local version = qbx:GetCoreVersion()
        Atlas.debug('qbx_core %s', tostring(version))
        -- Loaded characters: picks up characters already loaded when the agent starts
        CreateThread(function()
            for _, s in ipairs(GetPlayers()) do
                local src = tonumber(s)
                local ok, player = pcall(qbx.GetPlayer, qbx, src)
                if ok and type(player) == 'table' and type(player.PlayerData) == 'table' then
                    local p = Atlas.players[src]
                    if not (p and p.char == player.PlayerData.citizenid) then
                        charStart(src, player.PlayerData, true)
                    end
                end
                fetchAccountChars(src)
            end
        end)
    end,
})
