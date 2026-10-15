local fx = load_module('tests/fivem.lua')

-- Token: its hash has the top bit set, so GetHashKey returns it negative and clients report it signed
local TOKEN = 'atl_live_demo_token_1'

local function boot(opts)
    opts = opts or {}
    opts.convars = opts.convars or { ['atlas:token'] = TOKEN }
    fx.boot(opts)
    return Atlas
end

local function ped(x, y, z) return { x = x, y = y, z = z or 30.0, h = 0.0 } end

describe('core.emit', function()
    it('stamps a sequential envelope with server trust by default', function()
        boot()
        local s1 = Atlas.emit('money.change', { amount = 5 })
        local s2 = Atlas.emit('money.change')
        expect(s1).toBe(1)
        expect(s2).toBe(2)
        expect(Atlas.bufferDepth()).toBe(2)
        Atlas.jsReady = true
        Atlas.flush()
        local batch = fx.triggered('atlas:internal:batch')[1][1]
        expect(batch[1].type).toBe('money.change')
        expect(batch[1].trust).toBe('server')
        expect(batch[1].seq).toBe(1)
        expect(batch[1].data.amount).toBe(5)
        expect(next(batch[2].data)).toBeNil()
        fx.teardown()
    end)

    it('attaches the actor and last known position when a src is given', function()
        boot()
        fx.addPlayer(7, { name = 'Ann', ped = ped(10.04, 20.06) })
        local p = Atlas.ensurePlayer(7)
        Atlas.setChar(7, 'CHAR0007', 'Ann Lee')
        p.pos = { 1.0, 2.0, 3.0 }
        Atlas.jsReady = true
        Atlas.emit('job.change', {}, 7)
        Atlas.flush()
        local ev = fx.triggered('atlas:internal:batch')[1][1][1]
        expect(ev.src).toBe(7)
        expect(ev.actor.char).toBe('CHAR0007')
        expect(ev.actor.name).toBe('Ann Lee')
        expect(ev.pos).toEqual({ 1.0, 2.0, 3.0 })
        fx.teardown()
    end)

    it('reads a fresh rounded position for opts.fresh and honours opts.pos and opts.res', function()
        boot()
        fx.addPlayer(7, { ped = ped(10.04, 20.06, 5.55) })
        Atlas.ensurePlayer(7)
        Atlas.jsReady = true
        Atlas.emit('a', {}, 7, { fresh = true, res = 'qb-shops' })
        Atlas.emit('b', {}, 7, { pos = { 9.0, 9.0, 9.0 } })
        Atlas.flush()
        local evs = fx.triggered('atlas:internal:batch')[1][1]
        expect(evs[1].pos).toEqual({ 10.0, 20.1, 5.6 })
        expect(evs[1].res).toBe('qb-shops')
        expect(evs[2].pos).toEqual({ 9.0, 9.0, 9.0 })
        fx.teardown()
    end)

    it('keeps the identity an event was emitted with after the player changes job', function()
        boot()
        fx.addPlayer(7, { ped = ped(1, 1) })
        local p = Atlas.ensurePlayer(7)
        p.job = 'police'
        Atlas.rebuildActor(p)
        Atlas.emit('first', {}, 7)
        p.job = 'ems'
        Atlas.rebuildActor(p)
        Atlas.emit('second', {}, 7)
        Atlas.jsReady = true
        Atlas.flush()
        local evs = fx.triggered('atlas:internal:batch')[1][1]
        expect(evs[1].actor.job).toBe('police')
        expect(evs[2].actor.job).toBe('ems')
        fx.teardown()
    end)

    it('drops and counts events once the buffer is full, leaving a seq gap', function()
        boot()
        AtlasConfig.luaBufferMax = 3
        for _ = 1, 5 do Atlas.emit('x') end
        expect(Atlas.bufferDepth()).toBe(3)
        expect(Atlas.drops.lua_buffer).toBe(2)
        expect(Atlas.lastSeq()).toBe(5)
        fx.teardown()
    end)

    it('returns nil and buffers nothing while disabled', function()
        boot()
        Atlas.enabled = false
        expect(Atlas.emit('x')).toBeNil()
        expect(Atlas.bufferDepth()).toBe(0)
        fx.teardown()
    end)
end)

describe('core.flush', function()
    it('holds events until transport.js announces itself, then sends them in order', function()
        boot()
        Atlas.emit('a'); Atlas.emit('b')
        Atlas.flush()
        expect(#fx.triggered('atlas:internal:batch')).toBe(0)
        expect(Atlas.bufferDepth()).toBe(2)
        fx.net('atlas:internal:ready', nil)
        expect(Atlas.jsReady).toBe(true)
        Atlas.flush()
        local sent = fx.triggered('atlas:internal:batch')[1][1]
        expect(#sent).toBe(2)
        expect(sent[1].type).toBe('a')
        expect(sent[2].type).toBe('b')
        expect(Atlas.bufferDepth()).toBe(0)
        expect(Atlas.stats.flushed).toBe(2)
        fx.teardown()
    end)

    it('isolates an event the packer rejects and still sends the rest', function()
        boot()
        local deliver = TriggerEvent
        fx.set('TriggerEvent', function(name, ...)
            local args = { ... }
            if name == 'atlas:internal:batch' then
                for _, ev in ipairs(args[1]) do
                    if ev.data.poison then error('cannot pack') end
                end
            end
            return deliver(name, ...)
        end)
        Atlas.jsReady = true
        Atlas.emit('good1', {}); Atlas.emit('bad', { poison = true }); Atlas.emit('good2', {})
        Atlas.flush()
        local sent = {}
        for _, call in ipairs(fx.triggered('atlas:internal:batch')) do
            for _, ev in ipairs(call[1]) do sent[#sent + 1] = ev.type end
        end
        expect(sent).toEqual({ 'good1', 'good2' })
        expect(Atlas.drops.pack_error).toBe(1)
        expect(Atlas.bufferDepth()).toBe(0)
        fx.teardown()
    end)

    it('keeps flushing on its timer after a pack failure', function()
        boot()
        local deliver = TriggerEvent
        local fail = true
        fx.set('TriggerEvent', function(name, ...)
            if name == 'atlas:internal:batch' and fail then error('cannot pack') end
            return deliver(name, ...)
        end)
        Atlas.jsReady = true
        fx.tick()
        Atlas.emit('lost')
        fx.advance(AtlasConfig.flushMs + 50)
        fail = false
        Atlas.emit('kept')
        fx.advance(AtlasConfig.flushMs + 50)
        local sent = {}
        for _, call in ipairs(fx.triggered('atlas:internal:batch')) do
            for _, ev in ipairs(call[1]) do sent[#sent + 1] = ev.type end
        end
        expect(sent).toEqual({ 'kept' })
        fx.teardown()
    end)

    it('flushes on its own timer', function()
        boot()
        Atlas.jsReady = true
        fx.tick()
        Atlas.emit('a')
        fx.advance(AtlasConfig.flushMs + 50)
        expect(#fx.triggered('atlas:internal:batch')).toBe(1)
        fx.teardown()
    end)

    it('hands over the buffered events when the resource stops', function()
        boot()
        Atlas.jsReady = true
        Atlas.emit('last')
        fx.net('onResourceStop', nil, 'someone-else')
        expect(Atlas.bufferDepth()).toBe(1)
        fx.net('onResourceStop', nil, Atlas.resource)
        expect(Atlas.bufferDepth()).toBe(0)
        expect(fx.triggered('atlas:internal:batch')[1][1][1].type).toBe('last')
        fx.teardown()
    end)

    it('answers the handshake with the boot id and version', function()
        boot()
        fx.net('atlas:internal:ready', nil)
        local init = fx.triggered('atlas:internal:init')[1][1]
        expect(init.boot).toBe(Atlas.boot)
        expect(init.version).toBe('0.1.0')
        expect(#Atlas.boot).toBe(26)
        fx.teardown()
    end)

    it('ignores handshake and stats events sent by another resource', function()
        boot()
        fx.state.invoker = 'some-other-resource'
        fx.net('atlas:internal:ready', nil)
        fx.net('atlas:internal:stats', nil, { state = 'forged' })
        fx.net('atlas:internal:refused', nil, 'forged refusal')
        expect(Atlas.jsReady).toBe(false)
        expect(Atlas.js).toBeNil()
        expect(Atlas.refused).toBeNil()
        fx.teardown()
    end)
end)

describe('core token handling', function()
    it('refuses to run without a token and clears what was buffered', function()
        boot({ convars = {} })
        expect(Atlas.refused ~= nil).toBe(true)
        expect(Atlas.refused:find('atlas:token is not set', 1, true) ~= nil).toBe(true)
        expect(Atlas.enabled).toBe(false)
        expect(Atlas.emit('x')).toBeNil()
        expect(Atlas.tokenHash).toBeNil()
        fx.teardown()
    end)

    it('keeps only a hash of the token in Lua', function()
        boot()
        expect(fx.joaat(TOKEN) < 0).toBe(true)
        expect(Atlas.tokenHash).toBe(AtlasLib.common.u32(fx.joaat(TOKEN)))
        local seen = {}
        local function scan(t)
            if seen[t] then return false end
            seen[t] = true
            for k, v in pairs(t) do
                if type(k) == 'string' and k:find(TOKEN, 1, true) then return true end
                if type(v) == 'string' and v:find(TOKEN, 1, true) then return true end
                if type(v) == 'table' and scan(v) then return true end
            end
            return false
        end
        expect(scan(Atlas)).toBe(false)
        expect(scan(AtlasConfig)).toBe(false)
        fx.teardown()
    end)

    it('refuses when a client reports the token hash, signed or unsigned', function()
        for _, report in ipairs({ fx.joaat(TOKEN), AtlasLib.common.u32(fx.joaat(TOKEN)) }) do
            boot()
            fx.addPlayer(3, {})
            Atlas.ensurePlayer(3)
            fx.net('atlas:c:env', 3, { tokenHash = report })
            expect(Atlas.refused ~= nil).toBe(true)
            expect(Atlas.refused:find('REPLICATED', 1, true) ~= nil).toBe(true)
            expect(Atlas.refused:find('atlas-agent', 1, true) ~= nil).toBe(true)
            expect(Atlas.enabled).toBe(false)
            fx.teardown()
        end
    end)

    it('stays running when the reported hash does not match', function()
        boot()
        fx.addPlayer(3, {})
        Atlas.ensurePlayer(3)
        fx.net('atlas:c:env', 3, { tokenHash = 12345 })
        fx.net('atlas:c:env', 3, 'not a table')
        fx.net('atlas:c:env', 3, {})
        expect(Atlas.refused).toBeNil()
        expect(Atlas.enabled).toBe(true)
        fx.teardown()
    end)

    it('accepts one environment report per player session', function()
        boot()
        fx.addPlayer(3, {})
        Atlas.ensurePlayer(3)
        fx.net('atlas:c:env', 3, { tokenHash = 1 })
        fx.net('atlas:c:env', 3, { tokenHash = fx.joaat(TOKEN) })
        expect(Atlas.refused).toBeNil()
        fx.teardown()
    end)

    it('drops events that were buffered when it refuses', function()
        boot()
        Atlas.emit('a'); Atlas.emit('b')
        Atlas.refuse('test')
        Atlas.jsReady = true
        Atlas.flush()
        expect(Atlas.bufferDepth()).toBe(0)
        expect(#fx.triggered('atlas:internal:batch')).toBe(0)
        fx.teardown()
    end)

    it('repeats the refusal on the console every minute', function()
        boot({ convars = {} })
        fx.tick()
        local first = #fx.printed('NOT RUNNING')
        fx.advance(61000, 1000)
        expect(first).toBe(1)
        expect(#fx.printed('NOT RUNNING') >= 2).toBe(true)
        fx.teardown()
    end)
end)

describe('core identity cache', function()
    it('creates one record per online player and ignores unknown sources', function()
        boot()
        fx.addPlayer(4, { identifiers = { 'license:aaa', 'ip:1.2.3.4', 'discord:9' } })
        local p = Atlas.ensurePlayer(4)
        expect(Atlas.ensurePlayer('4')).toBe(p)
        expect(#Atlas.playerList).toBe(1)
        expect(p.ids.ip).toBeNil()
        expect(p.account).toBe('license:aaa')
        expect(Atlas.ensurePlayer(99)).toBeNil()
        expect(Atlas.ensurePlayer(0)).toBeNil()
        expect(Atlas.ensurePlayer('x')).toBeNil()
        fx.teardown()
    end)

    it('moves the character mapping when a character changes', function()
        boot()
        fx.addPlayer(4, {})
        Atlas.setChar(4, 'CHAR_A', 'A')
        expect(Atlas.charToSrc.CHAR_A).toBe(4)
        Atlas.setChar(4, 'CHAR_B', 'B')
        expect(Atlas.charToSrc.CHAR_A).toBeNil()
        expect(Atlas.charOf(4)).toBe('CHAR_B')
        expect(Atlas.players[4].actor.name).toBe('B')
        fx.teardown()
    end)

    it('removes a player from every index and keeps a reused character mapping', function()
        boot()
        fx.addPlayer(4, {}); fx.addPlayer(5, {}); fx.addPlayer(6, {})
        Atlas.setChar(4, 'CHAR_A', 'A')
        Atlas.ensurePlayer(5); Atlas.ensurePlayer(6)
        Atlas.setChar(5, 'CHAR_A', 'A')
        Atlas.removePlayer(4)
        expect(Atlas.players[4]).toBeNil()
        expect(Atlas.playerList).toEqual({ 5, 6 })
        expect(Atlas.charToSrc.CHAR_A).toBe(5)
        Atlas.removePlayer(5)
        expect(Atlas.charToSrc.CHAR_A).toBeNil()
        Atlas.removePlayer(1234)
        fx.teardown()
    end)

    it('runs every join and drop callback even when one fails', function()
        boot()
        local calls = {}
        Atlas.onJoin(function() error('boom') end)
        Atlas.onJoin(function(p, resumed) calls[#calls + 1] = 'join:' .. tostring(resumed) end)
        Atlas.onDrop(function() error('boom') end)
        Atlas.onDrop(function(p, reason) calls[#calls + 1] = 'drop:' .. reason end)
        Atlas.runJoin({}, true)
        Atlas.runDrop({}, 'quit')
        expect(calls).toEqual({ 'join:true', 'drop:quit' })
        expect(#fx.printed('callback failed')).toBe(2)
        fx.teardown()
    end)
end)

describe('core heartbeat', function()
    it('reports sorted adapters, a copy of the drop counters and the player count', function()
        boot()
        Atlas.adapters.qbox, Atlas.adapters.natives = true, true
        Atlas.drop('shots_rate', 3)
        fx.addPlayer(4, {})
        Atlas.ensurePlayer(4)
        fx.tick()
        fx.advance(AtlasConfig.heartbeatMs + 100)
        Atlas.jsReady = true
        Atlas.flush()
        local hb
        for _, ev in ipairs(fx.triggered('atlas:internal:batch')[1][1]) do
            if ev.type == 'agent.heartbeat' then hb = ev end
        end
        expect(hb ~= nil).toBe(true)
        expect(hb.data.adapters).toEqual({ 'natives', 'qbox' })
        expect(hb.data.drops.shots_rate).toBe(3)
        expect(hb.data.players).toBe(1)
        expect(hb.data.version).toBe('0.1.0')
        hb.data.drops.shots_rate = 99
        expect(Atlas.drops.shots_rate).toBe(3)
        fx.teardown()
    end)

    it('reports the console state in the heartbeat', function()
        boot()
        Atlas.consoleState = 'unsupported'
        fx.tick()
        fx.advance(AtlasConfig.heartbeatMs + 100)
        Atlas.jsReady = true
        Atlas.flush()
        local hb
        for _, ev in ipairs(fx.triggered('atlas:internal:batch')[1][1]) do
            if ev.type == 'agent.heartbeat' then hb = ev end
        end
        expect(hb.data.logs).toEqual({ console = 'unsupported' })
        fx.teardown()
    end)

    it('stops once the agent refuses', function()
        boot()
        fx.tick()
        Atlas.refuse('test')
        fx.advance(AtlasConfig.heartbeatMs * 3)
        local found = false
        Atlas.jsReady = true
        Atlas.flush()
        for _, batch in ipairs(fx.triggered('atlas:internal:batch')) do
            for _, ev in ipairs(batch[1]) do if ev.type == 'agent.heartbeat' then found = true end end
        end
        expect(found).toBe(false)
        fx.teardown()
    end)
end)

describe('core clock', function()
    it('calibrates to the second edge shortly after start', function()
        boot()
        expect(Atlas.clock.calibrated).toBe(false)
        fx.tick()
        fx.advance(1500)
        expect(Atlas.clock.calibrated).toBe(true)
        expect(Atlas.now() % 1 == 0).toBe(true)
        fx.teardown()
    end)
end)

describe('core weapon notes', function()
    local function player()
        fx.boot({ convars = { ['atlas:token'] = 'atl_live_x' } })
        fx.addPlayer(1, {})
        return Atlas.ensurePlayer(1)
    end

    it('records the time a weapon was last used', function()
        local p = player()
        Atlas.noteWeapon(p, 453432689, 12345)
        expect(p.weapons[453432689]).toBe(12345)
        fx.teardown()
    end)

    it('stops accepting new hashes at 64 while recent ones fill the table', function()
        local p = player()
        for h = 1, 200 do Atlas.noteWeapon(p, h, 50000) end
        local n = 0
        for _ in pairs(p.weapons) do n = n + 1 end
        expect(n).toBe(64)
        Atlas.noteWeapon(p, 1, 60000)
        expect(p.weapons[1]).toBe(60000)
        fx.teardown()
    end)

    it('drops entries older than two minutes to make room', function()
        local p = player()
        for h = 1, 64 do Atlas.noteWeapon(p, h, 1000) end
        Atlas.noteWeapon(p, 999, 200000)
        expect(p.weapons[999]).toBe(200000)
        expect(p.weapons[1]).toBeNil()
        fx.teardown()
    end)
end)
