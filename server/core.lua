-- Core: builds events, keeps the player cache and hands events to transport.js.
-- Emit: only builds a table, with no JSON and no waiting, so each event stays cheap.

local lib = AtlasLib
local common = lib.common

Atlas = {
    version = GetResourceMetadata(GetCurrentResourceName(), 'version', 0) or '0.0.0',
    resource = GetCurrentResourceName(),
    enabled = true,
    refused = nil,          -- refused: why the agent stopped itself, if it did
    players = {},           -- players: record per player id (see newPlayer)
    playerList = {},        -- playerList: player ids in order, so the sampler takes turns
    charToSrc = {},         -- charToSrc: character id to player id
    adapters = {},          -- adapters: names set to true while attached (detect.lua)
    drops = {},             -- drops: events lost per reason, sent in the heartbeat
    consoleState = 'off',   -- consoleState: on, unsupported or off, set by console.lua
    js = nil,               -- js: latest stats sent by transport.js
    jsReady = false,
    stats = {
        emits = 0, emitNs = 0, emitMaxNs = 0,   -- emit totals since start
        emitEmaUs = 0.0,
        samplerNs = 0, samplerRuns = 0, samplerMaxNs = 0, samples = 0,
        flushes = 0, flushNs = 0, flushed = 0,
        startedAt = GetGameTimer(),
    },
}

local cfg = AtlasConfig
local nanotime = os.nanotime or function() return math.floor(os.clock() * 1e9) end
Atlas.nanotime = nanotime

-- Clock: adds milliseconds to os.time seconds; the boot id is unique per start.
local clock = lib.clock.new(os.time, GetGameTimer)
Atlas.clock = clock
Atlas.now = clock.now

math.randomseed(os.time() ~ GetGameTimer())
Atlas.boot = common.ulid(clock.now())

-- Clock sync: waits for the next whole second to line up the clock, and repeats every 10 minutes.
CreateThread(function()
    while true do
        while clock.seeking do
            clock.step()
            Wait(0)
        end
        Wait(600000)
        clock.recalibrate()
    end
end)

-- Logging: console helpers; debug lines print only when debug is on.
function Atlas.log(msg, ...)
    print(('^5[atlas]^7 ' .. msg):format(...))
end

function Atlas.warn(msg, ...)
    print(('^3[atlas] WARNING:^7 ' .. msg):format(...))
end

function Atlas.debug(msg, ...)
    if cfg.debug then print(('^5[atlas:debug]^7 ' .. msg):format(...)) end
end

--- Vector constructors: lets lib/sandbox.lua read other resources' configs that use vector types.
function Atlas.vectorCtors()
    return {
        vec = vec, vec2 = vec2, vec3 = vec3, vec4 = vec4,
        vector2 = vector2, vector3 = vector3, vector4 = vector4,
        joaat = GetHashKey,
    }
end

function Atlas.drop(reason, n)
    Atlas.drops[reason] = (Atlas.drops[reason] or 0) + (n or 1)
end

-- Actor: who a player is, attached to every event.
--- Actor rebuild: makes a new table, so queued events keep the identity they were sent with.
function Atlas.rebuildActor(p)
    p.actor = {
        account = p.account,
        char = p.char,
        name = p.charName or p.name,
        job = p.job,
        grade = p.grade,
        duty = p.duty,
        gang = p.gang,
        bucket = p.bucket,
    }
end

local function newPlayer(src)
    local ids, account = common.pickIdentifiers(GetPlayerIdentifiers(src) or {})
    local p = {
        src = src,
        ids = ids,
        account = account,
        name = GetPlayerName(src),
        bucket = GetPlayerRoutingBucket(src),
        sessionId = nil,
        joinedAt = clock.now(),
        pos = nil,          -- pos: last known {x,y,z}
        money = {},         -- money: last known balances, set by the Qbox adapter
        recent = {},        -- recent: last sampled {x,y} points, used to check shot reports
        recentN = 0,
        recentAt = nil,     -- recentAt: game time of the last point
        weapons = {},       -- weapons: when each weapon was last seen, by weapon hash
        dead = false,
    }
    Atlas.rebuildActor(p)
    return p
end

local MAX_WEAPONS, WEAPON_TTL_MS = 64, 120000

--- Note weapon: remembers when a player used a weapon; keeps at most 64 so a client cannot grow the list.
function Atlas.noteWeapon(p, hash, gt)
    local weapons = p.weapons
    if weapons[hash] == nil then
        local count = 0
        for h, t in pairs(weapons) do
            if gt - t > WEAPON_TTL_MS then weapons[h] = nil else count = count + 1 end
        end
        if count >= MAX_WEAPONS then return end
    end
    weapons[hash] = gt
end

function Atlas.getPlayer(src)
    return Atlas.players[src]
end

--- Player record: created when first needed, for players online at start or seen before they join.
function Atlas.ensurePlayer(src)
    src = tonumber(src)
    if not src or src <= 0 then return nil end
    local p = Atlas.players[src]
    if p then return p end
    if not GetPlayerName(src) then return nil end
    p = newPlayer(src)
    Atlas.players[src] = p
    Atlas.playerList[#Atlas.playerList + 1] = src
    return p
end

function Atlas.removePlayer(src)
    local p = Atlas.players[src]
    if not p then return end
    if p.char and Atlas.charToSrc[p.char] == src then Atlas.charToSrc[p.char] = nil end
    Atlas.players[src] = nil
    local list = Atlas.playerList
    for i = #list, 1, -1 do
        if list[i] == src then table.remove(list, i) break end
    end
end

function Atlas.charOf(src)
    local p = Atlas.players[src]
    return p and p.char
end

--- Character: set by the Qbox adapter when a character loads.
function Atlas.setChar(src, char, charName)
    local p = Atlas.ensurePlayer(src)
    if not p then return end
    if p.char and Atlas.charToSrc[p.char] == src then Atlas.charToSrc[p.char] = nil end
    p.char, p.charName = char, charName
    if char then Atlas.charToSrc[char] = src end
    Atlas.rebuildActor(p)
    return p
end

-- Emit: events wait in a buffer until the next flush sends them to transport.js.
local buf, n = {}, 0
local seq = 0
local EMPTY = {}

--- Fresh position: reads the player's current coordinates and updates the cached position.
function Atlas.freshPos(p)
    local ped = GetPlayerPed(p.src)
    if ped and ped ~= 0 then
        local c = GetEntityCoords(ped)
        if c.x ~= 0.0 or c.y ~= 0.0 then
            p.pos = common.pos(c.x, c.y, c.z)
        end
    end
    return p.pos
end

--- Envelope: the event layout, shared by emit and atlas_bench; transport.js adds the version and boot id.
local function build(etype, data, src, opts, s)
    local ev = {
        type = etype,
        ts = (opts and opts.at) or clock.now(),
        seq = s,
        trust = (opts and opts.trust) or 'server',
        data = data or EMPTY,
    }
    if src then
        ev.src = src
        local p = Atlas.players[src]
        if p then
            ev.actor = p.actor
            if opts and opts.fresh then ev.pos = Atlas.freshPos(p) else ev.pos = p.pos end
        end
    end
    if opts then
        if opts.pos then ev.pos = opts.pos end
        if opts.res then ev.res = opts.res end
    end
    return ev
end

--- Emit: queues one event; `opts` is { trust, at, fresh, pos, res }; `src` adds the player and position.
function Atlas.emit(etype, data, src, opts)
    if not Atlas.enabled then return nil end
    local t0 = nanotime()

    seq = seq + 1
    local ev = build(etype, data, src, opts, seq)

    if n >= cfg.luaBufferMax then
        -- Buffer full: the event is dropped and counted; the gap in sequence numbers shows how many.
        Atlas.drop('lua_buffer')
    else
        n = n + 1
        buf[n] = ev
    end

    local dt = nanotime() - t0
    local st = Atlas.stats
    st.emits = st.emits + 1
    st.emitNs = st.emitNs + dt
    if dt > st.emitMaxNs then st.emitMaxNs = dt end
    st.emitEmaUs = st.emitEmaUs * 0.99 + (dt / 1000) * 0.01
    return seq
end

--- Bench: times `count` emits into a scratch buffer, without sending anything.
--- @return number avg_us, number max_us
function Atlas.benchEmit(count, src)
    local scratch, maxNs, total = {}, 0, 0
    local data = { mtype = 'cash', action = 'add', amount = 100, delta = 100, balance_after = 1000, reason = 'bench' }
    for i = 1, count do
        local t0 = nanotime()
        scratch[i] = build('bench.synthetic', data, src, nil, 0)
        local dt = nanotime() - t0
        total = total + dt
        if dt > maxNs then maxNs = dt end
    end
    return total / count / 1000, maxNs / 1000
end

function Atlas.lastSeq() return seq end
function Atlas.bufferDepth() return n end

--- Flush: hands all queued events to transport.js in one call.
function Atlas.flush()
    if n == 0 or not Atlas.jsReady then return end
    local t0 = nanotime()
    local out = buf
    local count = n
    buf, n = {}, 0
    if not pcall(TriggerEvent, 'atlas:internal:batch', out) then
        -- Failed: events are sent one by one, so only the bad one is lost
        for i = 1, count do
            if not pcall(TriggerEvent, 'atlas:internal:batch', { out[i] }) then Atlas.drop('pack_error') end
        end
    end
    local st = Atlas.stats
    st.flushes = st.flushes + 1
    st.flushed = st.flushed + count
    st.flushNs = st.flushNs + (nanotime() - t0)
end

CreateThread(function()
    while true do
        Wait(cfg.flushMs)
        if Atlas.enabled then pcall(Atlas.flush) end
    end
end)

-- Stop: sends what is still queued; transport.js saves it to disk.
AddEventHandler('onResourceStop', function(res)
    if res == Atlas.resource and Atlas.enabled then pcall(Atlas.flush) end
end)

-- Handshake: Lua and transport.js tell each other they are ready; only this resource is accepted.
local function fromSelf()
    local inv = GetInvokingResource()
    return inv == nil or inv == Atlas.resource
end

AddEventHandler('atlas:internal:ready', function()
    if not fromSelf() then return end
    TriggerEvent('atlas:internal:init', { boot = Atlas.boot, version = Atlas.version })
    Atlas.jsReady = true
end)

AddEventHandler('atlas:internal:stats', function(stats)
    if not fromSelf() then return end
    stats.receivedAt = GetGameTimer()
    Atlas.js = stats
end)

AddEventHandler('atlas:internal:refused', function(reason)
    if not fromSelf() then return end
    Atlas.refuse(reason, true)
end)

--- Refuse: stops the agent when the token is missing or exposed.
function Atlas.refuse(reason, fromJs)
    if Atlas.refused then return end
    Atlas.refused = reason
    Atlas.enabled = false
    buf, n = {}, 0
    if not fromJs then TriggerEvent('atlas:internal:refuse', reason) end
    CreateThread(function()
        while Atlas.refused do
            print(('^1[atlas] NOT RUNNING: %s^7'):format(Atlas.refused))
            Wait(60000)
        end
    end)
end

-- Hello: asks transport.js if it is already running.
TriggerEvent('atlas:internal:hello')

-- Token check: the agent refuses to run without a token.
do
    local token = GetConvar('atlas:token', '')
    if token == '' then
        Atlas.refuse('atlas:token is not set. Add `set atlas:token "atl_live_..."` to server.cfg (use set, not setr).')
    end
    -- Token hash: only the hash is kept here; a client reporting it means the token leaked.
    Atlas.tokenHash = token ~= '' and common.u32(GetHashKey(token)) or nil
    token = nil
end

-- Leak check: clients can read the token only if it was set with setr, and then their hash matches.
RegisterNetEvent('atlas:c:env', function(info)
    local src = source
    if type(info) ~= 'table' or not Atlas.tokenHash then return end
    local p = Atlas.players[src]
    if p then
        if p.envReported then return end -- One report per session
        p.envReported = true
    end
    if info.tokenHash and common.u32(info.tokenHash) == Atlas.tokenHash then
        Atlas.refuse('atlas:token is REPLICATED to clients (set with setr). Every player can read it. ' ..
            'Change it to `set atlas:token ...`, rotate the token in the Atlas dashboard, then restart ' .. Atlas.resource .. '.')
    end
end)

-- Join and drop: adapters add callbacks that run when a player joins or leaves.
Atlas.onJoinCbs, Atlas.onDropCbs = {}, {}

function Atlas.onJoin(cb) Atlas.onJoinCbs[#Atlas.onJoinCbs + 1] = cb end
function Atlas.onDrop(cb) Atlas.onDropCbs[#Atlas.onDropCbs + 1] = cb end

function Atlas.runJoin(p, resumed)
    for i = 1, #Atlas.onJoinCbs do
        local ok, err = pcall(Atlas.onJoinCbs[i], p, resumed)
        if not ok then Atlas.warn('join callback failed: %s', err) end
    end
end

function Atlas.runDrop(p, reason)
    for i = 1, #Atlas.onDropCbs do
        local ok, err = pcall(Atlas.onDropCbs[i], p, reason)
        if not ok then Atlas.warn('drop callback failed: %s', err) end
    end
end

-- Heartbeat: sent on an interval; transport.js adds its queue size and drop counts.
-- Logs: the console capture state comes from console.lua.
CreateThread(function()
    while true do
        Wait(cfg.heartbeatMs)
        if Atlas.enabled then
            local adapters = {}
            for name in pairs(Atlas.adapters) do adapters[#adapters + 1] = name end
            table.sort(adapters)
            local drops = {}
            for k, v in pairs(Atlas.drops) do drops[k] = v end
            Atlas.emit('agent.heartbeat', {
                version = Atlas.version,
                adapters = adapters,
                queue = n,
                drops = drops,
                emit_us_avg = math.floor(Atlas.stats.emitEmaUs * 100 + 0.5) / 100,
                players = #Atlas.playerList,
                logs = { console = Atlas.consoleState },
            })
        end
    end
end)
