-- Motion: sampler decisions, pure; a player who moved under 1 m, turned under 20 degrees and kept vehicle and bucket
-- sends no sample, only position.still every 30 s at most.

AtlasLib = AtlasLib or {}
local M = {}

M.MOVE_M = 1.0
M.TURN_DEG = 20
M.STILL_EVERY_MS = 30000

local sqrt, abs = math.sqrt, math.abs

local function headingDiff(a, b)
    local d = abs(a - b) % 360
    if d > 180 then d = 360 - d end
    return d
end

--- Decide: returns what to emit for one sample, 'sample', 'still' or 'skip'.
--- @param st table per-player sampler state (mutated): last = last full sample, stillSince, lastStillAt
--- @param cur table { x, y, z, h, vkey, bucket }
--- @param now integer ms
--- @return 'sample'|'still'|'skip'
function M.decide(st, cur, now)
    local last = st.last
    if last then
        local dx, dy, dz = cur.x - last.x, cur.y - last.y, cur.z - last.z
        local moved = sqrt(dx * dx + dy * dy + dz * dz) >= M.MOVE_M
            or headingDiff(cur.h, last.h) >= M.TURN_DEG
            or cur.vkey ~= last.vkey
            or cur.bucket ~= last.bucket
        if not moved then
            if not st.stillSince then st.stillSince = last.t end
            local ref = st.lastStillAt or last.t
            if now - ref >= M.STILL_EVERY_MS then
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

--- Vehicle key: vehicle state used to compare against the last sample.
function M.vehicleKey(model, seat)
    if not model then return 'foot' end
    return model .. ':' .. seat
end

--- Nearby: srcs of `players` ({ src, x, y }) within `radius` of (cx, cy), used by the combat boost.
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
