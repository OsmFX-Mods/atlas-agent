local fx = load_module('tests/fivem.lua')

local function boot(resources, files)
    fx.boot({
        convars = { ['atlas:token'] = 'atl_live_x' }, resources = resources or {}, files = files or {},
        load = { 'server/sources.lua' },
    })
end

describe('sources', function()
    it('lists a source only while every resource it needs is started', function()
        boot({ res_a = 'started', res_b = 'stopped' })
        Atlas.registerSource('places', { name = 'one', resources = { 'res_a' } })
        Atlas.registerSource('places', { name = 'two', resources = { 'res_a', 'res_b' } })
        Atlas.registerSource('prices', { name = 'other', resources = { 'res_a' } })
        local names = {}
        for _, def in ipairs(Atlas.sources('places')) do names[#names + 1] = def.name end
        expect(names).toEqual({ 'one' })
        fx.state.resources.res_b = 'started'
        expect(#Atlas.sources('places')).toBe(2)
        expect(#Atlas.sources('nothing')).toBe(0)
        fx.teardown()
    end)

    it('returns the resources of one kind as a set', function()
        boot()
        Atlas.registerSource('places', { name = 'one', resources = { 'res_a', 'res_b' } })
        Atlas.registerSource('prices', { name = 'two', resources = { 'res_c' } })
        expect(Atlas.sourceResources('places')).toEqual({ res_a = true, res_b = true })
        expect(Atlas.sourceResources('none')).toEqual({})
        fx.teardown()
    end)

    it('joins the rows of every active account source and fails as a whole when one fails', function()
        boot({ res_a = 'started', res_b = 'started' })
        Atlas.registerSource('accounts', { name = 'a', resources = { 'res_a' }, read = function() return { { 'x', 'job', 1 } } end })
        Atlas.registerSource('accounts', { name = 'b', resources = { 'res_b' }, read = function() return { { 'y', 'business', 2 } } end })
        expect(Atlas.accountsRows()).toEqual({ { 'x', 'job', 1 }, { 'y', 'business', 2 } })
        Atlas.registerSource('accounts', { name = 'c', resources = { 'res_a' }, read = function() return nil, 'db down' end })
        local rows, err = Atlas.accountsRows()
        expect(rows).toBeNil()
        expect(err).toBe('db down')
        fx.teardown()
    end)

    it('reports no account source when none is started', function()
        boot()
        local rows, err = Atlas.accountsRows()
        expect(rows).toBeNil()
        expect(err).toBe('no account source started')
        fx.teardown()
    end)

    it('runs a config file in the sandbox and passes the globals it needs', function()
        boot({ res = 'started' }, { ['res/cfg.lua'] = 'Config = Config or {}\nConfig.Zones = { a = vec3(1.0, 2.0, 3.0) }\nreturn 5' })
        local seed = {}
        local result, env = Atlas.loadConfig('res', 'cfg.lua', { Config = seed })
        expect(result).toBe(5)
        expect(seed.Zones.a.x).toBe(1.0)
        expect(rawget(env, 'Config')).toBe(seed)
        expect(Atlas.loadConfig('res', 'missing.lua')).toBeNil()
        expect(Atlas.loadConfig('absent', 'cfg.lua')).toBeNil()
        fx.teardown()
    end)

    it('does not leak state between config files that touch an unknown global', function()
        boot({ res = 'started' }, { ['res/a.lua'] = 'Config = Config or {}\nConfig.Leak = 1' })
        Atlas.loadConfig('res', 'a.lua')
        local _, env = Atlas.loadConfig('res', 'a.lua')
        expect(type(rawget(env, 'Config'))).toBe('table')
        expect(rawget(AtlasLib.sandbox.hole, 'Leak')).toBeNil()
        fx.teardown()
    end)
end)
