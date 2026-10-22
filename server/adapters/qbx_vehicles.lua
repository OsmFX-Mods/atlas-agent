-- Vehicles adapter: listens to qbx_vehicles hooks (built against 1.4.2).
-- Hooks: createPlayerVehicle sends vehicle.acquire; changeVehicleOwner sends vehicle.transfer. Both run before the database write.

local common = AtlasLib.common
local NAME = 'qbx_vehicles'

local function active() return Atlas.enabled and Atlas.adapterActive(NAME) end

local function plateHash(plate)
    if type(plate) ~= 'string' then return nil end
    local s = plate:upper():gsub('^%s+', ''):gsub('%s+$', '')
    return common.u32(GetHashKey(s))
end

local function onCreate(p)
    if not active() or type(p) ~= 'table' then return true end
    local ok, err = pcall(function()
        local props = type(p.props) == 'table' and p.props or {}
        local src = p.citizenid and Atlas.charToSrc[p.citizenid] or nil
        Atlas.emit('vehicle.acquire', {
            model = common.u32(props.model),
            plate_hash = plateHash(props.plate),
            owner_char = p.citizenid,
            garage = p.garage,
        }, src)
    end)
    if not ok then Atlas.drop('qbx_hook_error'); Atlas.debug('createPlayerVehicle hook: %s', tostring(err)) end
    return true
end

local function onOwnerChange(p)
    if not active() or type(p) ~= 'table' then return true end
    local at = Atlas.now()
    local vehicleId, toChar = tonumber(p.vehicleId), p.newCitizenId
    -- Model and plate need a database read, which hooks cannot wait for, so a thread reads them
    CreateThread(function()
        local t = common.sqlName(AtlasConfig.qbox.tables.vehicles)
        local row = vehicleId and t and Atlas.db.single(('SELECT hash, plate FROM %s WHERE id = ?'):format(t), { vehicleId })
        local src = toChar and Atlas.charToSrc[toChar] or nil
        Atlas.emit('vehicle.transfer', {
            model = row and common.u32(tonumber(row.hash)) or nil,
            plate_hash = row and plateHash(row.plate) or nil,
            to_char = toChar,
            vehicle_id = vehicleId,
        }, src, { at = at })
    end)
    return true
end

Atlas.registerAdapter({
    name = NAME,
    resources = { 'qbx_vehicles' },
    attach = function()
        local v = exports.qbx_vehicles
        v:removeHooks()
        v:registerHook('createPlayerVehicle', onCreate)
        v:registerHook('changeVehicleOwner', onOwnerChange)
    end,
})
