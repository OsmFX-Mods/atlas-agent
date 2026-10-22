-- qb-adminmenu adapter: staff actions from the menu become admin.action, and its teleports become admin.teleport.
-- Signals: the menu's own server events, counted only when the sender passes the menu's own permission check
-- (admin for player options, god for permissions, or the command permission for either), so a refused request sends nothing.
-- Money: the menu has no money options; qb-core's /givemoney is recognised by Atlas from its reason.

local NAME = 'qb_adminmenu'

local function active() return Atlas.enabled and Atlas.adapterActive(NAME) end

--- Staff: the sender's server id, when the sender may use the option; qb-adminmenu bans a sender who may not.
local function staff(src, perm)
    src = tonumber(src)
    if not src or not Atlas.players[src] then return nil end
    local id = tostring(src)
    return (IsPlayerAceAllowed(id, perm) or IsPlayerAceAllowed(id, 'command')) and src or nil
end

--- Target: the server id in the menu's player table, when that player is online.
local function target(player)
    local id = type(player) == 'table' and tonumber(player.id)
    return id and Atlas.players[id] and id or nil
end

--- Action: one menu option done by staff to a player; mover names who a teleport option moves, and makes it an admin.teleport.
local function action(name, mover, perm)
    return function(player, detail)
        local src, to = staff(source, perm or 'admin'), target(player)
        if not active() or not src or not to then return end
        if mover then
            Atlas.adminTeleport(mover == 'staff' and src or to, name, src, to)
        else
            Atlas.adminAction(name, to, GetPlayerName(src), type(detail) == 'string' and detail or nil)
        end
    end
end

RegisterNetEvent('qb-admin:server:kill', action('kill'))
RegisterNetEvent('qb-admin:server:revive', action('revive'))
RegisterNetEvent('qb-admin:server:freeze', action('freeze'))
RegisterNetEvent('qb-admin:server:spectate', action('spectate'))
RegisterNetEvent('qb-admin:server:kick', action('kick'))
RegisterNetEvent('qb-admin:server:ban', function(player, _, reason) action('ban')(player, reason) end)
RegisterNetEvent('qb-admin:server:goto', action('go to player', 'staff'))
RegisterNetEvent('qb-admin:server:intovehicle', action('enter their vehicle', 'staff'))
RegisterNetEvent('qb-admin:server:bring', action('bring', 'target'))

-- setPermissions: the target and the rank arrive apart; the target's new rank is read once qb-core has applied it.
RegisterNetEvent('qb-admin:server:setPermissions', function(targetId, group)
    local rank = type(group) == 'table' and type(group[1]) == 'table' and group[1].rank
    action('set permission', nil, 'god')({ id = targetId }, type(rank) == 'string' and rank or nil)
end)

Atlas.registerAdapter({
    name = NAME,
    resources = { 'qb-adminmenu' },
    attach = function() end,
})
