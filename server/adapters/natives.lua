-- Natives adapter: framework-free and always attached.
-- Covers: sessions, combat, resource starts and stops, txAdmin events and chat.

local cfg = AtlasConfig
local common = AtlasLib.common
local u32 = common.u32

local NAME = 'natives'
local sessionCounter = 0
local connectAt = {} -- connectAt: when each player started connecting, by temporary id

Atlas.lastLethal = Atlas.lastLethal or {} -- lastLethal: the last killing hit per victim { src, char, weapon, gt }, used for combat.death

local function newSessionId(src)
    sessionCounter = sessionCounter + 1
    return ('%s-%d-%d'):format(Atlas.boot, src, sessionCounter)
end

local function startSession(src, resumed, connectMs)
    local p = Atlas.ensurePlayer(src)
    if not p then return end
    if p.sessionId then return p end
    p.sessionId = newSessionId(src)
    p.joinedAt = Atlas.now()
    Atlas.emit('session.start', {
        session_id = p.sessionId,
        name = p.name,
        identifiers = p.ids,
        connect_ms = connectMs,
        resumed = resumed or nil,
    }, src)
    Atlas.runJoin(p, resumed)
    return p
end

-- Sessions: session.start and session.end from connect and drop events.
AddEventHandler('playerConnecting', function(name)
    if not Atlas.enabled then return end
    local tmp = source
    connectAt[tostring(tmp)] = GetGameTimer()
    local ids = common.pickIdentifiers(GetPlayerIdentifiers(tmp) or {})
    Atlas.emit('session.connecting', { name = name, identifiers = ids })
end)

AddEventHandler('playerJoining', function(oldId)
    if not Atlas.enabled then return end
    local src = tonumber(source)
    local key = tostring(oldId)
    local t = connectAt[key]
    connectAt[key] = nil
    startSession(src, false, t and (GetGameTimer() - t) or nil)
end)

AddEventHandler('playerDropped', function(reason)
    local src = tonumber(source)
    local p = Atlas.players[src]
    if not p then return end
    if Atlas.enabled then
        Atlas.runDrop(p, reason) -- Adapters run first, for example to send session.char_end
        Atlas.emit('session.end', {
            session_id = p.sessionId,
            reason = type(reason) == 'string' and reason:sub(1, 256) or nil,
            duration_ms = Atlas.now() - (p.joinedAt or Atlas.now()),
        }, src)
    end
    Atlas.lastLethal[src] = nil
    Atlas.removePlayer(src)
end)

-- Stale attempts: connection attempts that never joined are forgotten
CreateThread(function()
    while true do
        Wait(300000)
        local gt = GetGameTimer()
        for k, t in pairs(connectAt) do
            if gt - t > 600000 then connectAt[k] = nil end
        end
    end
end)

-- Rate cap: limits events per second per player and kind, since modified clients can flood combat events.
local rates = {} -- rates: window start and count per kind and player
local function overRate(kind, src, limit)
    local gt = GetGameTimer()
    local byKind = rates[kind]
    if not byKind then byKind = {}; rates[kind] = byKind end
    local r = byKind[src]
    if not r or gt - r[1] > 1000 then r = { gt, 0 }; byKind[src] = r end
    r[2] = r[2] + 1
    if r[2] > limit then Atlas.drop(kind .. '_rate') return true end
    return false
end

-- Combat: damage and explosion events.
AddEventHandler('weaponDamageEvent', function(sender, data)
    if not Atlas.enabled or type(data) ~= 'table' then return end
    local attacker = tonumber(sender)
    if attacker and overRate('damage', attacker, cfg.damageRatePerSec) then return end
    local netId = data.hitGlobalId
    if (not netId or netId == 0) and type(data.hitGlobalIds) == 'table' then netId = data.hitGlobalIds[1] end
    if not netId or netId == 0 then return end
    local ent = NetworkGetEntityFromNetworkId(netId)
    if not ent or ent == 0 or not DoesEntityExist(ent) or GetEntityType(ent) ~= 1 then return end -- Filter: peds only

    local isPlayer = IsPedAPlayer(ent)
    local victimSrc = isPlayer and NetworkGetEntityOwner(ent) or nil
    local vc = GetEntityCoords(ent)
    local vp = victimSrc and Atlas.players[victimSrc]
    local weapon = u32(data.weaponType)
    local willKill = data.willKill == true

    Atlas.emit('combat.damage', {
        victim = { src = victimSrc, char = vp and Atlas.effectiveChar(vp) or nil, npc = not isPlayer, pos = common.pos(vc.x, vc.y, vc.z) },
        weapon = weapon,
        dmg = tonumber(data.weaponDamage) or 0,
        will_kill = willKill,
        in_vehicle = GetVehiclePedIsIn(ent, false) ~= 0,
    }, attacker, { fresh = true })

    -- Weapons: remembered to check shot reports
    local ap = attacker and Atlas.players[attacker]
    if ap and weapon then Atlas.noteWeapon(ap, weapon, GetGameTimer()) end

    if victimSrc and willKill then
        Atlas.lastLethal[victimSrc] = { src = attacker, char = Atlas.charOf(attacker), weapon = weapon, gt = GetGameTimer() }
    end
    Atlas.boost(vc.x, vc.y)
end)

AddEventHandler('explosionEvent', function(sender, ev)
    if not Atlas.enabled or type(ev) ~= 'table' then return end
    local src = tonumber(sender)
    if src and overRate('explosion', src, cfg.explosionRatePerSec) then return end

    local x, y, z = tonumber(ev.posX), tonumber(ev.posY), tonumber(ev.posZ)
    Atlas.emit('combat.explosion', {
        etype = ev.explosionType,
        owner_src = src,
        scale = ev.damageScale,
        invisible = ev.isInvisible == true,
        audible = ev.isAudible ~= false,
    }, src, { pos = x and common.pos(x, y, z or 0.0) or nil })
    if x then Atlas.boost(x, y) end
end)

Atlas.onDrop(function(p)
    for _, byKind in pairs(rates) do byKind[p.src] = nil end
end)

-- Resource lifecycle: start and stop events that feed automatic annotations.
local function manifestHash(res)
    local content = LoadResourceFile(res, 'fxmanifest.lua') or LoadResourceFile(res, '__resource.lua')
    return content and u32(GetHashKey(content)) or nil
end

AddEventHandler('onResourceStart', function(res)
    if not Atlas.enabled or res == Atlas.resource then return end
    Atlas.emit('resource.lifecycle', {
        name = res,
        state = 'started',
        version = GetResourceMetadata(res, 'version', 0),
        manifest_hash = manifestHash(res),
    })
end)

AddEventHandler('onResourceStop', function(res)
    if not Atlas.enabled or res == Atlas.resource then return end
    Atlas.emit('resource.lifecycle', { name = res, state = 'stopped' })
end)

-- txAdmin events: become admin.action and server.annotation.
-- Privacy: txAdmin identifier lists can contain IP addresses, so they are never sent.
local function adminAction(action, target, by, detail)
    local src = tonumber(target)
    if src and src <= 0 then src = nil end
    local p = src and Atlas.players[src]
    Atlas.emit('admin.action', {
        action = action,
        target_char = p and Atlas.effectiveChar(p) or nil,
        by = type(by) == 'string' and by:sub(1, 64) or nil,
        detail = type(detail) == 'string' and detail:sub(1, 512) or nil,
    }, p and src or nil)
end

AddEventHandler('txAdmin:events:announcement', function(d)
    if not Atlas.enabled or type(d) ~= 'table' then return end
    Atlas.emit('server.annotation', { kind = 'announcement', text = tostring(d.message or ''):sub(1, 512), by = d.author })
end)

local restartAnnounced = false
AddEventHandler('txAdmin:events:scheduledRestart', function(d)
    if not Atlas.enabled or type(d) ~= 'table' then return end
    -- Countdown: the event fires at several steps, so it is recorded once near the end
    local s = tonumber(d.secondsRemaining) or 0
    if s > 60 then
        restartAnnounced = false -- A countdown above a minute is a new one, such as after a cancelled restart
    elseif not restartAnnounced then
        restartAnnounced = true
        Atlas.emit('server.annotation', { kind = 'restart', text = ('scheduled restart in %d s'):format(s) })
    end
end)

AddEventHandler('txAdmin:events:serverShuttingDown', function(d)
    if not Atlas.enabled or type(d) ~= 'table' then return end
    Atlas.emit('server.annotation', { kind = 'restart', text = tostring(d.message or 'server shutting down'):sub(1, 512), by = d.author })
    Atlas.flush()
end)

AddEventHandler('txAdmin:events:playerWarned', function(d)
    if Atlas.enabled and type(d) == 'table' then adminAction('warn', d.targetNetId, d.author, d.reason) end
end)

AddEventHandler('txAdmin:events:playerKicked', function(d)
    if Atlas.enabled and type(d) == 'table' then adminAction('kick', d.target, d.author, d.reason) end
end)

AddEventHandler('txAdmin:events:playerBanned', function(d)
    if not Atlas.enabled or type(d) ~= 'table' then return end
    local detail = d.reason
    if type(detail) == 'string' and type(d.durationTranslated) == 'string' then
        detail = ('%s (%s)'):format(detail, d.durationTranslated)
    end
    adminAction('ban', d.targetNetId, d.author, detail)
end)

AddEventHandler('txAdmin:events:playerHealed', function(d)
    if Atlas.enabled and type(d) == 'table' then adminAction('heal', d.target, d.author, nil) end
end)

-- Chat: length and command name only, unless atlas:chat_content is 1.
AddEventHandler('chatMessage', function(src, _, text)
    if not Atlas.enabled then return end
    local data = common.chatSummary(text, cfg.chatContent)
    if data then Atlas.emit('chat.message', data, tonumber(src)) end
end)

---------------------------------------------------------------------------
Atlas.registerAdapter({
    name = NAME,
    resources = {},
    attach = function()
        -- Resume: players already online when the agent starts or restarts get a resumed session
        for _, s in ipairs(GetPlayers()) do
            startSession(tonumber(s), true, nil)
        end
    end,
})
