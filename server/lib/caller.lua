-- Caller: reads FXServer's cross-resource stack text and says which script started a change.
-- Stack text: one line per frame, newest first, such as `> ref (@qb-banking/server/main.lua:88)`.
-- Pure: no FiveM calls, so it is tested under plain Lua; server/attribution.lua feeds it the live stack.

AtlasLib = AtlasLib or {}
local M = {}

--- Frames: the resource, file and line of each frame, newest first; frames of the runtime itself have no resource and are skipped.
--- @param text string? stack text, with or without colour codes
--- @return table[] frames { res, path, line }
function M.frames(text)
    local out = {}
    if type(text) ~= 'string' then return out end
    for res, path, line in text:gsub('%^%d', ''):gmatch('%(@([^/%s]+)/([^:%)]+):(%d+)%)') do
        out[#out + 1] = { res = res, path = path, line = tonumber(line) }
    end
    return out
end

--- Pick: who a stack belongs to.
--- Script: the newest frame outside the core resources (framework, inventory) and the libraries, which is the script that asked.
--- Core: with no such frame the core acted by itself. Its oldest frame says from where (a paycheck loop, a move in the
--- inventory window), and a frame in a command file means a staff command, whichever core resource it runs in.
--- @param frames table[] from frames()
--- @param core table set of resource name to its kind ('framework' or 'inventory')
--- @param libs table set of resource names that only carry a call (the agent itself, ox_lib, oxmysql)
--- @return string? res, string? origin `file:line`, string? kind script, framework, inventory or staff_command
function M.pick(frames, core, libs)
    local oldest, command
    for _, f in ipairs(frames) do
        if not core[f.res] and not libs[f.res] then
            return f.res, ('%s:%d'):format(f.path, f.line), 'script'
        end
        if core[f.res] then oldest = f end
        if f.path:lower():find('command', 1, true) then command = true end
    end
    if not oldest then return nil, nil, nil end
    return oldest.res, ('%s:%d'):format(oldest.path, oldest.line), command and 'staff_command' or core[oldest.res]
end

AtlasLib.caller = M
return M
