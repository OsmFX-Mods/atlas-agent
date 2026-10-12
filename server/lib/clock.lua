-- Clock: millisecond UTC timestamps from os.time (whole seconds) and GetGameTimer (monotonic ms); pure, sources injected.
-- Anchor: taken when os.time ticks to a new second, retaken periodically for drift and NTP; now() never goes backwards.

AtlasLib = AtlasLib or {}
local M = {}

--- @param osTime fun(): integer   seconds since epoch (UTC)
--- @param gameTimer fun(): integer monotonic ms
function M.new(osTime, gameTimer)
    local c = {
        osTime = osTime,
        gameTimer = gameTimer,
        baseMs = osTime() * 1000,
        baseGt = gameTimer(),
        calibrated = false,
        lastSec = osTime(),
        last = 0,
        -- seeking: true while looking for the next second edge
        seeking = true,
    }

    --- Now: current UTC time in ms, integer and non-decreasing.
    function c.now()
        local ms = c.baseMs + (c.gameTimer() - c.baseGt)
        if ms < c.last then ms = c.last end
        c.last = ms
        return ms
    end

    --- Step: call once per tick while seeking; returns true when this call took an anchor.
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

    --- Recalibrate: starts looking for a new second edge for periodic re-anchoring.
    function c.recalibrate()
        c.lastSec = c.osTime()
        c.seeking = true
    end

    return c
end

AtlasLib.clock = M
return M
