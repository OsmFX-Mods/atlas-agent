-- Clock: UTC time in milliseconds, built from os.time (seconds) and GetGameTimer (ms), both passed in.
-- Anchor: set when os.time moves to a new second and reset now and then; now() never goes back.

AtlasLib = AtlasLib or {}
local M = {}

--- @param osTime fun(): integer   seconds since 1970 (UTC)
--- @param gameTimer fun(): integer milliseconds that only go up
function M.new(osTime, gameTimer)
    local c = {
        osTime = osTime,
        gameTimer = gameTimer,
        baseMs = osTime() * 1000,
        baseGt = gameTimer(),
        calibrated = false,
        lastSec = osTime(),
        last = 0,
        -- seeking: true while waiting for the next whole second
        seeking = true,
    }

    --- Now: current UTC time in ms; never goes back.
    function c.now()
        local ms = c.baseMs + (c.gameTimer() - c.baseGt)
        if ms < c.last then ms = c.last end
        c.last = ms
        return ms
    end

    --- Step: call each tick while seeking; returns true once the clock is lined up.
    function c.step()
        local s = c.osTime()
        if s ~= c.lastSec then
            c.lastSec = s
            if c.seeking then
                c.baseMs = s * 1000
                c.baseGt = c.gameTimer()
                c.calibrated = true
                c.seeking = false
                return true
            end
        end
        return false
    end

    --- Recalibrate: starts waiting for the next whole second to line the clock up again.
    function c.recalibrate()
        c.lastSec = c.osTime()
        c.seeking = true
    end

    return c
end

AtlasLib.clock = M
return M
