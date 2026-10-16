-- Sandbox: runs another resource's config file safely so the places importer can read its coordinates.
-- Unknown names (lib, locale and so on) give a harmless empty value; files that fail to load are skipped.

AtlasLib = AtlasLib or {}
local M = {}

local hole
hole = setmetatable({}, {
    __index = function() return hole end,
    __call = function() return hole end,
    __newindex = function() end, -- newindex: writes are dropped, so a config cannot leave values behind for the next one
    __tostring = function() return '' end,
})
M.hole = hole

local function vec(...)
    local n = select('#', ...)
    local a, b, c, d = ...
    if n == 1 and type(a) == 'table' then return a end
    return { x = a, y = b, z = c, w = d }
end

local HOOK_STEPS = 5000000 -- Step limit: instructions allowed before a config is stopped (about 50 ms)

--- Copy: copies a standard library table, so a config cannot change the real one.
local function copy(t)
    local out = {}
    for k, v in pairs(t) do out[k] = v end
    return out
end

--- Guarded call: stops a config that never ends, such as a loop on the empty value.
local function guarded(fn)
    local hooked = debug and debug.sethook
        and pcall(debug.sethook, function() error('config ran too long', 0) end, '', HOOK_STEPS)
    local ok, res = pcall(fn)
    if hooked then pcall(debug.sethook) end
    return ok, res
end

--- @param src string Lua source
--- @param chunkname string
--- @param vectors table? { vec3 = fn, vector3 = fn, ... } (FiveM provides real ones)
--- @param globals table? values to define before the file runs, for files that add to a table another file creates
--- @return any result, table env  (result = the chunk's return value)
function M.load(src, chunkname, vectors, globals)
    if type(src) ~= 'string' or src == '' then return nil, nil end
    vectors = vectors or {}
    local env = {
        math = copy(math), string = copy(string), table = copy(table),
        pairs = pairs, ipairs = ipairs, next = next, select = select, type = type,
        tostring = tostring, tonumber = tonumber, setmetatable = setmetatable,
        vec = vectors.vec or vec, vec2 = vectors.vec2 or vec, vec3 = vectors.vec3 or vec, vec4 = vectors.vec4 or vec,
        vector2 = vectors.vector2 or vec, vector3 = vectors.vector3 or vec, vector4 = vectors.vector4 or vec,
        joaat = vectors.joaat, GetHashKey = vectors.joaat,
    }
    for k, v in pairs(globals or {}) do env[k] = v end
    setmetatable(env, { __index = function() return hole end })
    local fn, err = load(src, '@' .. chunkname, 't', env)
    if not fn then return nil, nil, err end
    local ok, res = guarded(fn)
    if not ok then return nil, nil, res end
    return res, env
end

--- Items: loops over the list part of a config value; the empty value gives nothing.
function M.items(t)
    local n = type(t) == 'table' and #t or 0
    local i = 0
    return function()
        i = i + 1
        if i <= n then return i, t[i] end
    end
end

--- Coordinates: extracts x, y and z from a vector3, vector4, table or {x=,y=} value.
function M.xyz(v)
    local t = type(v)
    if t == 'vector3' or t == 'vector4' or t == 'vector2' or t == 'table' or t == 'userdata' then
        local ok, x, y, z = pcall(function() return v.x, v.y, v.z end)
        if ok and type(x) == 'number' and type(y) == 'number' then return x, y, (type(z) == 'number' and z or 0.0) end
    end
    return nil
end

AtlasLib.sandbox = M
return M
