-- Common: pure helpers with no FiveM globals, so plain Lua 5.4 can test them.
-- Loading: a server_script fills AtlasLib.common; tests load it with dofile() and receive M.

AtlasLib = AtlasLib or {}
local M = {}

local floor, sqrt, abs = math.floor, math.sqrt, math.abs

--- Round: to 0.1 (10 cm), the precision positions are stored at.
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

--- Heading difference: smallest absolute difference between two headings, 0 to 180 degrees.
function M.headingDiff(a, b)
    local d = abs(a - b) % 360
    if d > 180 then d = 360 - d end
    return d
end

--- Unsigned hash: normalises a GTA hash to unsigned 32-bit, since client natives return signed and some server events unsigned.
function M.u32(h)
    if type(h) ~= 'number' then return nil end
    h = floor(h)
    return h & 0xFFFFFFFF
end

--- Slice size: players to sample per slice so everyone is sampled once per `sampleMs`, spread evenly over `sliceMs` slices.
function M.perSlice(n, sampleMs, sliceMs)
    if n <= 0 then return 0 end
    local slices = sampleMs / (sliceMs or 50)
    if slices < 1 then slices = 1 end
    return math.ceil(n / slices)
end

-- ULID: 48-bit ms timestamp plus 80 random bits in Crockford base32, used as the per-start `boot` id.
-- Ordering: ids sort by time, which the transport relies on to replay spool files of older boots first.
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

-- Identifier prefixes: the list kept for players; IPs are never collected.
local KEEP_IDS = { license = true, license2 = true, discord = true, fivem = true, steam = true, xbl = true, live = true }
local ACCOUNT_ORDER = { 'license2', 'license', 'fivem', 'discord' }

--- Identifiers: turns a GetPlayerIdentifiers() list into { prefix = 'prefix:value' } without IPs.
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

--- Account kind: classifies a Renewed-Banking bank_accounts_new row for accounts.snapshot.
--- Groups: jobs and gangs are sets of qbx group names.
function M.accountKind(id, creator, jobs, gangs)
    if jobs and jobs[id] then return 'job' end
    if gangs and gangs[id] then return 'gang' end
    if creator ~= nil and creator ~= '' then return 'shared' end
    return 'business'
end

--- Chat summary: message length and command name (first word after '/'), plus the text only when content capture is enabled.
function M.chatSummary(text, withContent)
    if type(text) ~= 'string' then return nil end
    local data = { len = #text }
    local cmd = text:match('^/(%S+)')
    if cmd then data.command = '/' .. cmd:sub(1, 32):lower() end
    if withContent then data.text = text:sub(1, 512) end
    return data
end

--- FNV-1a: stable 32-bit string hash for non-reversible ids where GetHashKey is unavailable, as in tests.
function M.fnv1a(s)
    local h = 0x811C9DC5
    for i = 1, #s do
        h = h ~ s:byte(i)
        h = (h * 0x01000193) & 0xFFFFFFFF
    end
    return h
end

-- Sanitize limits: caps on what a script can hand to exports.track, since the data crosses to JS as is.
local MAX_DEPTH, MAX_KEYS, MAX_STR, MAX_KEY = 4, 64, 1024, 64

--- Sanitize: copies plain data only (strings, finite numbers, booleans, tables); functions, userdata and cycles are dropped.
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
