-- Medical adapter: qbx_medical respawn event and qbx_ambulancejob check-in hook (built against 1.0.0).
-- Hooks: registered on each resource's exports, since both load qbx_core's hook module into their own state.

local NAME_MED, NAME_AMB = 'qbx_medical', 'qbx_ambulancejob'
local checkInCost -- checkInCost: read from qbx_ambulancejob config/shared.lua

-- playerRespawned: fired after qbx_medical's respawn hooks pass; emits medical.respawn and teleport.known 'respawn'.
-- Revive guard: marks the player as respawned, so the following state change is not reported as medical.revive (see qbox.lua).
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
        -- checkIn: fires in canCheckIn() before a bed is assigned; emits medical.checkin
        amb:registerHook('checkIn', onCheckIn)
    end,
})
