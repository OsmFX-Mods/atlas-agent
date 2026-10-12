-- Database: calls exports.oxmysql directly and awaits a promise, so oxmysql is not a hard dependency.
-- Yielding: call these only from threads (CreateThread), never from inside ox_inventory or qbx hooks.

Atlas.db = {}

local resource = GetCurrentResourceName()
local TIMEOUT_MS = 15000

function Atlas.db.available()
    return GetResourceState('oxmysql') == 'started'
end

--- @param method 'query'|'scalar'|'single'
--- @return any result, string? err
local function call(method, sql, params)
    if not Atlas.db.available() then return nil, 'oxmysql not started' end
    local p = promise.new()
    local settled = false
    local function settle(fn, v)
        if settled then return end
        settled = true
        fn(p, v)
    end
    local ok, err = pcall(function()
        exports.oxmysql[method](nil, sql, params or {}, function(result, e)
            if e then settle(p.reject, e) else settle(p.resolve, result) end
        end, resource, true)
    end)
    if not ok then return nil, tostring(err) end
    -- Timeout: a query that never calls back would hold the calling thread forever
    SetTimeout(TIMEOUT_MS, function() settle(p.reject, 'oxmysql timed out') end)
    local ok2, res = pcall(Citizen.Await, p)
    if not ok2 then return nil, tostring(res) end
    return res
end

function Atlas.db.query(sql, params) return call('query', sql, params) end
function Atlas.db.scalar(sql, params) return call('scalar', sql, params) end
function Atlas.db.single(sql, params) return call('single', sql, params) end

--- Database clock: unix seconds with fractions; snapshot deltas use it so agent clock skew cannot skip rows.
function Atlas.db.now()
    local v, err = call('scalar', 'SELECT UNIX_TIMESTAMP(NOW(3))')
    return tonumber(v), err
end
