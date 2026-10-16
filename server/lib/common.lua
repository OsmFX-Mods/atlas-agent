-- Common: helpers that need no FiveM functions, so plain Lua can test them.

AtlasLib = AtlasLib or {}
local M = {}

local floor, sqrt, abs = math.floor, math.sqrt, math.abs

--- Round: rounds to 0.1, the precision positions are stored at.
function M.round1(v)
    return floor(v * 10 + 0.5) / 10
end

--- Position: [x, y, z] array rounded to 0.1 m.
function M.pos(x, y, z)
    return { floor(x * 10 + 0.5) / 10, floor(y * 10 + 0.5) / 10, floor(z * 10 + 0.5) / 10 }
end

function M.dist3(ax, ay, az, bx, by, bz)
    local dx, dy, dz = ax - bx, ay - by, az - bz
    return sqrt(dx * dx + dy * dy + dz * dz)
end

function M.dist2(ax, ay, bx, by)
    local dx, dy = ax - bx, ay - by
    return sqrt(dx * dx + dy * dy)
end

--- Heading difference: the smallest angle between two headings, 0 to 180 degrees.
function M.headingDiff(a, b)
    local d = abs(a - b) % 360
    if d > 180 then d = 360 - d end
    return d
end

--- Unsigned hash: converts a game hash to an unsigned 32-bit number, as natives and events differ in sign.
function M.u32(h)
    if type(h) ~= 'number' then return nil end
    h = floor(h)
    return h & 0xFFFFFFFF
end

--- Slice size: players to read per slice so everyone is read once per `sampleMs`.
function M.perSlice(n, sampleMs, sliceMs)
    if n <= 0 then return 0 end
    local slices = sampleMs / (sliceMs or 50)
    if slices < 1 then slices = 1 end
    return math.ceil(n / slices)
end

-- Unique id: 26 characters that start with the time, so ids sort by age; used as the boot id.
-- Order: transport.js sends saved events from older starts first.
local ENC = '0123456789ABCDEFGHJKMNPQRSTVWXYZ'

function M.ulid(nowMs, rand)
    rand = rand or math.random
    local out = {}
    local t = floor(nowMs)
    for i = 10, 1, -1 do
        local r = t % 32
        out[i] = ENC:sub(r + 1, r + 1)
        t = t // 32
    end
    for i = 11, 26 do
        local r = rand(0, 31)
        out[i] = ENC:sub(r + 1, r + 1)
    end
    return table.concat(out)
end

-- Identifiers kept for players; IP addresses are never collected.
local KEEP_IDS = { license = true, license2 = true, discord = true, fivem = true, steam = true, xbl = true, live = true }
local ACCOUNT_ORDER = { 'license2', 'license', 'fivem', 'discord' }

--- Identifiers: turns the player's identifier list into { prefix = 'prefix:value' }, leaving out IPs.
--- Account id: the first of license2, license, fivem, discord.
function M.pickIdentifiers(list)
    local ids = {}
    for i = 1, #list do
        local s = list[i]
        local prefix = type(s) == 'string' and s:match('^([%w_]+):')
        if prefix and KEEP_IDS[prefix] then ids[prefix] = s end
    end
    local account
    for i = 1, #ACCOUNT_ORDER do
        account = ids[ACCOUNT_ORDER[i]]
        if account then break end
    end
    return ids, account
end

--- Account kind: tells whether a Renewed-Banking account belongs to a job, a gang, a person or a business.
--- Groups: jobs and gangs are sets of group names.
function M.accountKind(id, creator, jobs, gangs)
    if jobs and jobs[id] then return 'job' end
    if gangs and gangs[id] then return 'gang' end
    if creator ~= nil and creator ~= '' then return 'shared' end
    return 'business'
end

--- SQL name: a table or column name from the config as a quoted identifier, or nil when it has anything but letters, digits and underscores.
function M.sqlName(name)
    if type(name) ~= 'string' or not name:find('^[%w_]+$') then return nil end
    return '`' .. name .. '`'
end

--- Plate: trimmed and upper-cased, the form plates are hashed in; nil when there is none.
function M.plate(plate)
    if type(plate) ~= 'string' then return nil end
    local s = plate:upper():gsub('^%s+', ''):gsub('%s+$', '')
    return s ~= '' and s or nil
end

--- Chat summary: message length and command name; the text is added only when chat content is on.
function M.chatSummary(text, withContent)
    if type(text) ~= 'string' then return nil end
    local data = { len = #text }
    local cmd = text:match('^/(%S+)')
    if cmd then data.command = '/' .. cmd:sub(1, 32):lower() end
    if withContent then data.text = text:sub(1, 512) end
    return data
end

--- Hash: a fixed 32-bit hash of a string, for places where GetHashKey is not available, such as tests.
function M.fnv1a(s)
    local h = 0x811C9DC5
    for i = 1, #s do
        h = h ~ s:byte(i)
        h = (h * 0x01000193) & 0xFFFFFFFF
    end
    return h
end

-- Sanitize limits: caps on the data a script can pass to the track export.
local MAX_DEPTH, MAX_KEYS, MAX_STR, MAX_KEY = 4, 64, 1024, 64

--- Sanitize: copies strings, numbers, booleans and tables only, within the limits above.
function M.sanitize(v, depth)
    depth = depth or 0
    local t = type(v)
    if t == 'string' then return #v > MAX_STR and v:sub(1, MAX_STR) or v end
    if t == 'boolean' then return v end
    if t == 'number' then
        if v ~= v or v == math.huge or v == -math.huge then return nil end
        return v
    end
    if t ~= 'table' or depth >= MAX_DEPTH then return nil end
    local out, n = {}, 0
    for k, x in pairs(v) do
        local tk = type(k)
        if tk == 'string' or tk == 'number' then
            local c = M.sanitize(x, depth + 1)
            if c ~= nil then
                n = n + 1
                if n > MAX_KEYS then break end
                out[tk == 'string' and k:sub(1, MAX_KEY) or k] = c
            end
        end
    end
    return out
end

AtlasLib.common = M
return M
