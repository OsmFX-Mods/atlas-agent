local fx = load_module('tests/fivem.lua')

local function boot(oxmysql)
    fx.boot({ resources = { oxmysql = 'started' }, provided = { oxmysql = oxmysql }, load = { 'server/db.lua' } })
end

--- Run: executes `fn` in a thread and advances the clock until it finishes or `ms` pass.
local function run(fn, ms)
    local result
    CreateThread(function() result = table.pack(fn()) end)
    fx.advance(ms or 1000)
    return result
end

describe('db', function()
    it('returns the result of a query that calls back', function()
        boot({ scalar = function(_, _, _, cb) cb(42) end })
        local r = run(function() return Atlas.db.scalar('SELECT 1') end)
        expect(r[1]).toBe(42)
        fx.teardown()
    end)

    it('returns the error oxmysql reports', function()
        boot({ query = function(_, _, _, cb) cb(nil, 'syntax error') end })
        local r = run(function() return Atlas.db.query('BAD') end)
        expect(r[1]).toBeNil()
        expect(r[2]).toBe('syntax error')
        fx.teardown()
    end)

    it('gives up on a query that never calls back', function()
        boot({ query = function() end })
        local r = run(function() return Atlas.db.query('SELECT 1') end, 20000)
        expect(r ~= nil).toBe(true)
        expect(r[1]).toBeNil()
        expect(r[2]).toBe('oxmysql timed out')
        fx.teardown()
    end)

    it('does not time out a query that answers in time', function()
        local late
        boot({ scalar = function(_, _, _, cb) late = cb end })
        local r
        CreateThread(function() r = table.pack(Atlas.db.scalar('SELECT 1')) end)
        fx.advance(5000)
        late(7)
        fx.advance(20000)
        expect(r[1]).toBe(7)
        fx.teardown()
    end)

    it('reports oxmysql missing without calling it', function()
        fx.boot({ load = { 'server/db.lua' } })
        local v, err = Atlas.db.scalar('SELECT 1')
        expect(v).toBeNil()
        expect(err).toBe('oxmysql not started')
        fx.teardown()
    end)
end)
