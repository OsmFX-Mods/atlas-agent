-- Sampler: reads player positions on the server, never from client reports.
-- Schedule: each player is read once per sample interval, spread over 50 ms slices.

local cfg = AtlasConfig
local common, motion = AtlasLib.common, AtlasLib.motion
local u32, perSlice = common.u32, common.perSlice
local sqrt, floor = math.sqrt, math.floor
local nanotime = Atlas.nanotime

local SLICE_MS = 50
local UNARMED = u32(GetHashKey('WEAPON_UNARMED'))
local RING = 24      -- Ring: recent positions kept to check shot reports
local RING_GAP = 3000 -- Ring gap: minimum ms between kept positions

local state = {}      -- state: motion state per player
local lastAt = {}     -- lastAt: game time of the last sample per player
local boostUntil = {} -- boostUntil: game time when the boost ends per player
local cursor = 1

Atlas.sampler = { state = state, boostUntil = boostUntil }

--- Sample: reads one player and returns true if a position was read; `high` marks boost samples.
local function sampleOne(src, gt, high)
    local p = Atlas.players[src]
    if not p then return false end
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false end
    local c = GetEntityCoords(ped)
    local x, y, z = c.x, c.y, c.z
    if x == 0.0 and y == 0.0 then return false end -- Skipped while the player is still loading

    lastAt[src] = gt
    local nowMs = Atlas.now()

    -- Bucket: a change of routing bucket is sent as its own event
    local bucket = GetPlayerRoutingBucket(src)
    if bucket ~= p.bucket then
        local from = p.bucket
        p.bucket = bucket
        Atlas.rebuildActor(p)
        Atlas.emit('bucket.change', { from = from, to = bucket }, src)
    end

    local veh = GetVehiclePedIsIn(ped, false)
    local vmodel, vtype, seat
    if veh and veh ~= 0 then
        vmodel = u32(GetEntityModel(veh))
        vtype = GetVehicleType(veh)
        seat = (GetPedInVehicleSeat(veh, -1) == ped) and 'driver' or 'passenger'
    end

    -- Weapons: remembered to check shot reports
    local w = GetSelectedPedWeapon(ped)
    if w and w ~= 0 then
        w = u32(w)
        if w ~= UNARMED then Atlas.noteWeapon(p, w, gt) end
    end

    local pos = common.pos(x, y, z)
    p.pos = pos -- A new table each time, so queued events keep their own position
    if gt - (p.recentAt or -RING_GAP) >= RING_GAP then
        local ri = p.recentN % RING + 1
        p.recentN, p.recentAt = ri, gt
        p.recent[ri] = { x, y }
    end

    local st = state[src]
    if not st then st = {}; state[src] = st end
    local h = GetEntityHeading(ped)
    local cur = { x = x, y = y, z = z, h = h, vkey = motion.vehicleKey(vmodel, seat), bucket = bucket }
    local decision = motion.decide(st, cur, nowMs, cfg)

    if decision == 'sample' then
        local v = GetEntityVelocity(ped)
        local spd = sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
        Atlas.emit('position.sample', {
            h = floor(h + 0.5),
            spd = floor(spd * 10 + 0.5) / 10,
            veh = vmodel and { model = vmodel, vtype = vtype, seat = seat } or nil,
            hp = GetEntityHealth(ped),
            precision = high and 'high' or 'normal',
        }, src, { at = nowMs })
    elseif decision == 'still' then
        Atlas.emit('position.still', { since_ts = st.stillSince }, src, { at = nowMs })
    end
    Atlas.stats.samples = Atlas.stats.samples + 1
    return true
end

CreateThread(function()
    while true do
        Wait(SLICE_MS)
        if Atlas.enabled then
            local t0 = nanotime()
            local gt = GetGameTimer()
            local list = Atlas.playerList
            local count = #list
            local k = perSlice(count, cfg.sampleMs, SLICE_MS)
            local minGap = cfg.boostSampleMs - 100

            -- Due: each player is read once per sample interval; boosted players are read in the pass below
            local read, scanned = 0, 0
            while read < k and scanned < count do
                if cursor > count then cursor = 1 end
                local src = list[cursor]
                cursor = cursor + 1
                scanned = scanned + 1
                if src and not boostUntil[src] and gt - (lastAt[src] or 0) >= cfg.sampleMs then
                    if sampleOne(src, gt, false) then read = read + 1 end
                end
            end

            if next(boostUntil) then
                for src, untilGt in pairs(boostUntil) do
                    if gt > untilGt or not Atlas.players[src] then
                        boostUntil[src] = nil
                    elseif gt - (lastAt[src] or 0) >= minGap then
                        sampleOne(src, gt, true)
                    end
                end
            end

            local dt = nanotime() - t0
            local st = Atlas.stats
            st.samplerNs = st.samplerNs + dt
            st.samplerRuns = st.samplerRuns + 1
            if dt > st.samplerMaxNs then st.samplerMaxNs = dt end
        end
    end
end)

-- Boost: after a fight, nearby players are sampled more often (see config.lua).
-- Throttle: at most two scans per second for the same area.
local lastBoost = { gt = 0, x = 0.0, y = 0.0 }
function Atlas.boost(x, y)
    if not cfg.combatBoost or not x then return end
    local gt = GetGameTimer()
    if gt - lastBoost.gt < 500 and common.dist2(x, y, lastBoost.x, lastBoost.y) < 50.0 then return end
    lastBoost.gt, lastBoost.x, lastBoost.y = gt, x, y
    local r2 = cfg.boostRadius * cfg.boostRadius
    local untilGt = gt + cfg.boostMs
    for src, p in pairs(Atlas.players) do
        local pos = p.pos
        if pos then
            local dx, dy = pos[1] - x, pos[2] - y
            if dx * dx + dy * dy <= r2 then boostUntil[src] = untilGt end
        end
    end
end

Atlas.onDrop(function(p)
    state[p.src], lastAt[p.src], boostUntil[p.src] = nil, nil, nil
end)

--- Recent positions: the player's last sampled {x, y} points, used to check shot reports.
function Atlas.recentPositions(p)
    local out = {}
    for i = 1, RING do
        if p.recent[i] then out[#out + 1] = p.recent[i] end
    end
    return out
end
