local fx = load_module('tests/fivem.lua')

local function boot(resources, convars)
    convars = convars or {}
    convars['atlas:token'] = 'atl_live_x'
    fx.boot({
        convars = convars, resources = resources or {},
        load = { 'server/adapters/detect.lua', 'server/sources.lua', 'server/framework.lua' },
    })
end

local function framework(name, resource, over)
    local calls = { attach = 0, detach = 0 }
    local def = {
        name = name, resources = { resource },
        attach = function() calls.attach = calls.attach + 1 end,
        detach = function() calls.detach = calls.detach + 1 end,
    }
    for k, v in pairs(over or {}) do def[k] = v end
    Atlas.registerFramework(def)
    return def, calls
end

describe('framework registry', function()
    it('attaches the framework whose resource is installed and exposes its data readers', function()
        boot({ fw_a = 'started' })
        local readers = { money = { count = function() return 1 end } }
        Atlas.frameworkData.alpha = readers
        local def = framework('alpha', 'fw_a')
        fx.tick(); fx.tick()
        expect(Atlas.adapterActive('alpha')).toBe(true)
        expect(Atlas.framework).toBe(def)
        expect(Atlas.reader('money')).toBe(readers.money)
        expect(Atlas.reader('census')).toBeNil()
        fx.teardown()
    end)

    it('keeps the first framework and warns when a second one starts', function()
        boot({ fw_a = 'started', fw_b = 'started' })
        local _, a = framework('alpha', 'fw_a')
        local _, b = framework('beta', 'fw_b')
        fx.advance(200)
        expect(a.attach).toBe(1)
        expect(b.attach).toBe(0)
        expect(Atlas.adapterActive('beta')).toBe(false)
        expect(#fx.printed('alpha is the active framework, so beta is not used')).toBe(1)
        fx.teardown()
    end)

    it('follows the atlas:framework setting', function()
        boot({ fw_a = 'started', fw_b = 'started' }, { ['atlas:framework'] = 'BETA' })
        local _, a = framework('alpha', 'fw_a')
        local _, b = framework('beta', 'fw_b')
        fx.advance(200)
        expect(a.attach).toBe(0)
        expect(b.attach).toBe(1)
        fx.teardown()
    end)

    it('attaches no framework when the setting is none', function()
        boot({ fw_a = 'started' }, { ['atlas:framework'] = 'none' })
        local _, a = framework('alpha', 'fw_a')
        fx.advance(200)
        expect(a.attach).toBe(0)
        expect(Atlas.framework).toBeNil()
        fx.addPlayer(3, {})
        local p = Atlas.ensurePlayer(3)
        expect(Atlas.charFallback).toBe(true)
        expect(p.actor.char).toBe(p.account)
        fx.teardown()
    end)

    it('warns once about a framework name no adapter has', function()
        boot({ fw_a = 'started' }, { ['atlas:framework'] = 'qbcore' })
        framework('alpha', 'fw_a')
        fx.advance(200)
        fx.addPlayer(3, {})
        Atlas.ensurePlayer(3)
        fx.addPlayer(4, {})
        Atlas.ensurePlayer(4)
        expect(#fx.printed('atlas:framework is "qbcore", which is not supported (use auto, none or one of: alpha)')).toBe(1)
        expect(Atlas.framework).toBeNil()
        fx.teardown()
    end)

    it('hands the framework over when it stops and another is installed', function()
        boot({ fw_a = 'started', fw_b = 'started' })
        local _, a = framework('alpha', 'fw_a')
        local _, b = framework('beta', 'fw_b')
        fx.advance(200)
        fx.state.resources.fw_a = 'stopped'
        TriggerEvent('onResourceStop', 'fw_a')
        expect(a.detach).toBe(1)
        expect(Atlas.framework).toBeNil()
        TriggerEvent('onResourceStart', 'fw_b')
        fx.advance(200)
        expect(b.attach).toBe(1)
        expect(Atlas.framework.name).toBe('beta')
        fx.teardown()
    end)

    it('returns job and gang names from the groups reader, or nothing without one', function()
        boot({ fw_a = 'started' })
        expect(Atlas.groups()).toBeNil()
        Atlas.frameworkData.alpha = { groups = function() return { cop = true }, { crew = true } end }
        framework('alpha', 'fw_a')
        fx.advance(200)
        local jobs, gangs = Atlas.groups()
        expect(jobs.cop).toBe(true)
        expect(gangs.crew).toBe(true)
        fx.teardown()
    end)
end)

describe('character fallback', function()
    local function player(src)
        fx.addPlayer(src, { identifiers = { 'license2:abc' } })
        return Atlas.ensurePlayer(src)
    end

    it('uses the account id as the character when no framework is installed', function()
        boot()
        framework('alpha', 'fw_a')
        local p = player(3)
        expect(Atlas.charFallback).toBe(true)
        expect(p.actor.char).toBe(p.account)
        expect(Atlas.charOf(3)).toBe(p.account)
        fx.teardown()
    end)

    it('leaves the character empty while an installed framework has not loaded one', function()
        boot({ fw_a = 'started' })
        framework('alpha', 'fw_a')
        local p = player(3)
        expect(Atlas.charFallback).toBe(false)
        expect(p.actor.char).toBeNil()
        expect(Atlas.charOf(3)).toBeNil()
        fx.teardown()
    end)

    it('prefers the loaded character over the account id', function()
        boot()
        framework('alpha', 'fw_a')
        local p = player(3)
        Atlas.setChar(3, 'CHAR1', 'Ann')
        expect(p.actor.char).toBe('CHAR1')
        fx.teardown()
    end)

    it('turns off and rebuilds actors when a framework resource is added', function()
        boot()
        framework('alpha', 'fw_a')
        local p = player(3)
        expect(p.actor.char).toBe(p.account)
        fx.state.resources.fw_a = 'started'
        TriggerEvent('onResourceStart', 'fw_a')
        expect(Atlas.charFallback).toBe(false)
        expect(Atlas.players[3].actor.char).toBeNil()
        fx.teardown()
    end)

    it('stays on for a framework that is not selected', function()
        boot({ fw_a = 'started' }, { ['atlas:framework'] = 'other' })
        framework('alpha', 'fw_a')
        local p = player(3)
        expect(Atlas.charFallback).toBe(true)
        expect(p.actor.char).toBe(p.account)
        fx.teardown()
    end)
end)
