local fx = load_module('tests/fivem.lua')

local function boot()
    fx.boot({ convars = { ['atlas:token'] = 'atl_live_x' }, load = { 'server/db.lua', 'server/commands.lua' } })
    fx.tick()
end

describe('atlas_bench', function()
    it('prints a report for a fractional uptime', function()
        boot()
        fx.advance(1500)
        fx.state.commands.atlas_bench(0, {})
        expect(#fx.printed('atlas_bench (uptime')).toBe(1)
        expect(#fx.printed('drops     : none')).toBe(1)
        fx.teardown()
    end)

    it('runs the synthetic emit benchmark when given a count', function()
        boot()
        fx.addPlayer(1, {})
        Atlas.ensurePlayer(1)
        fx.advance(2300)
        fx.state.commands.atlas_bench(0, { '200' })
        expect(#fx.printed('synthetic : 200 emits')).toBe(1)
        fx.teardown()
    end)
end)

describe('atlas_selftest', function()
    it('reports each check and finishes', function()
        boot()
        fx.state.commands.atlas_selftest(0, {})
        fx.advance(6000)
        expect(#fx.printed('token set')).toBe(1)
        expect(#fx.printed('oxmysql not started')).toBe(1)
        expect(#fx.printed('--- atlas_selftest ---')).toBe(1)
        fx.advance(16000)
        expect(#fx.printed('Atlas confirmed a test event')).toBe(1)
        expect(#fx.printed('--- done ---')).toBe(1)
        fx.teardown()
    end)
end)

describe('atlas_selftest adapters and framework', function()
    local function bootAdapters(resources, convars)
        convars = convars or {}
        convars['atlas:token'] = 'atl_live_x'
        fx.boot({
            convars = convars, resources = resources,
            load = { 'server/db.lua', 'server/adapters/detect.lua', 'server/sources.lua', 'server/framework.lua', 'server/commands.lua' },
        })
    end

    local function run(...)
        fx.state.commands.atlas_selftest(0, { ... })
        fx.advance(22000)
    end

    it('lists every adapter as attached or skipped with the reason', function()
        bootAdapters({ fw_a = 'started', other = 'stopped' })
        Atlas.registerFramework({ name = 'alpha', resources = { 'fw_a' }, attach = function() end })
        Atlas.registerAdapter({ name = 'extra', resources = { 'other' }, attach = function() end })
        fx.advance(200)
        run()
        expect(#fx.printed('adapter alpha attached')).toBe(1)
        expect(#fx.printed('adapter extra skipped (other is stopped)')).toBe(1)
        expect(#fx.printed('no framework attached')).toBe(0)
        fx.teardown()
    end)

    it('says why a framework that is not selected is skipped', function()
        bootAdapters({ fw_a = 'started' }, { ['atlas:framework'] = 'beta' })
        Atlas.registerFramework({ name = 'alpha', resources = { 'fw_a' }, attach = function() end })
        fx.advance(200)
        run()
        expect(#fx.printed('adapter alpha skipped (atlas:framework is beta)')).toBe(1)
        expect(#fx.printed('no framework attached')).toBe(1)
        fx.teardown()
    end)

    it('says which framework is active when a second one is installed', function()
        bootAdapters({ fw_a = 'started', fw_b = 'started' })
        Atlas.registerFramework({ name = 'alpha', resources = { 'fw_a' }, attach = function() end })
        Atlas.registerFramework({ name = 'beta', resources = { 'fw_b' }, attach = function() end })
        fx.advance(200)
        run()
        expect(#fx.printed('adapter beta skipped (alpha is the active framework)')).toBe(1)
        fx.teardown()
    end)

    it('checks the framework money hook for the given player', function()
        bootAdapters({ fw_a = 'started' })
        local called
        Atlas.registerFramework({
            name = 'alpha', resources = { 'fw_a' }, attach = function() end,
            selftestMoney = function(src) called = src; Atlas.selftestMoneySeen = true; return true end,
        })
        fx.advance(200)
        run('7')
        expect(called).toBe(7)
        expect(#fx.printed('alpha money hook fires (player 7)')).toBe(1)
        fx.teardown()
    end)

    it('fails the money check when the hook never fires', function()
        bootAdapters({ fw_a = 'started' })
        Atlas.registerFramework({ name = 'alpha', resources = { 'fw_a' }, attach = function() end, selftestMoney = function() return true end })
        fx.advance(200)
        run('7')
        local line = fx.printed('alpha money hook fires')[1]
        expect(line:find('FAIL', 1, true) ~= nil).toBe(true)
        fx.teardown()
    end)
end)
