-- Exports: public API for other scripts, called as exports['atlas-agent'] (exports.atlas works through the manifest alias).
-- Attribution: the calling resource is recorded in the envelope's `res` field.

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
        tonumber(radius) or 30.0,
    } })
    return true
end)
