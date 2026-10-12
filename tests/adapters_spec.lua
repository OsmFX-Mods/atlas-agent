local fx = load_module('tests/fivem.lua')

local function boot(resources)
    fx.boot({
        convars = { ['atlas:token'] = 'atl_live_x' }, resources = resources or {},
        load = { 'server/adapters/detect.lua' },
    })
end

local function adapter(over)
    local calls = { attach = 0, detach = 0 }
    local def = {
        name = 'demo',
        resources = { 'res_a', 'res_b' },
        attach = function() calls.attach = calls.attach + 1 end,
        detach = function() calls.detach = calls.detach + 1 end,
    }
    for k, v in pairs(over or {}) do def[k] = v end
    return def, calls
end

describe('adapter registry', function()
    it('attaches on the first tick once every resource is started', function()
        boot({ res_a = 'started', res_b = 'started' })
        local def, calls = adapter()
        Atlas.registerAdapter(def)
        fx.tick(); fx.tick()
        expect(calls.attach).toBe(1)
        expect(Atlas.adapterActive('demo')).toBe(true)
        expect(Atlas.adapters.demo).toBe(true)
        fx.teardown()
    end)

    it('waits for a missing resource and attaches when it starts, in any order', function()
        boot({ res_a = 'started' })
        local def, calls = adapter()
        Atlas.registerAdapter(def)
        fx.tick(); fx.tick()
        expect(calls.attach).toBe(0)
        fx.state.resources.res_b = 'started'
        TriggerEvent('onResourceStart', 'res_b')
        fx.tick()
        expect(calls.attach).toBe(1)
        expect(Atlas.adapterActive('demo')).toBe(true)
        fx.teardown()
    end)

    it('detaches when a resource stops and clears the flag', function()
        boot({ res_a = 'started', res_b = 'started' })
        local def, calls = adapter()
        Atlas.registerAdapter(def)
        fx.tick(); fx.tick()
        fx.state.resources.res_b = 'stopped'
        TriggerEvent('onResourceStop', 'res_b')
        expect(calls.detach).toBe(1)
        expect(Atlas.adapterActive('demo')).toBe(false)
        expect(Atlas.adapters.demo).toBeNil()
        fx.teardown()
    end)

    it('re-attaches after a restart because the dependency lost our hooks', function()
        boot({ res_a = 'started', res_b = 'started' })
        local def, calls = adapter()
        Atlas.registerAdapter(def)
        fx.tick(); fx.tick()
        TriggerEvent('onResourceStart', 'res_a')
        fx.tick()
        expect(calls.detach).toBe(1)
        expect(calls.attach).toBe(2)
        expect(Atlas.adapterActive('demo')).toBe(true)
        fx.teardown()
    end)

    it('ignores start and stop events of unrelated resources', function()
        boot({ res_a = 'started', res_b = 'started' })
        local def, calls = adapter()
        Atlas.registerAdapter(def)
        fx.tick(); fx.tick()
        TriggerEvent('onResourceStart', 'other')
        TriggerEvent('onResourceStop', 'other')
        expect(calls.attach).toBe(1)
        expect(calls.detach).toBe(0)
        fx.teardown()
    end)

    it('retries a failing attach every second and succeeds once the resource is ready', function()
        boot({ res_a = 'started', res_b = 'started' })
        local tries = 0
        local def = adapter({ attach = function()
            tries = tries + 1
            if tries < 4 then error('not ready') end
        end })
        Atlas.registerAdapter(def)
        fx.tick()
        fx.advance(5000, 1000)
        expect(tries).toBe(4)
        expect(Atlas.adapterActive('demo')).toBe(true)
        fx.teardown()
    end)

    it('lets a newer attach replace a retry loop that is still running', function()
        boot({ res_a = 'started', res_b = 'started' })
        local successes, ready = 0, false
        local def = adapter({ attach = function()
            if not ready then error('not ready') end
            successes = successes + 1
        end })
        Atlas.registerAdapter(def)
        fx.tick(); fx.tick()
        TriggerEvent('onResourceStart', 'res_a')
        fx.tick()
        ready = true
        fx.advance(8000, 1000)
        expect(successes).toBe(1)
        expect(Atlas.adapterActive('demo')).toBe(true)
        fx.teardown()
    end)

    it('gives up after 30 attempts, warns and counts the failure', function()
        boot({ res_a = 'started', res_b = 'started' })
        local tries = 0
        local def = adapter({ attach = function() tries = tries + 1; error('never ready') end })
        Atlas.registerAdapter(def)
        fx.tick()
        fx.advance(40000, 1000)
        expect(tries).toBe(30)
        expect(Atlas.adapterActive('demo')).toBe(false)
        expect(Atlas.drops.adapter_attach_failed).toBe(1)
        expect(#fx.printed('failed to attach')).toBe(1)
        fx.teardown()
    end)

    it('stops retrying when the resource goes away mid-retry', function()
        boot({ res_a = 'started', res_b = 'started' })
        local tries = 0
        local def = adapter({ attach = function() tries = tries + 1; error('not ready') end })
        Atlas.registerAdapter(def)
        fx.tick()
        fx.advance(2000, 1000)
        fx.state.resources.res_b = 'stopped'
        fx.advance(5000, 1000)
        expect(tries <= 3).toBe(true)
        expect(Atlas.adapterActive('demo')).toBe(false)
        fx.teardown()
    end)
end)
