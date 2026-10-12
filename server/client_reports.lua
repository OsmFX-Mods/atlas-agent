-- Client reports: validates shots-fired reports from client/combat.lua, which are untrusted.
-- Result: accepted events carry trust = "client"; rejects are counted and reported at most once a minute per player.

local cfg = AtlasConfig
local common, shots = AtlasLib.common, AtlasLib.shots
local u32 = common.u32

-- Module flag: client_combat is a non-replicated convar, so clients read it from replicated GlobalState.
GlobalState.atlasClientCombat = cfg.clientCombat

local function serverWeapons(p, src, gt)
    local set = {}
    for h, t in pairs(p.weapons) do
        if gt - t < 60000 then set[h] = true end
    end
    local ped = GetPlayerPed(src)
    if ped and ped ~= 0 then
        local w = GetSelectedPedWeapon(ped)
        if w and w ~= 0 then set[u32(w)] = true end
    end
    if GetResourceState('ox_inventory') == 'started' then
        local ok, weapon = pcall(function() return exports.ox_inventory:GetCurrentWeapon(src) end)
        if ok and type(weapon) == 'table' and type(weapon.name) == 'string' then
            set[u32(GetHashKey(weapon.name))] = true
        end
    end
    return set
end

local function reject(p, src, reason)
    Atlas.drop('shots_' .. reason)
    p.shotsRejected = (p.shotsRejected or 0) + 1
    local gt = GetGameTimer()
    if not p.lastRejectEmit or gt - p.lastRejectEmit >= 60000 then
        p.lastRejectEmit = gt
        Atlas.emit('combat.shots_rejected', { reason = reason, count = p.shotsRejected }, src, { trust = 'derived' })
        p.shotsRejected = 0
    end
end

RegisterNetEvent('atlas:c:shots', function(payload)
    local src = tonumber(source)
    if not Atlas.enabled or not cfg.clientCombat then return end
    local p = Atlas.players[src]
    if not p then return end

    local gt = GetGameTimer()
    if p.lastShotsAt and gt - p.lastShotsAt < 5000 then return reject(p, src, 'rate') end
    p.lastShotsAt = gt

    local positions = Atlas.recentPositions(p)
    local ped = GetPlayerPed(src)
    local alive = not p.dead
    if ped and ped ~= 0 then
        local c = GetEntityCoords(ped)
        positions[#positions + 1] = { c.x, c.y }
        if GetEntityHealth(ped) <= 0 then alive = false end
    end

    local ok, reason, clean = shots.validate(payload, {
        alive = alive,
        positions = positions,
        weapons = serverWeapons(p, src, gt),
    })
    if not ok then return reject(p, src, reason) end

    for i = 1, #clean.reports do
        local r = clean.reports[i]
        Atlas.emit('combat.shots', { weapon = r.weapon, cells = r.cells, window_s = clean.window_s }, src, { trust = 'client' })
    end
end)
