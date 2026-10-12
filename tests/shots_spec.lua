local shots = load_module('server/lib/shots.lua')

local PISTOL = 453432689

local function ctx(over)
    local c = { alive = true, positions = { { 100.0, 100.0 } }, weapons = { [PISTOL] = true } }
    for k, v in pairs(over or {}) do c[k] = v end
    return c
end

local function report(cells, weapon)
    return { window_s = 15, reports = { { weapon = weapon or PISTOL, cells = cells } } }
end

describe('shots.validate', function()
    it('accepts a plausible report', function()
        local cx, cy = shots.cell(100.0, 100.0)
        local ok, reason, clean = shots.validate(report({ { cx, cy, 12 } }), ctx())
        expect(ok).toBe(true)
        expect(reason).toBeNil()
        expect(clean.reports[1].total).toBe(12)
        expect(clean.window_s).toBe(15)
    end)

    it('normalises signed weapon hashes', function()
        local signed = -1569615261
        local ok, _, clean = shots.validate(report({ { 4, 4, 1 } }, signed), ctx({ weapons = { [2725352035] = true } }))
        expect(ok).toBe(true)
        expect(clean.reports[1].weapon).toBe(2725352035)
    end)

    it('rejects malformed payloads', function()
        expect(select(2, shots.validate(nil, ctx()))).toBe('malformed')
        expect(select(2, shots.validate({ window_s = 15, reports = {} }, ctx()))).toBe('malformed')
        expect(select(2, shots.validate(report({ { 4, 4, 1.5 } }), ctx()))).toBe('malformed')
        expect(select(2, shots.validate(report({ { 4, 'x', 1 } }), ctx()))).toBe('malformed')
        expect(select(2, shots.validate({ window_s = 600, reports = { { weapon = PISTOL, cells = { { 4, 4, 1 } } } } }, ctx()))).toBe('malformed')
    end)

    it('rejects implausible volume', function()
        expect(select(2, shots.validate(report({ { 4, 4, 400 }, { 4, 3, 400 } }), ctx()))).toBe('volume')
    end)

    it('rejects dead players', function()
        expect(select(2, shots.validate(report({ { 4, 4, 1 } }), ctx({ alive = false })))).toBe('dead')
    end)

    it('rejects cells far from server-known positions', function()
        expect(select(2, shots.validate(report({ { 40, 40, 1 } }), ctx()))).toBe('position')
        expect(select(2, shots.validate(report({ { 4, 4, 1 } }), ctx({ positions = {} })))).toBe('position')
    end)

    it('rejects weapons the server never saw', function()
        expect(select(2, shots.validate(report({ { 4, 4, 1 } }, 12345), ctx()))).toBe('weapon')
    end)
end)

describe('shots.validate limits', function()
    local function reason(payload, c) return select(2, shots.validate(payload, c or ctx())) end
    local function at(x, y) return ctx({ positions = { { x, y } } }) end

    it('accepts a cell 75 m away and rejects one 100 m away', function()
        expect(reason(report({ { 3, 0, 1 } }), at(12.5, 12.5))).toBeNil()
        expect(reason(report({ { 4, 0, 1 } }), at(12.5, 12.5))).toBe('position')
        expect(reason(report({ { 3, 3, 1 } }), at(12.5, 12.5))).toBe('position')
    end)

    it('accepts any one of several known positions', function()
        local c = ctx({ positions = { { 5000.0, 5000.0 }, { 12.5, 12.5 } } })
        expect(reason(report({ { 0, 0, 1 } }), c)).toBeNil()
    end)

    it('allows 600 shots in total and rejects 601 as volume', function()
        expect(reason(report({ { 4, 4, 300 }, { 4, 3, 300 } }))).toBeNil()
        expect(reason(report({ { 4, 4, 300 }, { 4, 3, 301 } }))).toBe('volume')
        expect(reason(report({ { 4, 4, 601 } }))).toBe('malformed')
    end)

    it('allows 64 cells and eight weapons, rejects one more', function()
        local function cells(n)
            local out = {}
            for i = 1, n do out[i] = { 4, 4, 1 } end
            return out
        end
        expect(reason(report(cells(64)))).toBeNil()
        expect(reason(report(cells(65)))).toBe('malformed')
        local function weapons(n)
            local reports = {}
            for i = 1, n do reports[i] = { weapon = PISTOL, cells = { { 4, 4, 1 } } } end
            return { window_s = 15, reports = reports }
        end
        expect(reason(weapons(8))).toBeNil()
        expect(reason(weapons(9))).toBe('malformed')
    end)

    it('allows a window of 1 to 60 seconds and nothing else', function()
        local function window(w) return { window_s = w, reports = { { weapon = PISTOL, cells = { { 4, 4, 1 } } } } } end
        expect(reason(window(1))).toBeNil()
        expect(reason(window(60))).toBeNil()
        expect(reason(window(61))).toBe('malformed')
        expect(reason(window(0))).toBe('malformed')
        expect(reason(window(1.5))).toBe('malformed')
        expect(reason(window('15'))).toBe('malformed')
    end)

    it('rejects zero, negative, fractional and NaN counts and out-of-range cells', function()
        expect(reason(report({ { 4, 4, 0 } }))).toBe('malformed')
        expect(reason(report({ { 4, 4, -3 } }))).toBe('malformed')
        expect(reason(report({ { 4, 4, 0 / 0 } }))).toBe('malformed')
        expect(reason(report({ { 401, 4, 1 } }))).toBe('malformed')
        expect(reason(report({ { 4, -401, 1 } }))).toBe('malformed')
    end)

    it('rejects non-integer and out-of-range weapon hashes', function()
        expect(reason(report({ { 4, 4, 1 } }, 1.5))).toBe('malformed')
        expect(reason(report({ { 4, 4, 1 } }, 4294967296))).toBe('malformed')
        expect(reason(report({ { 4, 4, 1 } }, -2147483649))).toBe('malformed')
    end)

    it('checks dead before position and position before weapon', function()
        local far = report({ { 40, 40, 1 } }, 12345)
        expect(reason(far, ctx({ alive = false }))).toBe('dead')
        expect(reason(far)).toBe('position')
    end)

    it('does not modify the payload it was given', function()
        local payload = report({ { 4, 4, 2 } })
        shots.validate(payload, ctx())
        expect(payload.reports[1].total).toBeNil()
        expect(payload.reports[1].cells[1][3]).toBe(2)
    end)
end)
