local common = load_module('server/lib/common.lua')

describe('common', function()
    it('rounds positions to 0.1 m', function()
        expect(common.pos(1.26, -3.24, 30.05)).toEqual({ 1.3, -3.2, 30.1 })
        expect(common.round1(-212.44)).toBeNear(-212.4, 1e-9)
    end)

    it('computes heading differences across 0/360', function()
        expect(common.headingDiff(350, 10)).toBe(20)
        expect(common.headingDiff(10, 350)).toBe(20)
        expect(common.headingDiff(0, 180)).toBe(180)
    end)

    it('normalises signed hashes to u32', function()
        expect(common.u32(-1)).toBe(4294967295)
        expect(common.u32(-1569615261)).toBe(2725352035) -- Case: WEAPON_UNARMED
        expect(common.u32(2725352035)).toBe(2725352035)
        expect(common.u32('x')).toBeNil()
    end)

    it('spreads sampling across 50 ms slices', function()
        expect(common.perSlice(40, 3000, 50)).toBe(1)   -- Case: 40 / 60 rounds up to 1
        expect(common.perSlice(128, 3000, 50)).toBe(3)  -- Case: 128 / 60 rounds up to 3
        expect(common.perSlice(0, 3000, 50)).toBe(0)
        expect(common.perSlice(10, 20, 50)).toBe(10)    -- Case: sample_ms below one slice
    end)

    it('builds 26-char sortable ULIDs', function()
        local seq = 0
        local rand = function() seq = seq + 1; return seq % 32 end
        local a = common.ulid(1790000000000, rand)
        local b = common.ulid(1790000000001, rand)
        expect(#a).toBe(26)
        expect(a:match('^[0-9A-HJKMNP-TV-Z]+$') ~= nil).toBe(true)
        expect(a:sub(1, 10) < b:sub(1, 10)).toBe(true)
        -- Time prefix: known value from the ULID spec (1469918176385 -> 01ARYZ6S41)
        expect(common.ulid(1469918176385, rand):sub(1, 10)).toBe('01ARYZ6S41')
    end)

    it('picks identifiers without IPs and the preferred account', function()
        local ids, account = common.pickIdentifiers({ 'ip:1.2.3.4', 'license:aaa', 'license2:bbb', 'discord:1', 'fivem:9' })
        expect(ids.ip).toBeNil()
        expect(ids.license).toBe('license:aaa')
        expect(account).toBe('license2:bbb')
        local _, acc2 = common.pickIdentifiers({ 'discord:1', 'fivem:9' })
        expect(acc2).toBe('fivem:9')
    end)

    it('classifies bank accounts', function()
        local jobs, gangs = { police = true }, { ballas = true }
        expect(common.accountKind('police', nil, jobs, gangs)).toBe('job')
        expect(common.accountKind('ballas', nil, jobs, gangs)).toBe('gang')
        expect(common.accountKind('myshared', 'ABC123', jobs, gangs)).toBe('shared')
        expect(common.accountKind('burgershot', nil, jobs, gangs)).toBe('business')
    end)

    it('summarises chat without content by default', function()
        local d = common.chatSummary('/me waves hello', false)
        expect(d.len).toBe(15)
        expect(d.command).toBe('/me')
        expect(d.text).toBeNil()
        expect(common.chatSummary('hi', true).text).toBe('hi')
        expect(common.chatSummary(nil, true)).toBeNil()
    end)

    it('hashes with FNV-1a', function()
        expect(common.fnv1a('')).toBe(0x811C9DC5)
        expect(common.fnv1a('a')).toBe(0xE40C292C)
    end)

    it('measures planar and spatial distance', function()
        expect(common.dist2(0, 0, 3, 4)).toBe(5)
        expect(common.dist3(0, 0, 0, 2, 3, 6)).toBe(7)
    end)

    it('wraps heading differences past 360 and for negative headings', function()
        expect(common.headingDiff(-10, 10)).toBe(20)
        expect(common.headingDiff(370, 10)).toBe(0)
    end)

    it('keeps only known identifier prefixes and skips malformed entries', function()
        local ids = common.pickIdentifiers({ 'license:a', 'live:b', 'xbl:c', 'steam:d', 'tokenx:e', 'noprefix', 42 })
        expect(ids.license).toBe('license:a')
        expect(ids.live).toBe('live:b')
        expect(ids.xbl).toBe('xbl:c')
        expect(ids.steam).toBe('steam:d')
        expect(ids.tokenx).toBeNil()
        local _, account = common.pickIdentifiers({ 'steam:d' })
        expect(account).toBeNil()
    end)

    it('treats an empty creator as a business account', function()
        expect(common.accountKind('shop', '', {}, {})).toBe('business')
        expect(common.accountKind('shop', nil, nil, nil)).toBe('business')
    end)

    it('lowercases and truncates the chat command and caps captured text', function()
        local d = common.chatSummary('/ME ' .. string.rep('x', 600), true)
        expect(d.command).toBe('/me')
        expect(#d.text).toBe(512)
        expect(common.chatSummary('/' .. string.rep('a', 50), false).command).toBe('/' .. string.rep('a', 32))
        expect(common.chatSummary('no command', false).command).toBeNil()
    end)

    it('floors fractional hashes before converting to u32', function()
        expect(common.u32(5.9)).toBe(5)
    end)

    it('sanitises script data down to plain values', function()
        local deep = { a = { b = { c = { d = { e = 1 } } } } }
        local clean = common.sanitize({
            n = 5, s = 'x', b = true, bad = 0 / 0, inf = math.huge, fn = function() end, thread = coroutine.create(print),
            list = { 1, 2, 3 }, nested = deep, [true] = 'key', long = string.rep('z', 2000),
        })
        expect(clean.n).toBe(5)
        expect(clean.s).toBe('x')
        expect(clean.b).toBe(true)
        expect(clean.bad).toBeNil()
        expect(clean.inf).toBeNil()
        expect(clean.fn).toBeNil()
        expect(clean.thread).toBeNil()
        expect(clean.list).toEqual({ 1, 2, 3 })
        expect(#clean.long).toBe(1024)
        expect(clean.nested.a.b).toEqual({})
        expect(clean[true]).toBeNil()
    end)

    it('sanitises cyclic tables and caps the key count', function()
        local loop = {}
        loop.self = loop
        local clean = common.sanitize(loop)
        expect(clean.self.self.self.self).toBeNil()
        local many = {}
        for i = 1, 200 do many['k' .. i] = i end
        local count = 0
        for _ in pairs(common.sanitize(many)) do count = count + 1 end
        expect(count).toBe(64)
        expect(common.sanitize(function() end)).toBeNil()
        expect(common.sanitize(nil)).toBeNil()
    end)
end)
