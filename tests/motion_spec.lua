local motion = load_module('server/lib/motion.lua')

local function s(x, y, h, vkey, bucket)
    return { x = x, y = y, z = 30.0, h = h or 0, vkey = vkey or 'foot', bucket = bucket or 0 }
end

describe('motion.decide', function()
    it('samples the first observation', function()
        local st = {}
        expect(motion.decide(st, s(0, 0), 1000)).toBe('sample')
        expect(st.last.t).toBe(1000)
    end)

    it('suppresses small moves and emits still at most every 30 s', function()
        local st = {}
        motion.decide(st, s(0, 0), 0)
        expect(motion.decide(st, s(0.5, 0), 3000)).toBe('skip')
        expect(st.stillSince).toBe(0)
        expect(motion.decide(st, s(0.2, 0.1, 10), 27000)).toBe('skip')
        expect(motion.decide(st, s(0.2, 0.1), 30000)).toBe('still')
        expect(motion.decide(st, s(0.2, 0.1), 33000)).toBe('skip')
        expect(motion.decide(st, s(0.2, 0.1), 60000)).toBe('still')
    end)

    it('samples again on movement, turning, vehicle or bucket change', function()
        local st = {}
        motion.decide(st, s(0, 0), 0)
        expect(motion.decide(st, s(1.5, 0), 3000)).toBe('sample')
        expect(st.stillSince).toBeNil()
        expect(motion.decide(st, s(1.5, 0, 25), 6000)).toBe('sample')
        expect(motion.decide(st, s(1.5, 0, 25, 'veh:driver'), 9000)).toBe('sample')
        expect(motion.decide(st, s(1.5, 0, 25, 'veh:driver', 5), 12000)).toBe('sample')
        expect(motion.decide(st, s(1.5, 0, 25, 'veh:driver', 5), 15000)).toBe('skip')
    end)

    it('treats heading wrap-around as a small turn', function()
        local st = {}
        motion.decide(st, s(0, 0, 355), 0)
        expect(motion.decide(st, s(0, 0, 5), 3000)).toBe('skip')
    end)

    it('finds players within the boost radius', function()
        local players = { { src = 1, x = 0, y = 0 }, { src = 2, x = 100, y = 100 }, { src = 3, x = 200, y = 0 } }
        expect(motion.within(players, 0, 0, 150)).toEqual({ 1, 2 })
        expect(motion.within(players, 0, 0, 141)).toEqual({ 1 })
        expect(motion.within({}, 0, 0, 150)).toEqual({})
    end)
end)

describe('motion.decide thresholds', function()
    it('samples at exactly 1 m and skips just under it', function()
        local st = {}
        motion.decide(st, s(0, 0), 0)
        expect(motion.decide(st, s(0.99, 0), 3000)).toBe('skip')
        expect(motion.decide(st, s(1.0, 0), 6000)).toBe('sample')
    end)

    it('counts vertical movement', function()
        local st = {}
        motion.decide(st, s(0, 0), 0)
        local up = s(0, 0); up.z = 31.5
        expect(motion.decide(st, up, 3000)).toBe('sample')
    end)

    it('samples at exactly 20 degrees and skips just under it', function()
        local st = {}
        motion.decide(st, s(0, 0, 0), 0)
        expect(motion.decide(st, s(0, 0, 19.9), 3000)).toBe('skip')
        expect(motion.decide(st, s(0, 0, 20), 6000)).toBe('sample')
    end)

    it('measures movement from the last sample, not the last observation', function()
        local st = {}
        motion.decide(st, s(0, 0), 0)
        expect(motion.decide(st, s(0.6, 0), 3000)).toBe('skip')
        expect(motion.decide(st, s(1.2, 0), 6000)).toBe('sample')
    end)

    it('reports the time the player stopped moving', function()
        local st = {}
        motion.decide(st, s(0, 0), 5000)
        motion.decide(st, s(0, 0), 8000)
        expect(st.stillSince).toBe(5000)
    end)

    it('restarts the 30 s still timer after movement', function()
        local st = {}
        motion.decide(st, s(0, 0), 0)
        expect(motion.decide(st, s(0, 0), 30000)).toBe('still')
        expect(motion.decide(st, s(10, 0), 33000)).toBe('sample')
        expect(motion.decide(st, s(10, 0), 60000)).toBe('skip')
        expect(motion.decide(st, s(10, 0), 63000)).toBe('still')
    end)

    it('follows the rules it is given', function()
        local rules = { moveMeters = 5.0, turnDegrees = 90, stillEveryMs = 10000 }
        local st = {}
        motion.decide(st, s(0, 0), 0, rules)
        expect(motion.decide(st, s(4.0, 0), 3000, rules)).toBe('skip')
        expect(motion.decide(st, s(5.0, 0), 6000, rules)).toBe('sample')
        expect(motion.decide(st, s(5.0, 0, 80), 9000, rules)).toBe('skip')
        expect(motion.decide(st, s(5.0, 0), 16000, rules)).toBe('still')
    end)

    it('builds a vehicle key from model and seat', function()
        expect(motion.vehicleKey(nil, nil)).toBe('foot')
        expect(motion.vehicleKey(123, 'driver')).toBe('123:driver')
        expect(motion.vehicleKey(123, 'passenger') ~= motion.vehicleKey(123, 'driver')).toBe(true)
    end)
end)
