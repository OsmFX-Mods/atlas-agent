local sandbox = load_module('server/lib/sandbox.lua')

describe('sandbox.load', function()
    it('evaluates a data file that returns a table', function()
        local res = sandbox.load([[
            return {
                General = { name = 'Shop', locations = { vec3(25.7, -1347.3, 29.49) }, inventory = { { name = 'water', price = 10 } } },
            }
        ]], 'shops.lua')
        expect(res.General.name).toBe('Shop')
        local x, y = sandbox.xyz(res.General.locations[1])
        expect(x).toBe(25.7)
        expect(y).toBe(-1347.3)
    end)

    it('captures globals and tolerates unknown helpers', function()
        local res, env = sandbox.load([[
            lib.locale()
            Config = { peds = { { coords = vector4(1.0, 2.0, 3.0, 90.0), label = locale('bank') } } }
        ]], 'config.lua')
        expect(res).toBeNil()
        local cfg = rawget(env, 'Config')
        expect(#cfg.peds).toBe(1)
        expect(sandbox.xyz(cfg.peds[1].coords)).toBe(1.0)
        expect(type(cfg.peds[1].label)).toBe('table') -- Inert value: callers can type-check it
    end)

    it('reports syntax and runtime errors instead of throwing', function()
        local r1, _, e1 = sandbox.load('return {', 'bad.lua')
        expect(r1).toBeNil()
        expect(e1 ~= nil).toBe(true)
        local r2, _, e2 = sandbox.load('return 1 + {}', 'bad2.lua')
        expect(r2).toBeNil()
        expect(e2 ~= nil).toBe(true)
    end)

    it('cannot reach real globals', function()
        -- Globals: os and io both resolve to the same inert value, not the real libraries
        local res = sandbox.load('return os == io and os.exit == io.open', 'escape.lua')
        expect(res).toBe(true)
    end)

    it('xyz rejects non-vectors', function()
        expect(sandbox.xyz(nil)).toBeNil()
        expect(sandbox.xyz('x')).toBeNil()
        expect(sandbox.xyz(sandbox.hole)).toBeNil()
    end)

    it('cannot change the real standard libraries', function()
        local before = string.format
        sandbox.load('string.format = nil; math.floor = nil; table.insert = nil', 'tamper.lua')
        expect(string.format).toBe(before)
        expect(math.floor ~= nil).toBe(true)
        expect(table.insert ~= nil).toBe(true)
    end)

    it('aborts a config that never returns', function()
        local res, env, err = sandbox.load('while lib.ready() do end return {}', 'loop.lua')
        expect(res).toBeNil()
        expect(env).toBeNil()
        expect(tostring(err):find('ran too long', 1, true) ~= nil).toBe(true)
        local ok = sandbox.load('return { fine = true }', 'after.lua')
        expect(ok.fine).toBe(true)
    end)
end)

describe('sandbox.items', function()
    local function collect(t)
        local out = {}
        for i, v in sandbox.items(t) do out[#out + 1] = { i, v } end
        return out
    end

    it('walks the array part in order', function()
        local got = collect({ 'a', 'b', 'c' })
        expect(#got).toBe(3)
        expect(got[3][2]).toBe('c')
    end)

    it('yields nothing for the inert value, which would make ipairs run forever', function()
        local _, env = sandbox.load('Config = { shops = lib.missing }', 'config.lua')
        expect(#collect(rawget(env, 'Config').shops)).toBe(0)
        expect(#collect(sandbox.hole)).toBe(0)
    end)

    it('yields nothing for non-tables', function()
        expect(#collect(nil)).toBe(0)
        expect(#collect('text')).toBe(0)
    end)
end)
