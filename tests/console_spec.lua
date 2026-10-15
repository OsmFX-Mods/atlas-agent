local fx = load_module('tests/fivem.lua')

-- Listener: the stub native keeps the callback so specs can feed console lines to it
local listener

local function boot(convars, native, tweak)
    convars = convars or {}
    convars['atlas:token'] = 'atl_live_x'
    listener = nil
    fx.boot({ convars = convars })
    if native ~= false then
        fx.set('RegisterConsoleListener', native or function(fn) listener = fn end)
    end
    if tweak then tweak(AtlasConfig) end
    load_module('server/console.lua')
    fx.tick() -- tick: starts the flush thread so its 1 s wait begins now
end

local function batches()
    Atlas.jsReady = true
    Atlas.flush()
    local out = {}
    for _, call in ipairs(fx.triggered('atlas:internal:batch')) do
        for _, ev in ipairs(call[1]) do
            if ev.type == 'console.lines' then out[#out + 1] = ev end
        end
    end
    return out
end

local function kept(channel, text)
    local before = #batches()
    listener(channel, text)
    fx.advance(1000)
    return #batches() > before
end

describe('console filter', function()
    it('keeps errors, warnings, failures and hitches and ignores the rest', function()
        boot()
        for _, text in ipairs({ 'SCRIPT ERROR: @res/a.lua:3: boom', 'Error loading script', 'request failed', 'Warning: slow', 'server thread hitch warning' }) do
            listener('script:res', text)
        end
        for _, text in ipairs({ 'Started resource res', 'player joined', 'hello world' }) do
            listener('script:res', text)
        end
        fx.advance(1000)
        local evs = batches()
        expect(#evs).toBe(1)
        expect(#evs[1].data.lines).toBe(5)
        expect(evs[1].data.lines[1].t).toBe('SCRIPT ERROR: @res/a.lua:3: boom')
        fx.teardown()
    end)

    it('does nothing while the agent is disabled', function()
        boot()
        Atlas.enabled = false
        listener('script:res', 'SCRIPT ERROR: boom')
        Atlas.enabled = true
        fx.advance(1000)
        expect(#batches()).toBe(0)
        fx.teardown()
    end)
end)

describe('console settings', function()
    it('keeps lines with the configured words in any letter case', function()
        boot(nil, nil, function(cfg) cfg.consoleWords = { 'timeout', 'a.b' } end)
        expect(kept('c', 'Request TIMEOUT after 5 s')).toBe(true)
        expect(kept('c', 'file a.b missing')).toBe(true)
        expect(kept('c', 'file axb missing')).toBe(false)
        expect(kept('c', 'Warning: slow')).toBe(false)
        expect(kept('c', 'SCRIPT ERROR: boom')).toBe(true)
        fx.teardown()
    end)

    it('uses the line limit, line length and stack window from the config', function()
        boot(nil, nil, function(cfg)
            cfg.consoleMaxLines, cfg.consoleMaxChars, cfg.consoleStackMs = 2, 10, 500
        end)
        for i = 1, 4 do listener('c', 'Warning ' .. i .. ' with a long tail') end
        fx.advance(1000)
        local lines = batches()[1].data.lines
        expect(#lines).toBe(2)
        expect(#lines[1].t).toBe(10)
        listener('c', 'SCRIPT ERROR: boom')
        fx.advance(1000)
        expect(kept('c', '  > late line')).toBe(false)
        fx.teardown()
    end)
end)

describe('console continuation', function()
    it('keeps stack lines for 2 seconds after a SCRIPT ERROR on the same channel', function()
        boot()
        listener('script:res', 'SCRIPT ERROR: @res/a.lua:3: boom')
        listener('script:res', '  > fn (@res/a.lua:3)')
        listener('script:res', 'stack traceback:')
        listener('script:res', '    at doThing (@res/a.lua:9)')
        listener('script:res', 'in function <res/a.lua:1>')
        listener('script:res', 'plain chatter')
        fx.advance(1000)
        local lines = batches()[1].data.lines
        expect(#lines).toBe(5)
        expect(lines[2].t).toBe('  > fn (@res/a.lua:3)')
        expect(lines[5].c).toBe('script:res')
        fx.teardown()
    end)

    it('drops stack lines on another channel, without an error, or after the window', function()
        boot()
        expect(kept('script:res', '  > fn (@res/a.lua:3)')).toBe(false)
        listener('script:res', 'SCRIPT ERROR: boom')
        fx.advance(1000)
        listener('other', '  > fn (@other/b.lua:1)')
        expect(kept('other', 'stack traceback:')).toBe(false)
        fx.advance(1500)
        expect(kept('script:res', '  > late line')).toBe(false)
        fx.teardown()
    end)
end)

describe('console flush', function()
    it('emits one console.lines event per flush with ts, channel and text', function()
        boot()
        local t0 = Atlas.now()
        listener('script:res', 'Warning: one')
        listener(nil, 'Warning: two')
        fx.advance(1000)
        local evs = batches()
        expect(#evs).toBe(1)
        local lines = evs[1].data.lines
        expect(#lines).toBe(2)
        expect(lines[1].c).toBe('script:res')
        expect(lines[2].c).toBe('')
        expect(lines[1].t).toBe('Warning: one')
        expect(lines[1].ts >= t0).toBe(true)
        fx.advance(3000)
        expect(#batches()).toBe(1)
        fx.teardown()
    end)

    it('truncates text to 1000 characters', function()
        boot()
        listener('c', 'Warning: ' .. string.rep('x', 2000))
        fx.advance(1000)
        expect(#batches()[1].data.lines[1].t).toBe(1000)
        fx.teardown()
    end)

    it('caps kept lines at 100 per flush and counts the rest as console_cap drops', function()
        boot()
        for i = 1, 130 do listener('c', 'Warning ' .. i) end
        fx.advance(1000)
        expect(#batches()[1].data.lines).toBe(100)
        expect(Atlas.drops.console_cap).toBe(30)
        for i = 1, 5 do listener('c', 'Warning again ' .. i) end
        fx.advance(1000)
        expect(#batches()[2].data.lines).toBe(5)
        fx.teardown()
    end)
end)

describe('console state', function()
    it('is on when the native registers a listener', function()
        boot()
        expect(Atlas.consoleState).toBe('on')
        expect(type(listener)).toBe('function')
        fx.teardown()
    end)

    it('is unsupported when the native is missing, and nothing else breaks', function()
        boot(nil, false)
        expect(Atlas.consoleState).toBe('unsupported')
        expect(#fx.printed('RegisterConsoleListener')).toBe(1)
        expect(Atlas.emit('probe', {})).toBe(1)
        fx.teardown()
    end)

    it('is unsupported when registering fails', function()
        boot(nil, function() error('no such native') end)
        expect(Atlas.consoleState).toBe('unsupported')
        fx.teardown()
    end)

    it('is off with atlas:console 0 and never registers', function()
        boot({ ['atlas:console'] = 0 })
        expect(Atlas.consoleState).toBe('off')
        expect(listener).toBeNil()
        expect(#fx.printed('RegisterConsoleListener')).toBe(0)
        fx.teardown()
    end)
end)
