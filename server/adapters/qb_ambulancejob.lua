-- qb-ambulancejob adapter: hospital respawns and check-ins (built against the qb-ambulancejob of 2026).
-- Deaths and revives come from the isdead and inlaststand metadata, which the QBCore adapter reads.
-- Signals: both are client requests that qb-ambulancejob acts on; a respawn counts only for a character that is down.

local NAME = 'qb_ambulancejob'
local conf -- conf: qb-ambulancejob's Config, read when the adapter attaches

local function active() return Atlas.enabled and Atlas.adapterActive(NAME) and Atlas.adapterActive('qbcore') end

local function hospitalName(index)
    local list = type(conf) == 'table' and type(conf.Locations) == 'table' and conf.Locations.hospital
    local h = type(list) == 'table' and list[tonumber(index)]
    return type(h) == 'table' and type(h.name) == 'string' and h.name or nil
end

local function down(src)
    local p = Atlas.players[src]
    return p and p.char and p.down and p or nil
end

-- Respawn: the player gave up and is sent to a hospital bed; sends medical.respawn, so the state change after it is not a revive.
RegisterNetEvent('hospital:server:RespawnAtHospital', function()
    local src = tonumber(source)
    if not active() or not src or not down(src) then return end
    Atlas.characters.respawn(src)
end)

-- Check-in: the player paid for treatment at a hospital; sends medical.checkin with the hospital and the bill.
RegisterNetEvent('hospital:server:SendToBed', function(_, _, hospitalIndex)
    local src = tonumber(source)
    local p = src and Atlas.players[src]
    if not active() or not p or not p.char then return end
    Atlas.emit('medical.checkin', {
        hospital = hospitalName(hospitalIndex),
        cost = type(conf) == 'table' and tonumber(conf.BillCost) or nil,
    }, src, { fresh = true })
end)

Atlas.registerAdapter({
    name = NAME,
    resources = { 'qb-ambulancejob' },
    attach = function()
        local read = Atlas.frameworkData.qbcore and Atlas.frameworkData.qbcore.config
        conf = read and read('qb-ambulancejob') or nil
    end,
})
