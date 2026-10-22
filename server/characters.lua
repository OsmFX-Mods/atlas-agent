-- Characters: the shared identity and medical-state pipeline that framework adapters and the exports feed.
-- Contract: adapters translate their framework's signals into these calls, so event shapes stay identical across frameworks.

local C = {}
Atlas.characters = C
Atlas.lastLethal = Atlas.lastLethal or {} -- lastLethal: filled by the natives adapter, read to name a killer

--- Load: a character became active for a player.
--- @param c table { char, name?, job?, grade?, duty?, gang?, jobPayment?, money? = { cash, bank, crypto }, dead?, isNew?, resumed? }
--- Resumed: the character was already loaded when the agent started, so no spawn is reported.
--- @return table? player record
function C.load(src, c)
    local p = Atlas.ensurePlayer(src)
    if not p or type(c) ~= 'table' or not c.char then return nil end
    p.job, p.grade, p.duty = c.job, c.grade, c.duty == true
    -- Paycheck: some frameworks send paychecks with an unknown reason, so money.change carries job_payment to identify them
    p.jobPayment = tonumber(c.jobPayment)
    p.gang = c.gang
    p.money = {}
    for k, v in pairs(c.money or {}) do p.money[k] = tonumber(v) end
    p.dead = c.dead == true
    p.down = p.dead
    Atlas.setChar(src, c.char, c.name)

    local isNew = c.isNew == true and not c.resumed
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
        resumed = c.resumed or nil,
    }, src, { fresh = true })
    if not c.resumed then
        Atlas.emit('teleport.known', { reason = 'spawn' }, src)
    end
    Atlas.staff.check(src)
    return p
end

--- Unload: the character left, because of a logout, a drop or a switch to another character.
--- @param p table player record
function C.unload(p, reason)
    if not p.char then return end
    if Atlas.money and Atlas.money.flush then Atlas.money.flush(p.src) end
    Atlas.emit('session.char_end', { session_id = p.sessionId, char = p.char, reason = reason }, p.src, { fresh = true })
    p.job, p.grade, p.duty, p.gang, p.jobPayment = nil, nil, nil, nil, nil
    p.money, p.state, p.dead, p.down, p.respawned = {}, nil, false, false, false
    Atlas.setChar(p.src, nil, nil)
end

-- Drop: a player leaving ends the loaded character, whichever adapter or export loaded it.
Atlas.onDrop(function(p)
    if p.char then C.unload(p, 'drop') end
end)

local function loaded(src)
    local p = Atlas.players[tonumber(src)]
    return p and p.char and p or nil
end

--- Job: the primary job or grade changed; only a real move emits job.change, a job definition edit just refreshes the pay.
--- Duty: a duty difference updates the cache silently, since duty.change comes from C.setDuty.
function C.setJob(src, job, grade, duty, payment)
    local p = loaded(src)
    if not p then return end
    local fromJob, fromGrade = p.job, p.grade
    p.jobPayment = tonumber(payment) or p.jobPayment
    if duty == nil then duty = p.duty end
    if fromJob == job and fromGrade == grade and duty == p.duty then return end
    p.job, p.grade, p.duty = job, grade, duty
    Atlas.rebuildActor(p)
    if fromJob ~= job or fromGrade ~= grade then
        Atlas.emit('job.change', { from = { job = fromJob, grade = fromGrade }, to = { job = job, grade = grade } }, p.src)
    end
end

--- Duty: emits duty.change once per change.
function C.setDuty(src, on)
    local p = loaded(src)
    if not p then return end
    on = on == true
    if p.duty == on then return end
    p.duty = on
    Atlas.rebuildActor(p)
    Atlas.emit('duty.change', { job = p.job, on = on }, p.src)
end

--- Gang: nil means no gang.
function C.setGang(src, gang)
    local p = loaded(src)
    if not p then return end
    if gang == p.gang then return end
    local from = p.gang
    p.gang = gang
    Atlas.rebuildActor(p)
    Atlas.emit('gang.change', { from = from, to = gang }, p.src)
end

--- Down: the character went down, as 'dead' or 'laststand'; emits one combat.death per down.
--- Cause: a lethal hit by another player in the last 10 s names the killer.
--- Quiet: the character was already down when it was restored, so nothing is emitted.
function C.markDown(src, kind, quiet)
    local p = loaded(src)
    if not p or p.down then return end
    p.down = true
    if quiet then return end
    local data = { state = kind, cause = 'unknown' }
    local l = Atlas.lastLethal[src]
    if l and GetGameTimer() - l.gt < AtlasConfig.killWindowMs and l.src ~= src then
        data.cause = 'player'
        data.killer_char = l.char
        data.killer_src = l.src
        data.weapon = l.weapon
    end
    Atlas.lastLethal[src] = nil
    p.respawned = false
    Atlas.emit('combat.death', data, src)
end

--- Up: the character is no longer down; a revive is reported unless a respawn announced itself first.
--- Revive: frameworks often only tell clients about revives, so it is inferred from the state flip.
function C.markUp(src)
    local p = loaded(src)
    if not p then return end
    if p.down then
        local respawned = p.respawned
        p.respawned = false
        if not respawned then Atlas.emit('medical.revive', {}, src, { fresh = true }) end
    end
    p.down = false
end

--- State: a medical or restraint flag changed (isdead, inlaststand, ishandcuffed, injail); emits player.state,
--- and for the two life flags combat.death or medical.revive. Jail is a number of months, the others are true or false.
function C.setState(src, key, value)
    local p = loaded(src)
    if not p then return end
    p.state = p.state or {}
    local old = p.state[key]
    if key == 'injail' then
        if (tonumber(old) or 0) == (tonumber(value) or 0) then return end
    elseif old == value then
        return
    end
    p.state[key] = value
    p.dead = p.state.isdead == true or p.state.inlaststand == true

    Atlas.emit('player.state', { key = key, value = value }, p.src, { fresh = true })

    local life = key == 'isdead' or key == 'inlaststand'
    if life and value == true then
        C.markDown(p.src, key == 'isdead' and 'dead' or 'laststand')
    elseif not p.dead then
        -- Revive: medical scripts often only tell the client, so this state change is all the server sees
        if life then C.markUp(p.src) else p.down = false end
    end
end

--- Respawn: the character respawned at a hospital; the state flip that follows is not a revive.
function C.respawn(src)
    local p = Atlas.players[tonumber(src)]
    if p then p.respawned = true end
    Atlas.emit('medical.respawn', {}, src, { fresh = true })
    Atlas.emit('teleport.known', { reason = 'respawn' }, src)
end
