-- FiveM stub: fake natives, events and threads so server scripts load and run under plain Lua 5.4.
-- Time: specs advance a fake game timer with fx.advance(ms), which resumes every thread that is due.

local fx = {}

local installed = {}   -- installed: global names set by boot, cleared by teardown
local saved = {}       -- saved: original values of globals that existed before boot
local S              -- S: state of the current boot

local MODULES = {
    'config.lua',
    'server/lib/common.lua', 'server/lib/clock.lua', 'server/lib/motion.lua',
    'server/lib/shots.lua', 'server/lib/inventory.lua', 'server/lib/sandbox.lua',
    'server/core.lua',
}

--- Jenkins one-at-a-time hash over the lowercased string, as GetHashKey returns it (signed 32-bit).
local function joaat(s)
    local h = 0
    s = s:lower()
    for i = 1, #s do
        h = (h + s:byte(i)) & 0xFFFFFFFF
        h = (h + (h << 10)) & 0xFFFFFFFF
        h = h ~ (h >> 6)
    end
    h = (h + (h << 3)) & 0xFFFFFFFF
    h = h ~ (h >> 11)
    h = (h + (h << 15)) & 0xFFFFFFFF
    return h >= 0x80000000 and h - 0x100000000 or h
end
fx.joaat = joaat

local function set(name, value)
    if not installed[name] then
        installed[name] = true
        saved[name] = rawget(_G, name)
    end
    _G[name] = value
end

local function entity(p) return p and p.ped end

local function natives()
    local function player(src) return S.players[src] end
    set('GetCurrentResourceName', function() return S.resource end)
    set('GetResourceMetadata', function() return '0.1.0' end)
    set('GetGameTimer', function() return S.gt end)
    set('GetHashKey', joaat)
    set('GetConvar', function(name, default)
        local v = S.convars[name]
        return v == nil and default or tostring(v)
    end)
    set('GetConvarInt', function(name, default)
        local v = S.convars[name]
        return v == nil and default or tonumber(v)
    end)
    set('GetResourceState', function(name) return S.resources[name] or 'missing' end)
    set('GetInvokingResource', function() return S.invoker end)
    set('LoadResourceFile', function(res, path) return S.files[res .. '/' .. path] end)
    set('GetResourceKvpString', function(key) return S.kvp[key] end)
    set('SetResourceKvp', function(key, value) S.kvp[key] = value end)

    set('GetPlayers', function()
        local out = {}
        for src in pairs(S.players) do out[#out + 1] = tostring(src) end
        table.sort(out)
        return out
    end)
    set('GetPlayerName', function(src) local p = player(src); return p and p.name end)
    set('GetPlayerIdentifiers', function(src) local p = player(src); return p and p.identifiers end)
    set('GetPlayerRoutingBucket', function(src) local p = player(src); return p and p.bucket or 0 end)
    set('GetPlayerPed', function(src) local p = player(src); return p and p.ped and src + 1000 or 0 end)
    set('GetEntityCoords', function(id) local p = S.players[id - 1000]; return p.ped end)
    set('GetEntityHeading', function(id) return entity(S.players[id - 1000]).h or 0.0 end)
    set('GetEntityHealth', function(id) return entity(S.players[id - 1000]).hp or 200 end)
    set('GetEntityVelocity', function(id) return entity(S.players[id - 1000]).vel or { x = 0.0, y = 0.0, z = 0.0 } end)
    set('GetSelectedPedWeapon', function(id) return entity(S.players[id - 1000]).weapon or 0 end)
    set('GetVehiclePedIsIn', function(id) return entity(S.players[id - 1000]).vehicle and id or 0 end)
    set('GetEntityModel', function(id) return entity(S.players[id - 1000]).vehicle.model end)
    set('GetVehicleType', function(id) return entity(S.players[id - 1000]).vehicle.vtype end)
    set('GetPedInVehicleSeat', function(id)
        local veh = entity(S.players[id - 1000]).vehicle
        return veh.driver and id or 0
    end)
end

local function events()
    set('AddEventHandler', function(name, fn)
        local list = S.handlers[name]
        if not list then list = {}; S.handlers[name] = list end
        list[#list + 1] = fn
    end)
    set('RegisterNetEvent', function(name, fn)
        _G.AddEventHandler(name, fn)
    end)
    set('TriggerEvent', function(name, ...)
        S.triggered[#S.triggered + 1] = { name = name, args = table.pack(...) }
        for _, fn in ipairs(S.handlers[name] or {}) do fn(...) end
    end)
    set('GlobalState', {})
    set('exports', setmetatable({}, {
        __call = function(_, name, fn) S.exported[name] = fn end,
        __index = function(_, name) return S.provided[name] end,
    }))
end

local function threads()
    set('CreateThread', function(fn)
        S.threads[#S.threads + 1] = { co = coroutine.create(fn), wake = S.gt }
    end)
    set('Wait', function(ms) coroutine.yield(ms or 0) end)
    set('RegisterCommand', function(name, fn) S.commands[name] = fn end)
    set('SetTimeout', function(ms, fn)
        _G.CreateThread(function() _G.Wait(ms); fn() end)
    end)
    -- Promises: a minimal pending, resolved or rejected cell, awaited by polling inside a thread
    set('promise', { new = function()
        local p = { state = 'pending' }
        function p.resolve(self, v) if self.state == 'pending' then self.state, self.value = 'resolved', v end end
        function p.reject(self, e) if self.state == 'pending' then self.state, self.value = 'rejected', e end end
        return p
    end })
    set('Citizen', { Await = function(p)
        while p.state == 'pending' do coroutine.yield(50) end
        if p.state == 'rejected' then error(p.value, 0) end
        return p.value
    end })
end

--- Boot: installs the stubs and loads the core modules plus `opts.load`.
--- @param opts table? { convars, resources, provided, files, load = { 'server/sampler.lua', ... }, resource }
function fx.boot(opts)
    opts = opts or {}
    fx.teardown()
    S = {
        gt = 10000, wall = 1790000000, resource = opts.resource or 'atlas-agent',
        convars = opts.convars or {}, resources = opts.resources or {},
        players = {}, handlers = {}, triggered = {}, threads = {}, printed = {},
        exported = {}, provided = opts.provided or {}, commands = {}, kvp = {}, files = opts.files or {}, invoker = nil,
    }
    fx.state = S

    local origTime = os.time
    saved.os_time = origTime
    os.time = function(t)
        if t then return origTime(t) end
        return S.wall + S.gt // 1000
    end
    set('print', function(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring((select(i, ...))) end
        S.printed[#S.printed + 1] = table.concat(parts, ' ')
    end)
    set('source', nil)

    natives(); events(); threads()
    for _, name in ipairs({ 'Atlas', 'AtlasLib', 'AtlasConfig' }) do set(name, nil) end
    for _, rel in ipairs(MODULES) do load_module(rel) end
    for _, rel in ipairs(opts.load or {}) do load_module(rel) end
    return S
end

--- Set: installs one more global stub that teardown removes again.
fx.set = set

--- Teardown: removes every stub and loaded global so specs stay independent.
function fx.teardown()
    if not S then return end
    if saved.os_time then os.time = saved.os_time; saved.os_time = nil end
    for name in pairs(installed) do _G[name] = saved[name] end
    installed, saved, S, fx.state = {}, {}, nil, nil
end

--- Add player: registers a fake connected player; `spec.ped` holds the position, heading, health, velocity, weapon and vehicle.
function fx.addPlayer(src, spec)
    spec = spec or {}
    S.players[src] = {
        name = spec.name or ('Player' .. src),
        identifiers = spec.identifiers or { 'license:lic' .. src, 'ip:10.0.0.' .. src },
        bucket = spec.bucket or 0,
        ped = spec.ped,
    }
    return S.players[src]
end

--- Advance: moves the fake clock forward in `tickMs` steps, resuming every thread whose wait has elapsed.
function fx.advance(ms, tickMs)
    tickMs = tickMs or 25
    local target = S.gt + ms
    repeat
        S.gt = math.min(S.gt + tickMs, target)
        for i = 1, #S.threads do
            local t = S.threads[i]
            if t and t.wake <= S.gt and coroutine.status(t.co) == 'suspended' then
                local ok, waitMs = coroutine.resume(t.co)
                if not ok then error(waitMs, 0) end
                t.wake = S.gt + (waitMs or 0)
            end
        end
    until S.gt >= target
end

--- Tick: runs threads that are due now, without moving the clock.
function fx.tick() fx.advance(0) end

--- Net: delivers a client event to its handlers as `src`, like TriggerServerEvent.
function fx.net(name, src, ...)
    _G.source = src
    for _, fn in ipairs(S.handlers[name] or {}) do fn(...) end
    _G.source = nil
end

--- Triggered: argument lists of every TriggerEvent(name, ...) so far.
function fx.triggered(name)
    local out = {}
    for _, e in ipairs(S.triggered) do
        if e.name == name then out[#out + 1] = e.args end
    end
    return out
end

--- Printed: console lines that contain `needle`.
function fx.printed(needle)
    local out = {}
    for _, line in ipairs(S.printed) do
        if line:find(needle, 1, true) then out[#out + 1] = line end
    end
    return out
end

if after_each then after_each(fx.teardown) end

return fx
