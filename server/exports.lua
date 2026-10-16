-- Exports: functions for other scripts, called as exports['atlas-agent'] (exports.atlas also works).
-- The calling resource is recorded in the event's `res` field.

local cfg = AtlasConfig
local common = AtlasLib.common

local function cleanName(name)
    if type(name) ~= 'string' then return nil end
    name = name:lower():gsub('^custom%.', ''):gsub('[^%w_%.%-]', '_')
    if name == '' then return nil end
    return 'custom.' .. name:sub(1, 64)
end

local function validSrc(src)
    src = tonumber(src)
    return (src and Atlas.players[src]) and src or nil
end

-- track: emits custom.<name> from exports['atlas-agent']:track(name, data, src?)
exports('track', function(name, data, src)
    local etype = cleanName(name)
    if not etype then return false end
    if type(data) ~= 'table' then data = { value = data } end
    data = common.sanitize(data) or {}
    return Atlas.emit(etype, data, validSrc(src), { res = GetInvokingResource() }) ~= nil
end)

-- money: emits money.change from exports['atlas-agent']:money(src, delta, moneyType, reason)
exports('money', function(src, delta, moneyType, reason)
    delta = tonumber(delta)
    if not delta or delta ~= delta or math.abs(delta) > 1e12 then return false end
    src = validSrc(src)
    return Atlas.emit('money.change', {
        mtype = type(moneyType) == 'string' and moneyType:sub(1, 32) or 'cash',
        action = delta >= 0 and 'add' or 'remove',
        amount = math.abs(delta),
        delta = delta,
        reason = type(reason) == 'string' and reason:sub(1, 128) or 'unknown',
    }, src, { fresh = src ~= nil, res = GetInvokingResource() }) ~= nil
end)

-- place: suggests a place from exports['atlas-agent']:place(name, coords, radius, kind?)
exports('place', function(name, coords, radius, kind)
    if type(name) ~= 'string' or name == '' then return false end
    local x, y = AtlasLib.sandbox.xyz(coords)
    if not x then return false end
    Atlas.suggestPlaces({ {
        name:sub(1, 64),
        type(kind) == 'string' and kind or 'custom',
        common.round1(x),
        common.round1(y),
        tonumber(radius) or cfg.placeRadius[kind] or cfg.placeRadius.custom,
    } })
    return true
end)

-- Characters: for servers with their own framework. An attached framework adapter already reports all of this, so these refuse then.
local function ownFramework(src)
    if Atlas.framework then return nil end
    return validSrc(src)
end

local function cleanId(v)
    if type(v) == 'number' then v = tostring(math.floor(v)) end
    if type(v) ~= 'string' or v == '' or #v > 64 then return nil end
    return v
end

local function cleanText(v, max)
    return type(v) == 'string' and v ~= '' and v:sub(1, max) or nil
end

local function cleanAmount(v)
    v = tonumber(v)
    return (v and v == v and math.abs(v) <= 1e12) and v or nil
end

-- character: reports the character a player is now playing, from exports['atlas-agent']:character(src, data)
-- Data: { id, name?, job?, grade?, duty?, gang?, cash?, bank?, crypto?, new? }; a different id ends the previous character first.
exports('character', function(src, data)
    src = ownFramework(src)
    if not src or type(data) ~= 'table' then return false end
    local id = cleanId(data.id)
    if not id then return false end
    local p = Atlas.players[src]
    if p.char == id then return true end
    if p.char then Atlas.characters.unload(p, 'switch') end
    return Atlas.characters.load(src, {
        char = id,
        name = cleanText(data.name, 64),
        job = cleanText(data.job, 32),
        grade = tonumber(data.grade),
        duty = data.duty == true,
        gang = cleanText(data.gang, 32),
        money = { cash = cleanAmount(data.cash), bank = cleanAmount(data.bank), crypto = cleanAmount(data.crypto) },
        isNew = data.new == true,
    }) ~= nil
end)

-- logout: reports that the player stopped playing their character, from exports['atlas-agent']:logout(src)
exports('logout', function(src)
    src = ownFramework(src)
    local p = src and Atlas.players[src]
    if not p or not p.char then return false end
    Atlas.characters.unload(p, 'logout')
    return true
end)

-- job: reports a job or grade change, from exports['atlas-agent']:job(src, name, grade?, onDuty?)
exports('job', function(src, name, grade, onDuty)
    src = ownFramework(src)
    name = cleanText(name, 32)
    if not src or not name then return false end
    local duty -- duty: left as it is when the caller does not say
    if onDuty ~= nil then duty = onDuty == true end
    Atlas.characters.setJob(src, name, tonumber(grade), duty)
    return true
end)

-- duty: reports going on or off duty, from exports['atlas-agent']:duty(src, on)
exports('duty', function(src, on)
    src = ownFramework(src)
    if not src then return false end
    Atlas.characters.setDuty(src, on == true)
    return true
end)

-- gang: reports a gang change, from exports['atlas-agent']:gang(src, name?) where no name means no gang
exports('gang', function(src, name)
    src = ownFramework(src)
    if not src then return false end
    Atlas.characters.setGang(src, cleanText(name, 32))
    return true
end)
