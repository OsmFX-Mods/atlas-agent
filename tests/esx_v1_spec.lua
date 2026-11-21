local fx = load_module('tests/fivem.lua')

-- ESX v1: stock es_extended from before accounts moved to JSON in users. Layouts of the saved data:
-- A (1.1.0): users.money and users.bank, black_money in user_accounts, items in user_inventory.
-- B (February 2020): as A, with items as JSON in users.inventory.
-- C (1.2.0): every account in user_accounts, items as JSON in users.inventory, no name or is_dead columns.
-- D (upgraded): as C, with the old users.money, users.bank and user_inventory left behind holding stale data.

local SETTLE_MS = 2600 -- SETTLE_MS: just past the wait for the respawn callback that may follow a cleared dead state

local SAVED = {
    { identifier = 'steam:a', cash = 10, bank = 100, black = 5, items = { bread = 2, water = 0 } },
    { identifier = 'steam:b', cash = 20, bank = 200, black = 0, items = { water = 3 } },
    { identifier = 'steam:c', cash = 30, bank = 300, black = 0, items = { bread = 0 } },
}

local world -- world: the fake server: saved tables, live players and what the database was asked

--- Funcref: what a function from another resource looks like: callable, and an error when indexed.
local function funcref(fn)
    return setmetatable({}, {
        __call = function(_, ...) return fn(...) end,
        __index = function(_, key) error('attempt to index a funcref with ' .. tostring(key)) end,
    })
end

local function data() return Atlas.frameworkData.esx end

--- Seed: fills the saved tables for one layout.
local function seed(kind, opts)
    local users = { 'identifier', 'group', 'job', 'job_grade' }
    local function has(...) for _, c in ipairs({ ... }) do users[#users + 1] = c end end
    if kind == 'A' or kind == 'B' or kind == 'D' then has('money', 'bank', 'firstname', 'lastname', 'is_dead') end
    if kind ~= 'A' then has('inventory') end
    if kind == 'legacy' then has('accounts', 'firstname', 'lastname') end
    if opts.created then has('created_at') end

    world.columns = {}
    if kind == 'none' then return end
    world.columns.users = users
    if kind ~= 'legacy' then world.columns.user_accounts = { 'identifier', 'name', 'money' } end
    if kind == 'A' or kind == 'D' then world.columns.user_inventory = { 'identifier', 'item', 'count' } end

    for _, s in ipairs(SAVED) do
        local row = { identifier = s.identifier }
        if kind == 'A' or kind == 'B' then row.money, row.bank = s.cash, s.bank end
        if kind == 'D' then row.money, row.bank = 999, 999 end
        if kind ~= 'A' then row.inventory = json.encode(s.items) end
        if kind == 'legacy' then row.accounts = json.encode({ money = s.cash, bank = s.bank, black_money = s.black }) end
        world.users[#world.users + 1] = row

        if kind == 'A' or kind == 'B' then
            world.accounts[#world.accounts + 1] = { identifier = s.identifier, name = 'black_money', money = s.black }
        elseif (kind == 'C' or kind == 'D') and not opts.emptyAccounts then
            world.accounts[#world.accounts + 1] = { identifier = s.identifier, name = 'money', money = s.cash }
            world.accounts[#world.accounts + 1] = { identifier = s.identifier, name = 'bank', money = s.bank }
            world.accounts[#world.accounts + 1] = { identifier = s.identifier, name = 'black_money', money = s.black }
        end

        if kind == 'A' then
            for item, count in pairs(s.items) do
                world.items[#world.items + 1] = { identifier = s.identifier, item = item, count = count }
            end
        elseif kind == 'D' then
            world.items[#world.items + 1] = { identifier = s.identifier, item = 'stale', count = 9 }
        end
    end
end

--- Users after: one keyset page of the users table.
local function usersAfter(cursor, limit)
    local out = {}
    for _, u in ipairs(world.users) do
        if u.identifier > cursor then
            out[#out + 1] = u
            if #out == limit then break end
        end
    end
    return out
end

--- Items page: the rows of the next `limit` holders that have at least one item.
local function itemRows(cursor, limit)
    local seen, holders = {}, {}
    for _, r in ipairs(world.items) do
        if r.count > 0 and r.identifier > cursor and not seen[r.identifier] then
            seen[r.identifier] = true
            holders[#holders + 1] = r.identifier
        end
    end
    table.sort(holders)
    local chosen = {}
    for i = 1, math.min(limit, #holders) do chosen[holders[i]] = true end
    local out = {}
    for _, r in ipairs(world.items) do
        if r.count > 0 and chosen[r.identifier] then out[#out + 1] = { identifier = r.identifier, item = r.item, n = r.count } end
    end
    table.sort(out, function(a, b)
        if a.identifier ~= b.identifier then return a.identifier < b.identifier end
        return a.item < b.item
    end)
    return out
end

--- Query: answers the statements the ESX readers send, from the saved tables.
local function query(sql, params)
    params = params or {}
    world.queries[#world.queries + 1] = sql
    if sql:find('TABLE_NAME IN', 1, true) then
        world.schemaReads = world.schemaReads + 1
        if world.schemaErrors > 0 then
            world.schemaErrors = world.schemaErrors - 1
            return nil, 'timeout'
        end
        local out = {}
        for i = 1, 3 do
            for _, c in ipairs(params[i] and world.columns[params[i]] or {}) do out[#out + 1] = { t = params[i], c = c } end
        end
        return out
    end
    if sql:find('information_schema', 1, true) then
        local out = {}
        for _, c in ipairs(world.columns[params[1]] or {}) do
            out[#out + 1] = { c = c, e = c == 'created_at' and 'DEFAULT_GENERATED' or '' }
        end
        return out
    end

    local limit = tonumber(sql:match('LIMIT (%d+)'))
    local cursor = params[#params] or ''
    if sql:find('SELECT u.identifier', 1, true) then
        -- Join: one row per holder and account, and one row with no account for a holder who has none
        local fromColumns = sql:find('u.money', 1, true) ~= nil
        local out = {}
        for _, u in ipairs(usersAfter(cursor, limit)) do
            local money, bank = fromColumns and u.money or nil, fromColumns and u.bank or nil
            local any = false
            for _, a in ipairs(world.accounts) do
                if a.identifier == u.identifier then
                    any = true
                    out[#out + 1] = { identifier = u.identifier, money = money, bank = bank, account = a.name, amount = a.money }
                end
            end
            if not any then out[#out + 1] = { identifier = u.identifier, money = money, bank = bank } end
        end
        return out
    elseif sql:find('SELECT identifier, money, bank', 1, true) then
        local out = {}
        for i, u in ipairs(usersAfter(cursor, limit)) do out[i] = { identifier = u.identifier, money = u.money, bank = u.bank } end
        return out
    elseif sql:find('SELECT identifier, inventory', 1, true) then
        local out = {}
        for i, u in ipairs(usersAfter(cursor, limit)) do out[i] = { identifier = u.identifier, inventory = u.inventory } end
        return out
    elseif sql:find('SELECT i.identifier, i.item', 1, true) then
        return itemRows(cursor, limit)
    elseif sql:find('AS k, accounts', 1, true) then
        local out = {}
        for i, u in ipairs(usersAfter(cursor, limit)) do out[i] = { identifier = u.identifier, k = u.identifier, accounts = u.accounts } end
        return out
    elseif sql:find('SELECT name FROM', 1, true) then
        local out = {}
        for i, name in ipairs(world.jobs) do out[i] = { name = name } end
        return out
    end
    return {}
end

local function scalar(sql, params)
    world.queries[#world.queries + 1] = sql
    if sql:find("name = 'bank'", 1, true) then
        for _, a in ipairs(world.accounts) do if a.name == 'bank' then return 1 end end
        return nil
    elseif sql:find('COUNT(DISTINCT identifier)', 1, true) then
        local seen, n = {}, 0
        for _, r in ipairs(world.items) do
            if r.count > 0 and not seen[r.identifier] then seen[r.identifier], n = true, n + 1 end
        end
        return n
    elseif sql:find('COUNT(*)', 1, true) then
        return #world.users
    elseif sql:find('WHERE identifier = ?', 1, true) then
        return params[1] .. '#1761200000' -- key: a timed character key, only asked for when users has a creation column in use
    end
end

--- Single: the saved identity row, after world.slowMs so a spec can act while it is being read.
local function single(sql, params)
    world.singles = world.singles + 1
    world.queries[#world.queries + 1] = sql
    if world.slowMs then Wait(world.slowMs) end
    local columns = sql:match('^SELECT (.-) FROM')
    for _, u in ipairs(world.users) do
        if u.identifier == params[1] then
            local row = {}
            for c in columns:gmatch('[%w_]+') do row[c] = u[c] end
            return row
        end
    end
end

--- Boot: a server with stock v1 es_extended in the given layout, or 'legacy' or 'none'.
--- @param opts table? { version, db = false, schemaErrors, created, emptyAccounts, before = fn, attachMs }
local function boot(kind, opts)
    opts = opts or {}
    world = {
        kind = kind, live = {}, state = {}, users = {}, accounts = {}, items = {}, jobs = { 'ambulance', 'police' },
        queries = {}, singles = 0, schemaReads = 0, schemaErrors = opts.schemaErrors or 0,
        dbUp = opts.db ~= false, version = opts.version or '1.2.0',
    }
    local ESX = { GetPlayerFromId = funcref(function(src) return world.live[src] end) } -- ESX: stock v1 has no ESX.Player or ESX.GetJobs
    fx.boot({
        convars = { ['atlas:token'] = 'atl_live_x', ['atlas:snapshots'] = 0 },
        resources = { es_extended = 'started', esx_ambulancejob = 'started' },
        provided = { es_extended = { getSharedObject = funcref(function() return ESX end) } }, -- no RunStaticPlayerMethod either
        load = {
            'server/db.lua', 'server/adapters/detect.lua', 'server/sources.lua', 'server/framework.lua',
            'server/characters.lua', 'server/staff.lua', 'server/money.lua', 'server/adapters/esx_data.lua', 'server/adapters/esx_v1.lua',
            'server/adapters/esx.lua', 'server/adapters/esx_death.lua', 'server/adapters/esx_ambulance.lua', 'server/snapshots.lua',
        },
    })
    seed(kind, opts)
    fx.set('GetResourceMetadata', function(res, key)
        if res == 'es_extended' and key == 'version' then return world.version end
        return '0.1.0'
    end)
    fx.set('Player', function() return { state = {} } end)
    local db = Atlas.db
    db.available = function() return world.dbUp end
    db.query, db.scalar, db.single = query, scalar, single
    db.now = function() return 1790000100.5 end
    world.legacy = { money = data().money, census = data().census, groups = data().groups }
    if opts.before then opts.before() end
    fx.advance(opts.attachMs or 200)
end

local function events(etype)
    Atlas.jsReady = true
    Atlas.flush()
    local out = {}
    for _, call in ipairs(fx.triggered('atlas:internal:batch')) do
        for _, ev in ipairs(call[1]) do
            if ev.type == etype then out[#out + 1] = ev end
        end
    end
    return out
end

--- Run: executes `fn` in a thread, since snapshots wait between pages.
local function run(fn)
    local done = false
    CreateThread(function() fn(); done = true end)
    fx.advance(60000, 100)
    return done
end

--- Live player: an xPlayer of the booted layout, with every method a funcref.
local function livePlayer(src, spec)
    spec = spec or {}
    local s = {
        cash = spec.cash or 100, bank = spec.bank or 500, black = spec.black or 0, group = spec.group or 'user',
        job = spec.job or { name = 'police', grade = 2, grade_salary = 75 },
        items = spec.items or { { name = 'bread', count = 2 }, { name = 'water', count = 1 }, { name = 'stone', count = 0 } },
        calls = {},
    }
    local x = { source = src, identifier = spec.identifier or ('steam:p' .. src) }
    x.getJob = funcref(function() return s.job end)
    x.getGroup = funcref(function() return s.group end)
    x.getMoney = funcref(function() return s.cash end)
    x.getAccounts = funcref(function()
        local list = {}
        if world.kind == 'C' or world.kind == 'D' then list[1] = { name = 'money', money = s.cash, label = 'Cash' } end
        list[#list + 1] = { name = 'bank', money = s.bank, label = 'Bank' }
        list[#list + 1] = { name = 'black_money', money = s.black, label = 'Black money' }
        return list
    end)
    x.getInventory = funcref(function(minimal)
        if world.kind == 'A' or not minimal then return s.items end -- A: ignores its argument and keeps zero counts
        local map = {}
        for _, item in ipairs(s.items) do
            if item.count > 0 then map[item.name] = item.count end
        end
        return map
    end)
    x.setAccountMoney = funcref(function(name, money, reason)
        s.calls[#s.calls + 1] = { name, money, reason }
        if name == 'money' then s.cash = money elseif name == 'bank' then s.bank = money else s.black = money end
    end)
    world.live[src], world.state[src] = x, s
    return x, s
end

--- Save user: adds or updates the player's users row.
local function saveUser(identifier, fields)
    local row
    for _, u in ipairs(world.users) do if u.identifier == identifier then row = u end end
    if not row then
        row = { identifier = identifier }
        world.users[#world.users + 1] = row
        table.sort(world.users, function(a, b) return a.identifier < b.identifier end)
    end
    for k, v in pairs(fields or {}) do row[k] = v end
end

local function connect(src, spec)
    fx.addPlayer(src, { ped = { x = 10.0, y = 10.0, z = 30.0, h = 0.0 } })
    Atlas.ensurePlayer(src)
    local x, s = livePlayer(src, spec)
    saveUser(x.identifier, spec and spec.saved)
    return x, s
end

local function login(src, spec)
    local x, s = connect(src, spec)
    TriggerEvent('esx:playerLoaded', src, x)
    fx.advance(50)
    return Atlas.players[src], s, x
end

local function drop(src)
    Atlas.runDrop(Atlas.players[src], 'quit')
    Atlas.removePlayer(src)
end

local function restart()
    TriggerEvent('onResourceStop', 'es_extended')
    TriggerEvent('onResourceStart', 'es_extended')
    fx.advance(200)
end

local function readAs(name) return #fx.printed('es_extended read as ' .. name) end

local function setItem(s, name, count)
    for _, item in ipairs(s.items) do if item.name == name then item.count = count end end
end

describe('esx v1 detection', function()
    for _, kind in ipairs({ 'A', 'B', 'C', 'D' }) do
        it('reads layout ' .. kind .. ' as ESX v1 from the database, whatever the resource version says', function()
            boot(kind, { version = '2.0.0' })
            expect(Atlas.adapterActive('esx')).toBe(true)
            expect(readAs('ESX v1')).toBe(1)
            expect(data().money.delta).toBe(false)
            fx.teardown()
        end)
    end

    it('reads a users.accounts column as ESX Legacy, whatever the resource version says', function()
        boot('legacy', { version = '1.2.0' })
        expect(readAs('ESX Legacy')).toBe(1)
        expect(readAs('ESX v1')).toBe(0)
        fx.teardown()
    end)

    it('retries after a database error', function()
        boot('A', { version = '2.0.0', schemaErrors = 2, attachMs = 3000 })
        expect(world.schemaReads).toBe(3)
        expect(readAs('ESX v1')).toBe(1)
        fx.teardown()
    end)

    it('falls back to the resource version when the database keeps failing', function()
        boot('A', { version = '1.2.0', schemaErrors = 99, attachMs = 6000 })
        expect(world.schemaReads).toBe(5)
        expect(readAs('ESX v1')).toBe(1)
        fx.teardown()
        boot('A', { version = '1.9.4', schemaErrors = 99, attachMs = 6000 })
        expect(readAs('ESX Legacy')).toBe(1)
        fx.teardown()
    end)

    local VERSIONS = {
        { '1.0.0', true }, { '1.1.0', true }, { '1.2', true }, { '1.2.0', true },
        { '1.3.0', false }, { '1.10.2', false }, { '0.9.0', false }, { '2.0.0', false }, { 'legacy', false },
    }
    for _, case in ipairs(VERSIONS) do
        it(('reads version %s as %s without a database'):format(case[1], case[2] and 'v1' or 'not v1'), function()
            boot('A', { version = case[1], db = false })
            expect(world.schemaReads).toBe(0)
            expect(readAs(case[2] and 'ESX v1' or 'ESX Legacy')).toBe(1)
            fx.teardown()
        end)

        it(('reads version %s as %s without a users table'):format(case[1], case[2] and 'v1' or 'not v1'), function()
            boot('none', { version = case[1] })
            expect(world.schemaReads).toBe(1)
            expect(readAs(case[2] and 'ESX v1' or 'ESX Legacy')).toBe(1)
            fx.teardown()
        end)
    end

    it('keeps the Legacy readers and sends no v1 query when attached as Legacy', function()
        boot('legacy', { created = true })
        expect(data().money).toBe(world.legacy.money)
        expect(data().census).toBe(world.legacy.census)
        expect(data().groups).toBe(world.legacy.groups)
        expect(AtlasConfig.esx.createdColumn).toBe('created_at')

        local x = { source = 4, identifier = 'char1:abc4', variables = { firstName = 'Ann', lastName = 'Lee' } }
        x.getJob = funcref(function() return { name = 'police', grade = 2, onDuty = true } end)
        x.getAccounts = funcref(function() return { money = 100, bank = 500, black_money = 0 } end)
        fx.addPlayer(4, {})
        Atlas.ensurePlayer(4)
        world.live[4] = x
        TriggerEvent('esx:playerLoaded', 4, x, false)
        fx.advance(50)
        expect(Atlas.players[4].char).toBe('char1:abc4#1761200000')
        expect(events('session.char_start')[1].data.char_name).toBe('Ann Lee')
        expect(data().money.page(nil, nil, 5)[1]).toEqual({ 'steam:a', 10, 100, 0 })

        fx.client('esx_ambulancejob:setDeathStatus', 4, true)
        expect(#events('combat.death')).toBe(0)
        expect(world.singles).toBe(0)
        for _, sql in ipairs(world.queries) do
            expect(sql:find('user_accounts', 1, true)).toBeNil()
            expect(sql:find('user_inventory', 1, true)).toBeNil()
            expect(sql:find('`jobs`', 1, true)).toBeNil()
        end
        fx.teardown()
    end)
end)

describe('esx v1 characters', function()
    for _, kind in ipairs({ 'A', 'B', 'C', 'D' }) do
        it('keys a character by plain identifier in layout ' .. kind .. ', also with a created_at column', function()
            boot(kind, { created = true })
            local p = login(4, { identifier = 'steam:abc' })
            expect(p.char).toBe('steam:abc')
            expect(events('session.char_start')[1].data.char).toBe('steam:abc')
            fx.teardown()
        end)
    end

    for _, kind in ipairs({ 'A', 'B', 'D' }) do
        it('loads job, balances, group, saved name and saved dead state in layout ' .. kind, function()
            boot(kind)
            local p = login(4, {
                cash = 150, bank = 700, black = 25, group = 'admin',
                job = { name = 'ambulance', grade = 3, grade_salary = 120 },
                saved = { firstname = 'Ann', lastname = 'Lee', is_dead = 1 },
            })
            local ev = events('session.char_start')[1]
            expect(ev.data.char_name).toBe('Ann Lee')
            expect(ev.data.job).toBe('ambulance')
            expect(p.grade).toBe(3)
            expect(p.jobPayment).toBe(120)
            expect(p.money).toEqual({ cash = 150, bank = 700, crypto = 0, black_money = 25 })
            expect(p.staff).toBe('admin')
            expect(p.down).toBe(true)
            expect(p.state.isdead).toBe(true)
            expect(#events('combat.death')).toBe(0)
            fx.teardown()
        end)
    end

    it('loads layout C, which has no name or is_dead columns', function()
        boot('C')
        local p = login(4, { cash = 150, bank = 700, black = 25, group = 'mod' })
        expect(events('session.char_start')[1].data.char_name).toBeNil()
        expect(p.money).toEqual({ cash = 150, bank = 700, crypto = 0, black_money = 25 })
        expect(p.staff).toBe('mod')
        expect(p.down).toBe(false)
        expect(world.singles).toBe(0)
        fx.teardown()
    end)

    it('reads is_dead = 0 as alive', function()
        boot('A')
        local p = login(4, { saved = { firstname = 'Ann', lastname = 'Lee', is_dead = 0 } })
        expect(p.down).toBe(false)
        expect(p.state).toBeNil()
        fx.teardown()
    end)

    it('starts a character at once without a database', function()
        boot('A', { db = false, version = '1.2.0' })
        local x = connect(4, { identifier = 'steam:abc' })
        TriggerEvent('esx:playerLoaded', 4, x)
        expect(Atlas.players[4].char).toBe('steam:abc')
        expect(world.singles).toBe(0)
        fx.teardown()
    end)

    it('replays money events that arrive while the identity is read', function()
        boot('A')
        world.slowMs = 500
        local x, s = connect(4, { saved = { firstname = 'Ann', lastname = 'Lee' } })
        TriggerEvent('esx:playerLoaded', 4, x)
        fx.advance(50)
        s.bank = 600
        TriggerEvent('esx:addAccountMoney', 4, 'bank', 100, 'Paycheck')
        expect(#events('session.char_start')).toBe(0)
        expect(#events('money.change')).toBe(0)
        fx.advance(600)
        local start, money = events('session.char_start')[1], events('money.change')
        expect(start.data.char_name).toBe('Ann Lee')
        expect(#money).toBe(1)
        expect(money[1].data.delta).toBe(100)
        expect(money[1].data.balance_after).toBe(600)
        expect(money[1].actor.char).toBe('steam:p4')
        expect(start.seq < money[1].seq).toBe(true)
        fx.teardown()
    end)

    it('does not start a character when the player disconnects during the read', function()
        boot('A')
        world.slowMs = 500
        local x = connect(4)
        TriggerEvent('esx:playerLoaded', 4, x)
        fx.advance(50)
        world.live[4] = nil
        TriggerEvent('esx:playerDropped', 4, 'Disconnected.')
        drop(4)
        fx.advance(600)
        expect(#events('session.char_start')).toBe(0)
        expect(Atlas.players[4]).toBeNil()
        fx.teardown()
    end)

    it('does not start a character when only the player drop arrives during the read', function()
        boot('A')
        world.slowMs = 500
        local x = connect(4)
        TriggerEvent('esx:playerLoaded', 4, x)
        fx.advance(50)
        drop(4)
        fx.advance(600)
        expect(#events('session.char_start')).toBe(0)
        fx.teardown()
    end)

    it('ends the character on esx:playerDropped and reports esx_player_logout as a logout', function()
        boot('A')
        local p = login(4)
        TriggerEvent('esx:playerDropped', 4, 'esx_player_logout')
        expect(events('session.char_end')[1].data.reason).toBe('logout')
        expect(p.char).toBeNil()
        login(5)
        TriggerEvent('esx:playerDropped', 5, 'Disconnected.')
        expect(events('session.char_end')[2].data.reason).toBe('drop')
        fx.teardown()
    end)

    it('picks up characters that were loaded before the agent attached', function()
        boot('A', { before = function()
            connect(4, { identifier = 'steam:abc', saved = { firstname = 'Ann', lastname = 'Lee' } })
        end })
        fx.advance(100)
        local ev = events('session.char_start')[1]
        expect(ev.data.char).toBe('steam:abc')
        expect(ev.data.char_name).toBe('Ann Lee')
        expect(ev.data.resumed).toBe(true)
        fx.teardown()
    end)
end)

describe('esx v1 money events', function()
    for _, kind in ipairs({ 'A', 'B', 'C', 'D' }) do
        it('reports add, remove and set with the right balance in layout ' .. kind, function()
            boot(kind)
            local p, s = login(4)
            s.bank = 600
            TriggerEvent('esx:addAccountMoney', 4, 'bank', 100, 'Paycheck')
            s.cash = 70
            TriggerEvent('esx:removeAccountMoney', 4, 'money', 30, 'shop')
            s.black = 40
            TriggerEvent('esx:setAccountMoney', 4, 'black_money', 40, 'admin')
            local list = events('money.change')
            expect(#list).toBe(3)
            expect(list[1].data).toEqual({ mtype = 'bank', action = 'add', amount = 100, delta = 100, balance_after = 600, reason = 'Paycheck', job_payment = 75 })
            expect(list[2].data).toEqual({ mtype = 'cash', action = 'remove', amount = 30, delta = -30, balance_after = 70, reason = 'shop', job_payment = 75 })
            expect(list[3].data).toEqual({ mtype = 'black_money', action = 'set', amount = 40, delta = 40, balance_after = 40, reason = 'admin', job_payment = 75 })
            expect(p.money).toEqual({ cash = 70, bank = 600, crypto = 0, black_money = 40 })
            fx.teardown()
        end)
    end
end)

describe('esx v1 money snapshots', function()
    it('reports delta = false', function()
        boot('A')
        expect(data().money.delta).toBe(false)
        data().money.init()
        expect(data().money.delta).toBe(false)
        fx.teardown()
    end)

    for _, kind in ipairs({ 'A', 'B', 'C', 'D' }) do
        it('refreshes online balances when no money event fired in layout ' .. kind, function()
            boot(kind)
            local p, s = login(4)
            s.cash, s.bank, s.black = 11, 22, 33
            expect(p.money.bank).toBe(500)
            data().money.init()
            expect(p.money).toEqual({ cash = 11, bank = 22, crypto = 0, black_money = 33 })
            fx.teardown()
        end)

        it('pages saved balances from the right source in layout ' .. kind, function()
            boot(kind)
            local rows, cursor, got = data().money.page(nil, nil, 2)
            expect(rows).toEqual({ { 'steam:a', 10, 100, 0 }, { 'steam:b', 20, 200, 0 } })
            expect(cursor).toBe('steam:b')
            expect(got).toBe(2)
            rows, cursor, got = data().money.page(nil, cursor, 2)
            expect(rows).toEqual({ { 'steam:c', 30, 300, 0 } })
            expect(cursor).toBe('steam:c')
            expect(got).toBe(1)
            rows, cursor, got = data().money.page(nil, cursor, 2)
            expect(rows).toEqual({})
            expect(cursor).toBeNil()
            expect(got).toBe(0)
            expect(data().money.count()).toBe(3)
            fx.teardown()
        end)
    end

    it('reads user_accounts rather than the stale columns on an upgraded server', function()
        boot('D')
        for _, r in ipairs(data().money.page(nil, nil, 10)) do
            expect(r[2] ~= 999 and r[3] ~= 999).toBe(true)
        end
        for _, sql in ipairs(world.queries) do expect(sql:find('SELECT identifier, money, bank', 1, true)).toBeNil() end
        fx.teardown()
    end)

    it('gives a holder without account rows a zero balance', function()
        boot('C')
        saveUser('steam:d')
        local rows = data().money.page(nil, 'steam:c', 5)
        expect(rows).toEqual({ { 'steam:d', 0, 0, 0 } })
        fx.teardown()
    end)

    it('survives players joining and leaving during its pauses', function()
        boot('A')
        for src = 1, 30 do login(src) end
        for src = 1, 30 do world.state[src].bank = 1000 + src end
        local done = false
        CreateThread(function() data().money.init(); done = true end)
        fx.tick()
        expect(done).toBe(false)

        local leaver -- leaver: a player the first pass of 25 has not reached yet
        for src = 1, 30 do
            if Atlas.players[src].money.bank ~= 1000 + src then leaver = src break end
        end
        expect(leaver ~= nil).toBe(true)
        local gone = Atlas.players[leaver]
        drop(leaver)
        connect(40)
        fx.advance(100)

        expect(done).toBe(true)
        expect(Atlas.players[leaver]).toBeNil()
        expect(gone.money.bank).toBeNil()
        for src = 1, 30 do
            if src ~= leaver then expect(Atlas.players[src].money.bank).toBe(1000 + src) end
        end
        fx.teardown()
    end)

    it('sends a full snapshot in pages, with live balances for online players', function()
        boot('C')
        AtlasConfig.moneyPageRows = 2
        local _, s = login(4, { identifier = 'steam:a', cash = 1, bank = 2 })
        s.cash, s.bank = 77, 88
        expect(run(function() Atlas.snapshots.money('full') end)).toBe(true)
        local pages = events('money.snapshot')
        expect(#pages).toBe(2)
        expect(pages[1].data.final).toBeNil()
        expect(pages[2].data.final).toBe(true)
        expect(pages[1].data.rows[1]).toEqual({ 'steam:a', 77, 88, 0 })
        expect(pages[2].data.rows).toEqual({ { 'steam:c', 30, 300, 0 } })
        fx.teardown()
    end)

    it('sends an empty final page when the last page was exactly full', function()
        boot('B')
        AtlasConfig.moneyPageRows = 3
        expect(run(function() Atlas.snapshots.money('full') end)).toBe(true)
        local pages = events('money.snapshot')
        expect(#pages).toBe(2)
        expect(#pages[1].data.rows).toBe(3)
        expect(pages[2].data.rows).toEqual({})
        expect(pages[2].data.final).toBe(true)
        fx.teardown()
    end)
end)

describe('esx v1 item census', function()
    local BREAD2 = '[{"count":2,"name":"bread"}]'
    local WATER3 = '[{"count":3,"name":"water"}]'

    it('groups user_inventory rows per holder and leaves zero counts out', function()
        boot('A')
        world.items[#world.items + 1] = { identifier = 'steam:a', item = 'apple', count = 4 }
        local kind = data().census()[1]
        expect(kind.kind).toBe('player')
        expect(kind.delta).toBe(false)
        expect(kind.count()).toBe(2)
        local rows, cursor, got = kind.page(nil, nil, 5)
        expect(rows).toEqual({ { 'steam:a', '[{"count":4,"name":"apple"},{"count":2,"name":"bread"}]' }, { 'steam:b', WATER3 } })
        expect(cursor).toBe('steam:b')
        expect(got).toBe(2)
        fx.teardown()
    end)

    it('pages user_inventory by holder', function()
        boot('A')
        local kind = data().census()[1]
        local rows, cursor, got = kind.page(nil, nil, 1)
        expect(rows).toEqual({ { 'steam:a', BREAD2 } })
        expect(cursor).toBe('steam:a')
        expect(got).toBe(1)
        rows, cursor, got = kind.page(nil, cursor, 1)
        expect(rows).toEqual({ { 'steam:b', WATER3 } })
        expect(got).toBe(1)
        rows, cursor, got = kind.page(nil, cursor, 1)
        expect(rows).toEqual({})
        expect(cursor).toBeNil()
        expect(got).toBe(0)
        fx.teardown()
    end)

    for _, kind in ipairs({ 'B', 'C', 'D' }) do
        it('reads and pages JSON inventories in layout ' .. kind, function()
            boot(kind)
            local census = data().census()[1]
            expect(census.count()).toBe(3)
            local rows, cursor, got = census.page(nil, nil, 2)
            expect(rows).toEqual({ { 'steam:a', BREAD2 }, { 'steam:b', WATER3 } })
            expect(cursor).toBe('steam:b')
            expect(got).toBe(2)
            rows, cursor, got = census.page(nil, cursor, 2)
            expect(rows).toEqual({ { 'steam:c', '[]' } })
            expect(cursor).toBe('steam:c')
            expect(got).toBe(1)
            rows, cursor, got = census.page(nil, cursor, 2)
            expect(rows).toEqual({})
            expect(cursor).toBeNil()
            expect(got).toBe(0)
            fx.teardown()
        end)
    end

    it('reads empty JSON inventories as empty', function()
        boot('C')
        world.users = {
            { identifier = 'steam:d', inventory = nil }, { identifier = 'steam:e', inventory = '' },
            { identifier = 'steam:f', inventory = '{}' }, { identifier = 'steam:g', inventory = '{"bread":0}' },
        }
        local rows = data().census()[1].page(nil, nil, 10)
        for i = 1, 4 do expect(rows[i][2]).toBe('[]') end
        fx.teardown()
    end)

    it('uses the JSON column and not the stale table on an upgraded server', function()
        boot('D')
        local rows = data().census()[1].page(nil, nil, 10)
        for _, r in ipairs(rows) do expect(r[2]:find('stale', 1, true)).toBeNil() end
        for _, sql in ipairs(world.queries) do expect(sql:find('user_inventory', 1, true)).toBeNil() end
        fx.teardown()
    end)

    it('sends user_inventory through a full census with a final page', function()
        boot('A')
        AtlasConfig.censusPageRows = 1
        expect(run(function() Atlas.snapshots.census('full') end)).toBe(true)
        local pages = events('items.census')
        expect(#pages).toBe(3)
        expect(pages[1].data.holder_kind).toBe('player')
        expect(pages[1].data.mode).toBe('full')
        expect(pages[1].data.rows).toEqual({ { 'steam:a', BREAD2 } })
        expect(pages[2].data.rows).toEqual({ { 'steam:b', WATER3 } })
        expect(pages[3].data.rows).toEqual({})
        expect(pages[3].data.final).toBe(true)
        fx.teardown()
    end)
end)

describe('esx v1 item ledger', function()
    for _, case in ipairs({ { 'A', 'a list' }, { 'B', 'a name to count table' }, { 'C', 'a name to count table' } }) do
        it(('reads %s in layout %s'):format(case[2], case[1]), function()
            boot(case[1])
            local p, s = login(4)
            Atlas.itemLedger.check(4)
            setItem(s, 'bread', 5)
            setItem(s, 'water', 0)
            Atlas.itemLedger.check(4)
            local created, removed = events('item.create'), events('item.remove')
            expect(#created).toBe(1)
            expect(created[1].data).toEqual({ item = 'bread', count = 3, to = { kind = 'player', id = p.char }, inferred = true })
            expect(#removed).toBe(1)
            expect(removed[1].data).toEqual({ item = 'water', count = 1, from = { kind = 'player', id = p.char }, inferred = true })
            fx.teardown()
        end)
    end
end)

describe('esx v1 deaths', function()
    local function status(src, dead, respawned) fx.client('esx_ambulancejob:setDeathStatus', src, dead, nil, respawned) end
    local function callback(src) fx.client('esx:triggerServerCallback', src, 'esx_ambulancejob:removeItemsAfterRPDeath', 1) end

    it('emits one death and ignores repeats', function()
        boot('A')
        local p = login(4)
        status(4, true)
        status(4, true)
        fx.advance(SETTLE_MS)
        status(4, true)
        expect(#events('combat.death')).toBe(1)
        expect(events('player.state')[1].data).toEqual({ key = 'isdead', value = true })
        expect(p.dead).toBe(true)
        fx.teardown()
    end)

    it('turns a cleared state into a revive after the wait', function()
        boot('A')
        local p = login(4)
        status(4, true)
        status(4, false)
        fx.advance(1000)
        expect(#events('medical.revive')).toBe(0)
        fx.advance(SETTLE_MS)
        expect(#events('medical.revive')).toBe(1)
        expect(#events('medical.respawn')).toBe(0)
        expect(p.dead).toBe(false)
        fx.teardown()
    end)

    it('turns a cleared state followed by the respawn callback into a respawn', function()
        boot('A')
        login(4)
        status(4, true)
        status(4, false)
        fx.advance(1000)
        callback(4)
        fx.advance(SETTLE_MS)
        expect(#events('medical.respawn')).toBe(1)
        expect(#events('medical.revive')).toBe(0)
        expect(events('teleport.known')[2].data.reason).toBe('respawn')
        fx.teardown()
    end)

    it('takes a true third value as a respawn at once', function()
        boot('A')
        login(4)
        status(4, true)
        status(4, false, true)
        expect(#events('medical.respawn')).toBe(1)
        fx.advance(SETTLE_MS)
        expect(#events('medical.revive')).toBe(0)
        fx.teardown()
    end)

    it('does not count a callback from outside the signal time', function()
        boot('A')
        login(4)
        status(4, true)
        callback(4)
        fx.advance(AtlasConfig.esx.deathSignalMs + 100)
        status(4, false)
        fx.advance(SETTLE_MS)
        expect(#events('medical.respawn')).toBe(0)
        expect(#events('medical.revive')).toBe(1)
        fx.teardown()
    end)

    it('ignores other server callbacks', function()
        boot('A')
        login(4)
        status(4, true)
        status(4, false)
        fx.client('esx:triggerServerCallback', 4, 'esx_shops:buy', 1)
        fx.advance(SETTLE_MS)
        expect(#events('medical.respawn')).toBe(0)
        expect(#events('medical.revive')).toBe(1)
        fx.teardown()
    end)

    it('settles a pending revive first when a new death arrives', function()
        boot('A')
        login(4)
        status(4, true)
        status(4, false)
        fx.advance(1000)
        status(4, true)
        expect(#events('medical.revive')).toBe(1)
        expect(#events('combat.death')).toBe(2)
        fx.advance(SETTLE_MS)
        expect(#events('medical.revive')).toBe(1)
        expect(Atlas.players[4].dead).toBe(true)
        fx.teardown()
    end)

    it('settles a pending respawn first when a new death arrives', function()
        boot('A')
        login(4)
        status(4, true)
        status(4, false)
        callback(4)
        fx.advance(500)
        status(4, true)
        expect(#events('medical.respawn')).toBe(1)
        expect(#events('medical.revive')).toBe(0)
        expect(#events('combat.death')).toBe(2)
        fx.advance(SETTLE_MS)
        expect(#events('medical.respawn')).toBe(1)
        expect(#events('medical.revive')).toBe(0)
        fx.teardown()
    end)

    it('emits nothing later when the player drops during the wait', function()
        boot('A')
        login(4)
        status(4, true)
        status(4, false)
        callback(4)
        drop(4)
        fx.advance(SETTLE_MS)
        expect(#events('medical.revive')).toBe(0)
        expect(#events('medical.respawn')).toBe(0)
        fx.teardown()
    end)

    it('emits nothing later when the character logs out during the wait', function()
        boot('A')
        login(4)
        status(4, true)
        status(4, false)
        TriggerEvent('esx:playerDropped', 4, 'esx_player_logout')
        fx.advance(SETTLE_MS)
        expect(#events('medical.revive')).toBe(0)
        expect(#events('medical.respawn')).toBe(0)
        fx.teardown()
    end)

    it('does not report a saved death again, and a later revive still counts', function()
        boot('A')
        login(4, { saved = { firstname = 'Ann', lastname = 'Lee', is_dead = 1 } })
        status(4, true)
        fx.advance(SETTLE_MS)
        expect(#events('combat.death')).toBe(0)
        status(4, false)
        fx.advance(SETTLE_MS)
        expect(#events('medical.revive')).toBe(1)
        expect(Atlas.players[4].down).toBe(false)
        fx.teardown()
    end)

    it('ignores players without a character and malformed values', function()
        boot('A')
        connect(9)
        status(9, true)
        login(4)
        status(4, 'yes')
        fx.advance(SETTLE_MS)
        expect(#events('combat.death')).toBe(0)
        fx.teardown()
    end)
end)

describe('esx v1 selftest', function()
    it('passes the atlas_selftest reason through setAccountMoney without changing the balance', function()
        boot('A')
        local _, s = login(4, { bank = 640 })
        Atlas.selftestMoneySeen = false
        expect(Atlas.framework.selftestMoney(4)).toBe(true)
        expect(s.calls).toEqual({ { 'bank', 640, 'atlas_selftest' } })
        expect(s.bank).toBe(640)
        expect(Atlas.selftestMoneySeen).toBe(false) -- stock v1 fires no money event of its own

        TriggerEvent('esx:setAccountMoney', 4, s.calls[1][1], s.calls[1][2], s.calls[1][3])
        expect(Atlas.selftestMoneySeen).toBe(true)
        fx.teardown()
    end)

    it('fails for a player who is not loaded', function()
        boot('A')
        expect(Atlas.framework.selftestMoney(99)).toBe(false)
        fx.teardown()
    end)
end)

describe('esx v1 configured table names', function()
    local BAD = 'users; DROP TABLE x'

    local function noBadSql()
        for _, sql in ipairs(world.queries) do expect(sql:find('DROP', 1, true)).toBeNil() end
    end

    it('warns and reads nothing for an invalid characters table', function()
        boot('A')
        AtlasConfig.esx.tables.characters = BAD
        expect(data().money.page(nil, nil, 5)).toBeNil()
        expect(data().money.count()).toBeNil()
        expect(#fx.printed('esx.tables.characters is not a valid table name') >= 1).toBe(true)
        noBadSql()
        fx.teardown()
    end)

    it('warns and reads nothing for an invalid inventory table', function()
        boot('A')
        AtlasConfig.esx.tables.inventory = BAD
        local kind = data().census()[1]
        expect(kind.page(nil, nil, 5)).toBeNil()
        expect(kind.count()).toBeNil()
        expect(#fx.printed('esx.tables.inventory is not a valid table name') >= 1).toBe(true)
        noBadSql()
        fx.teardown()
    end)

    it('warns and reads nothing for an invalid accounts table', function()
        boot('C')
        AtlasConfig.esx.tables.userAccounts = BAD
        expect(data().money.page(nil, nil, 5)).toBeNil()
        expect(#fx.printed('esx.tables.userAccounts is not a valid table name')).toBe(1)
        noBadSql()
        fx.teardown()
    end)

    it('falls back to the version when the accounts table has a name it cannot quote', function()
        boot('C', { version = '1.2.0', attachMs = 6000, before = function()
            world.columns['user-accounts'] = world.columns.user_accounts
            AtlasConfig.esx.tables.userAccounts = 'user-accounts'
        end })
        expect(Atlas.adapterActive('esx')).toBe(true)
        expect(readAs('ESX v1')).toBe(1)
        expect(#fx.printed('esx.tables.userAccounts is not a valid table name') >= 1).toBe(true)
        fx.teardown()
    end)

    it('warns and lists no jobs for an invalid jobs table', function()
        boot('A')
        AtlasConfig.esx.tables.jobs = BAD
        local jobs, gangs = data().groups()
        expect(jobs).toBeNil()
        expect(gangs).toBeNil()
        expect(#fx.printed('esx.tables.jobs is not a valid table name')).toBe(1)
        noBadSql()
        fx.teardown()
    end)
end)

describe('esx v1 groups and listeners', function()
    it('lists jobs from the jobs table, since v1 has no ESX.GetJobs', function()
        boot('A')
        local jobs, gangs = Atlas.groups()
        expect(jobs).toEqual({ ambulance = true, police = true })
        expect(gangs).toEqual({})
        fx.teardown()
    end)

    it('reads the rank again on esx:playerGroupChanged', function()
        boot('A')
        local p, s = login(4, { group = 'user' })
        expect(p.staff).toBe(false)
        s.group = 'admin'
        TriggerEvent('esx:playerGroupChanged', 4)
        expect(p.staff).toBe('admin')
        expect(events('player.staff')[1].data.role).toBe('admin')
        s.group = 'user'
        TriggerEvent('esx:playerGroupChanged', '4')
        expect(p.staff).toBe(false)
        expect(events('player.staff')[2].data.role).toBeNil()
        fx.teardown()
    end)

    it('renames the character on esx_identity:characterChanged and reports a first identity as new', function()
        boot('C')
        local p = login(4)
        TriggerEvent('esx_identity:characterChanged', { source = 4, firstname = 'Ann', lastname = 'Lee' }, true)
        expect(p.charName).toBe('Ann Lee')
        local created = events('character.create')
        expect(#created).toBe(1)
        expect(created[1].data).toEqual({ char = 'steam:p4', char_name = 'Ann Lee' })
        TriggerEvent('esx_identity:characterChanged', { source = 4, firstname = 'Bo', lastname = 'Ray' }, true)
        expect(p.charName).toBe('Bo Ray')
        expect(#events('character.create')).toBe(1)
        fx.teardown()
    end)

    it('ignores malformed identities and players without a character', function()
        boot('C')
        local p = login(4)
        connect(9)
        TriggerEvent('esx_identity:characterChanged', 'junk', true)
        TriggerEvent('esx_identity:characterChanged', { source = 4, firstname = '' }, true)
        TriggerEvent('esx_identity:characterChanged', { source = 9, firstname = 'Ann', lastname = 'Lee' }, true)
        expect(p.charName).toBeNil()
        expect(Atlas.players[9].charName).toBeNil()
        expect(#events('character.create')).toBe(0)
        fx.teardown()
    end)
end)

-- Regressions: bugs found while these tests were written.
describe('esx v1 regressions', function()
    it('keeps timed keys when a first attach read v1 from the version and a restart reads Legacy', function()
        boot('legacy', { version = '1.2.0', created = true, schemaErrors = 5, attachMs = 6000 })
        expect(readAs('ESX v1')).toBe(1)
        restart()
        expect(readAs('ESX Legacy')).toBe(1)
        expect(AtlasConfig.esx.createdColumn).toBe('created_at')
        expect(data().keys.timed()).toBe(true)
        fx.teardown()
    end)

    it('reads layout C money once rows appear in a user_accounts table that was empty at attach', function()
        boot('C', { emptyAccounts = true })
        world.accounts[1] = { identifier = 'steam:a', name = 'money', money = 10 }
        world.accounts[2] = { identifier = 'steam:a', name = 'bank', money = 100 }
        local rows = data().money.page(nil, nil, 1)
        expect(rows).toEqual({ { 'steam:a', 10, 100, 0 } })
        fx.teardown()
    end)

    it('attaches on a Legacy server whose config.lua predates the v1 table names', function()
        boot('legacy', { before = function()
            AtlasConfig.esx.tables.userAccounts = nil
            AtlasConfig.esx.tables.inventory = nil
        end })
        expect(Atlas.adapterActive('esx')).toBe(true)
        fx.teardown()
    end)

    for _, kind in ipairs({ 'A', 'B', 'C', 'D' }) do
        it('counts saved accounts the config maps into a snapshot slot in layout ' .. kind, function()
            boot(kind)
            AtlasConfig.esx.accounts.black_money = 'cash'
            AtlasConfig.esx.accounts.tokens = 'crypto'
            world.accounts[#world.accounts + 1] = { identifier = 'steam:b', name = 'tokens', money = 7 }
            local rows, cursor, got = data().money.page(nil, nil, 2)
            expect(rows).toEqual({ { 'steam:a', 15, 100, 0 }, { 'steam:b', 20, 200, 7 } })
            expect(cursor).toBe('steam:b')
            expect(got).toBe(2)
            fx.teardown()
        end)
    end

    it('does not count an account row on top of the users column of the same name', function()
        boot('A')
        world.accounts[#world.accounts + 1] = { identifier = 'steam:a', name = 'money', money = 500 }
        expect(data().money.page(nil, nil, 1)).toEqual({ { 'steam:a', 10, 100, 0 } })
        fx.teardown()
    end)

    it('reads the users columns when there is no user_accounts table', function()
        boot('A', { before = function() world.columns.user_accounts = nil end })
        local rows, cursor, got = data().money.page(nil, nil, 2)
        expect(rows).toEqual({ { 'steam:a', 10, 100, 0 }, { 'steam:b', 20, 200, 0 } })
        expect(cursor).toBe('steam:b')
        expect(got).toBe(2)
        fx.teardown()
    end)

    it('reads the layout again when es_extended restarts after a database migration', function()
        boot('A')
        expect(readAs('ESX v1')).toBe(1)
        table.insert(world.columns.users, 'accounts')
        restart()
        expect(readAs('ESX Legacy')).toBe(1)
        fx.teardown()
    end)

    it('does not reuse a late respawn callback for the next revive', function()
        boot('A')
        login(4)
        fx.client('esx_ambulancejob:setDeathStatus', 4, true)
        fx.client('esx_ambulancejob:setDeathStatus', 4, false)
        fx.advance(SETTLE_MS)
        fx.client('esx:triggerServerCallback', 4, 'esx_ambulancejob:removeItemsAfterRPDeath', 1)
        fx.client('esx_ambulancejob:setDeathStatus', 4, true)
        fx.client('esx_ambulancejob:setDeathStatus', 4, false)
        fx.advance(SETTLE_MS)
        expect(#events('medical.respawn')).toBe(0)
        expect(#events('medical.revive')).toBe(2)
        fx.teardown()
    end)
end)
