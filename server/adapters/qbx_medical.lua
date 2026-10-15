-- Medical adapter: qbx_medical respawns and qbx_ambulancejob check-ins (built against 1.0.0).
-- Each resource has its own hooks, so they are added on that resource.

local NAME_MED, NAME_AMB = 'qbx_medical', 'qbx_ambulancejob'
local checkInCost -- checkInCost: read from qbx_ambulancejob config/shared.lua

-- Respawn: sends medical.respawn and teleport.known after qbx_medical's respawn hooks pass.
-- Marks the player as respawned, so the state change after it is not reported as a revive (see qbox.lua).
AddEventHandler('qbx_medical:server:playerRespawned', function(src)
    if not Atlas.enabled or not Atlas.adapterActive(NAME_MED) then return end
    src = tonumber(src)
    local p = Atlas.players[src]
    if p then p.respawned = true end
    Atlas.emit('medical.respawn', {}, src, { fresh = true })
    Atlas.emit('teleport.known', { reason = 'respawn' }, src)
end)

local function onCheckIn(p)
    if not Atlas.enabled or type(p) ~= 'table' then return true end
    pcall(function()
        Atlas.emit('medical.checkin', {
            hospital = type(p.hospitalName) == 'string' and p.hospitalName or nil,
            cost = checkInCost,
        }, tonumber(p.source), { fresh = true })
    end)
    return true
end

Atlas.registerAdapter({
    name = NAME_MED,
    resources = { 'qbx_medical' },
    attach = function() end,
})

Atlas.registerAdapter({
    name = NAME_AMB,
    resources = { 'qbx_ambulancejob' },
    attach = function()
        local cfgSrc = LoadResourceFile('qbx_ambulancejob', 'config/shared.lua')
        local conf = AtlasLib.sandbox.load(cfgSrc, 'qbx_ambulancejob/config/shared.lua', Atlas.vectorCtors())
        checkInCost = type(conf) == 'table' and tonumber(conf.checkInCost) or nil

        local amb = exports.qbx_ambulancejob
        amb:removeHooks()
        -- checkIn: fires before a bed is assigned; sends medical.checkin
        amb:registerHook('checkIn', onCheckIn)
    end,
})
