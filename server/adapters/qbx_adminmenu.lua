-- qbx_adminmenu adapter: staff actions from the Qbox admin menu become admin.action, and its teleports become admin.teleport.
-- Signals: the menu's own server events, counted only when the sender passes the same checks the menu makes
-- (its configured permission for the option, and admin messages turned on), so a refused request sends nothing.
-- Money: the menu sets cash and bank with the reason qbx_adminmenu, which Atlas already counts as staff money.

local NAME = 'qbx_adminmenu'

local function active() return Atlas.enabled and Atlas.adapterActive(NAME) end

-- perms: the menu's eventPerms, read from its config when it attaches; these are the values it ships with
local perms = { playerOptionsGeneral = 'mod', kick = 'mod', ban = 'admin', changePerms = 'admin', changePlayerData = 'admin', giveAllWeapons = 'admin' }

-- GENERAL: the menu's player options in its own order; mover is the player an option teleports
local GENERAL = {
    { 'kill' }, { 'revive' }, { 'freeze' }, { 'go to player', 'staff' }, { 'bring', 'target' }, { 'enter their vehicle', 'staff' },
    { 'set routing bucket' },
}
-- ADMINISTRATION: the menu's administration options in its own order, with the permission each checks
local ADMINISTRATION = { { 'kick', 'kick' }, { 'ban', 'ban' }, { 'set permission', 'changePerms' } }

--- Staff: the sender's server id, when the menu lets the sender use the option.
local function staff(src, perm)
    src = tonumber(src)
    if not src or not Atlas.players[src] or not IsPlayerAceAllowed(tostring(src), perms[perm]) then return nil end
    local ok, optin = pcall(function() return exports.qbx_core:IsOptin(src) end)
    return (not ok or optin ~= false) and src or nil
end

--- Target: the server id in the menu's player table, when that player is online.
local function target(player)
    local id = type(player) == 'table' and tonumber(player.id)
    return id and Atlas.players[id] and id or nil
end

local function record(src, name, to, mover, detail)
    if mover then return Atlas.adminTeleport(mover == 'staff' and src or to, name, src, to) end
    Atlas.adminAction(name, to, GetPlayerName(src), detail)
end

RegisterNetEvent('qbx_admin:server:playerOptionsGeneral', function(selected, player, input)
    local src, to, option = staff(source, 'playerOptionsGeneral'), target(player), GENERAL[tonumber(selected)]
    if not active() or not src or not to or not option then return end
    record(src, option[1], to, option[2], option[1] == 'set routing bucket' and tostring(input) or nil)
end)

RegisterNetEvent('qbx_admin:server:playerAdministration', function(selected, player, input)
    local option = ADMINISTRATION[tonumber(selected)]
    local src, to = option and staff(source, option[2]), target(player)
    if not active() or not src or not to then return end
    local detail -- detail: the kick or ban reason, or the rank given
    if type(input) == 'string' then detail = input elseif type(input) == 'table' and type(input[1]) == 'string' then detail = input[1] end
    record(src, option[1], to, nil, detail)
end)

RegisterNetEvent('qbx_admin:server:changePlayerData', function(selected, player)
    local src, to = staff(source, 'changePlayerData'), target(player)
    if not active() or not src or not to or type(selected) ~= 'string' then return end
    record(src, 'change ' .. selected:sub(1, 32), to)
end)

RegisterNetEvent('qbx_admin:server:giveAllWeapons', function(weaponType, playerId)
    local src = staff(source, 'giveAllWeapons')
    local to = src and (target({ id = playerId }) or src)
    if not active() or not src then return end
    record(src, 'give weapons', to, nil, type(weaponType) == 'string' and weaponType:sub(1, 32) or nil)
end)

Atlas.registerAdapter({
    name = NAME,
    resources = { 'qbx_adminmenu' },
    attach = function()
        local conf = AtlasLib.sandbox.load(LoadResourceFile('qbx_adminmenu', 'config/server.lua'), 'qbx_adminmenu/config/server.lua')
        local event = type(conf) == 'table' and conf.eventPerms
        if type(event) ~= 'table' then return end
        for key in pairs(perms) do
            if type(event[key]) == 'string' then perms[key] = event[key] end
        end
    end,
})
