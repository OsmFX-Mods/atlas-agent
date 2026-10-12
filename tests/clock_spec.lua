local clockLib = load_module('server/lib/clock.lua')

describe('clock', function()
    it('anchors to the second edge for ms precision', function()
        -- Start: the wall clock is really at 100.700 s when the agent starts
        local wallMs = 100700
        local gt = 5000
        local osTime = function() return wallMs // 1000 end
        local gameTimer = function() return gt end
        local c = clockLib.new(osTime, gameTimer)
        -- Before calibration: the error stays under 1 s, since it assumes 100.000
        expect(c.now()).toBe(100000)
        -- Edge: ticks pass and os.time flips at 101.004
        for _ = 1, 10 do
            wallMs = wallMs + 33; gt = gt + 33
            c.step()
        end
        expect(c.calibrated).toBe(true)
        -- Accuracy: now tracks the wall clock within one 33 ms tick
        wallMs = wallMs + 500; gt = gt + 500
        expect(math.abs(c.now() - wallMs) <= 33).toBe(true)
    end)

    it('never goes backwards on re-anchoring', function()
        local wall, gt = 200000, 0
        local c = clockLib.new(function() return wall // 1000 end, function() return gt end)
        gt = 900
        local before = c.now() -- Expected: 200900
        -- Re-anchor: the wall clock stepped back (NTP)
        wall = 199500
        c.recalibrate()
        for _ = 1, 40 do wall = wall + 20; gt = gt + 20; c.step() end
        expect(c.now() >= before).toBe(true)
    end)

    it('stays uncalibrated until the second flips and then stops seeking', function()
        local wall, gt = 100000, 0
        local c = clockLib.new(function() return wall // 1000 end, function() return gt end)
        c.step(); c.step()
        expect(c.calibrated).toBe(false)
        expect(c.seeking).toBe(true)
        wall, gt = 101000, 700
        expect(c.step()).toBe(true)
        expect(c.calibrated).toBe(true)
        expect(c.seeking).toBe(false)
        expect(c.now()).toBe(101000)
        expect(c.step()).toBe(false)
    end)

    it('starts seeking again on recalibrate', function()
        local c = clockLib.new(function() return 100 end, function() return 0 end)
        c.seeking = false
        c.recalibrate()
        expect(c.seeking).toBe(true)
    end)
end)
