-- Staff: tells Atlas which players hold an in-game staff rank, so their teleports and actions read as staff ones.
-- Rank: the framework's own rank when it keeps one (older QBCore, ESX groups), otherwise the ACE permissions in staffAces.
-- Checks: when a player joins, when a character starts and when Qbox or QBCore changes a player's permissions.

local cfg = AtlasConfig
local S = {}
Atlas.staff = S

--- Role: the staff rank of a player, or nil for a player with none.
function S.role(src)
    local fw = Atlas.framework
    if fw and fw.staffRole then
        local ok, role = pcall(fw.staffRole, src)
        if ok and type(role) == 'string' and role ~= '' then return role:lower():sub(1, 32) end
    end
    for _, entry in ipairs(cfg.staffAces) do
        if IsPlayerAceAllowed(tostring(src), entry[1]) then return entry[2] end
    end
    return nil
end

--- Check: reads the rank again and sends player.staff when it changed; a player who lost their rank is sent without one.
function S.check(src)
    local p = Atlas.players[src]
    if not p then return end
    local role = S.role(src) or false
    local before = p.staff or false
    p.staff = role
    if role == before then return end
    Atlas.emit('player.staff', { role = role or nil }, src)
end

Atlas.onJoin(function(p) S.check(p.src) end)

-- OnPermissionUpdate: Qbox and QBCore fire it after adding or removing a permission.
AddEventHandler('QBCore:Server:OnPermissionUpdate', function(src)
    src = tonumber(src)
    if Atlas.enabled and src then S.check(src) end
end)
