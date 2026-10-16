-- ESX ambulance adapter: deaths and revives for ESX before 1.16, where esx_ambulancejob handles them (checked against 1.13 to 1.15).
-- Source: esx_ambulancejob sets the server-side isDead state on every death, revive and respawn, so that is the state read here.
-- Events: esx:onPlayerDeath marks a new death, and the removeItemsAfterRPDeath callback marks a hospital respawn.
-- Not used when esx_death is running, since it reports all of this itself (see esx_death.lua).

local cfg = AtlasConfig
local C = Atlas.characters
local NAME = 'esx_ambulancejob'

local signals = {} -- signals: signals[src] = { death = game time, respawn = game time } of the last event seen

local function active()
    return Atlas.enabled and Atlas.adapterActive(NAME) and Atlas.adapterActive('esx') and GetResourceState('esx_death') ~= 'started'
end

local function mark(src, kind)
    src = tonumber(src)
    if not src then return end
    signals[src] = signals[src] or {}
    signals[src][kind] = GetGameTimer()
end

--- Seen: whether the event arrived recently; it counts once.
local function seen(src, kind)
    local s = signals[src]
    if not (s and s[kind]) then return false end
    local recent = GetGameTimer() - s[kind] <= cfg.esx.deathSignalMs
    s[kind] = nil
    return recent
end

-- Death: the client reports it to the server when the character goes down.
AddEventHandler('esx:onPlayerDeath', function()
    if active() then mark(source, 'death') end
end)

-- Respawn: a hospital respawn goes through this callback; a revive does not.
AddEventHandler('esx:triggerServerCallback', function(name)
    if active() and name == 'esx_ambulancejob:removeItemsAfterRPDeath' then mark(source, 'respawn') end
end)

local function dead(src)
    local ok, v = pcall(function() return Player(src).state.isDead end)
    return ok and v == true
end

-- State: reads the dead state once its matching event has had time to arrive.
AddStateBagChangeHandler('isDead', nil, function(bag)
    if not active() then return end
    local src = GetPlayerFromStateBagName(bag)
    if not src or src == 0 then return end
    CreateThread(function()
        Wait(cfg.esx.deathSettleMs)
        local p = Atlas.players[src]
        if not active() or not p or not p.char then return end
        local now = dead(src)
        if now == p.dead then return end
        p.state = p.state or {}
        p.state.isdead = now
        p.dead = now
        Atlas.emit('player.state', { key = 'isdead', value = now }, src, { fresh = true })
        if now then
            -- Restore: a death saved earlier comes back at login without a death event, which is not a new death
            C.markDown(src, 'dead', not seen(src, 'death'))
        else
            if seen(src, 'respawn') then C.respawn(src) end
            C.markUp(src)
        end
    end)
end)

Atlas.onDrop(function(p) signals[p.src] = nil end)

Atlas.registerAdapter({
    name = NAME,
    resources = { 'esx_ambulancejob' },
    attach = function() end,
})
