-- Motion: decides what each position sample sends; needs lib/common.lua loaded first.

AtlasLib = AtlasLib or {}
local M = {}

local sqrt = math.sqrt
local headingDiff = AtlasLib.common.headingDiff

-- Rules: used when no rules are passed; the agent passes the values from config.lua.
M.DEFAULT_RULES = { moveMeters = 1.0, turnDegrees = 20, stillEveryMs = 30000 }

--- Decide: returns 'sample', 'still' or 'skip' for one sample.
--- A player who has not moved, turned or changed vehicle or bucket sends only a still marker every stillEveryMs.
--- @param st table per-player state (updated here): last, stillSince, lastStillAt
--- @param cur table { x, y, z, h, vkey, bucket }
--- @param now integer ms
--- @param rules table? { moveMeters, turnDegrees, stillEveryMs }
--- @return 'sample'|'still'|'skip'
function M.decide(st, cur, now, rules)
    rules = rules or M.DEFAULT_RULES
    local last = st.last
    if last then
        local dx, dy, dz = cur.x - last.x, cur.y - last.y, cur.z - last.z
        local moved = sqrt(dx * dx + dy * dy + dz * dz) >= rules.moveMeters
            or headingDiff(cur.h, last.h) >= rules.turnDegrees
            or cur.vkey ~= last.vkey
            or cur.bucket ~= last.bucket
        if not moved then
            if not st.stillSince then st.stillSince = last.t end
            local ref = st.lastStillAt or last.t
            if now - ref >= rules.stillEveryMs then
                st.lastStillAt = now
                return 'still'
            end
            return 'skip'
        end
    end
    cur.t = now
    st.last = cur
    st.stillSince = nil
    st.lastStillAt = nil
    return 'sample'
end

--- Vehicle key: on foot, or vehicle model and seat, to spot a change between samples.
function M.vehicleKey(model, seat)
    if not model then return 'foot' end
    return model .. ':' .. seat
end

--- Within: sources of `players` ({ src, x, y }) inside `radius` of (cx, cy).
function M.within(players, cx, cy, radius)
    local out, r2 = {}, radius * radius
    for i = 1, #players do
        local p = players[i]
        local dx, dy = p.x - cx, p.y - cy
        if dx * dx + dy * dy <= r2 then out[#out + 1] = p.src end
    end
    return out
end

AtlasLib.motion = M
return M
