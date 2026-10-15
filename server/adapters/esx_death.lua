-- ESX death adapter: esx_death reports deaths and revives with one server event (built against esx_death from ESX Legacy 1.16.0).
-- Event: esx_death:stateChanged(src, dead, reason); reasons are death, respawn, revive, ems, admin, txadmin, restore and logout.

local C = Atlas.characters
local NAME = 'esx_death'

local function active() return Atlas.enabled and Atlas.adapterActive(NAME) and Atlas.adapterActive('esx') end

AddEventHandler('esx_death:stateChanged', function(src, dead, reason)
    if not active() then return end
    src = tonumber(src)
    local p = Atlas.players[src]
    if not p or not p.char then return end
    -- Logout: the character is leaving, which session.char_end reports
    if reason == 'logout' then return end
    dead = dead == true
    p.state = p.state or {}
    p.state.isdead = dead
    p.dead = dead

    if dead then
        Atlas.emit('player.state', { key = 'isdead', value = true }, src, { fresh = true })
        -- Restore: a death saved earlier comes back at login, which is not a new death
        C.markDown(src, 'dead', reason == 'restore')
    else
        Atlas.emit('player.state', { key = 'isdead', value = false }, src, { fresh = true })
        -- Respawn: announced first, so the state change that follows is not reported as a revive
        if reason == 'respawn' then C.respawn(src) end
        C.markUp(src)
    end
end)

Atlas.registerAdapter({
    name = NAME,
    resources = { 'esx_death' },
    attach = function() end,
})
