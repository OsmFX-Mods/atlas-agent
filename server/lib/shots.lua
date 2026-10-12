-- Shots: validates client shots-fired reports on a 25 m cell grid; pure.
-- Rules: within the caps, player alive, every cell near a server-sampled position, every weapon seen in hand or equipped.

AtlasLib = AtlasLib or {}
local M = {}

M.CELL = 25
M.MAX_DIST = 75
M.MAX_WINDOW_S = 60
M.MAX_WEAPONS = 8
M.MAX_CELLS = 64
M.MAX_SHOTS_PER_WEAPON = 600 -- shot cap: a minigun fires about 500 in a 15 s window

local floor, sqrt, type = math.floor, math.sqrt, type

local function isInt(v, lo, hi)
    return type(v) == 'number' and v == v and floor(v) == v and v >= lo and v <= hi
end

--- @param payload any
--- @param ctx table { alive = bool, positions = { {x, y}, ... }, weapons = { [u32] = true } }
--- @return boolean ok, string? reason, table? clean { window_s, reports = { {weapon, cells, total} } }
function M.validate(payload, ctx)
    if type(payload) ~= 'table' then return false, 'malformed' end
    local win = payload.window_s
    if not isInt(win, 1, M.MAX_WINDOW_S) then return false, 'malformed' end
    local reports = payload.reports
    if type(reports) ~= 'table' or #reports < 1 or #reports > M.MAX_WEAPONS then return false, 'malformed' end

    local clean = {}
    local reach = M.MAX_DIST + M.CELL * 0.7072 -- Reach: cell centre to farthest corner
    local reach2 = reach * reach
    local positions = ctx.positions or {}

    for i = 1, #reports do
        local r = reports[i]
        if type(r) ~= 'table' then return false, 'malformed' end
        local weapon = r.weapon
        if not isInt(weapon, -2147483648, 4294967295) then return false, 'malformed' end
        weapon = floor(weapon) & 0xFFFFFFFF
        local cells = r.cells
        if type(cells) ~= 'table' or #cells < 1 or #cells > M.MAX_CELLS then return false, 'malformed' end
        local total, out = 0, {}
        for j = 1, #cells do
            local c = cells[j]
            if type(c) ~= 'table' then return false, 'malformed' end
            local cx, cy, n = c[1], c[2], c[3]
            if not isInt(cx, -400, 400) or not isInt(cy, -400, 400) or not isInt(n, 1, M.MAX_SHOTS_PER_WEAPON) then
                return false, 'malformed'
            end
            total = total + n
            out[j] = { floor(cx), floor(cy), floor(n) }
        end
        if total > M.MAX_SHOTS_PER_WEAPON then return false, 'volume' end
        clean[i] = { weapon = weapon, cells = out, total = total }
    end

    if not ctx.alive then return false, 'dead' end

    if #positions == 0 then return false, 'position' end
    for i = 1, #clean do
        local cells = clean[i].cells
        for j = 1, #cells do
            local mx, my = (cells[j][1] + 0.5) * M.CELL, (cells[j][2] + 0.5) * M.CELL
            local near = false
            for k = 1, #positions do
                local p = positions[k]
                local dx, dy = p[1] - mx, p[2] - my
                if dx * dx + dy * dy <= reach2 then near = true break end
            end
            if not near then return false, 'position' end
        end
    end

    local weapons = ctx.weapons or {}
    for i = 1, #clean do
        if not weapons[clean[i].weapon] then return false, 'weapon' end
    end

    return true, nil, { window_s = floor(win), reports = clean }
end

--- Cell: grid cell for a world coordinate, shared with the client module.
function M.cell(x, y)
    return floor(x / M.CELL), floor(y / M.CELL)
end

AtlasLib.shots = M
return M
