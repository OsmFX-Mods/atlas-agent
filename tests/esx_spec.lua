local fx = load_module('tests/fivem.lua')

local state -- state: the fake ESX world: live players, jobs and death flags

local function newPlayer(src, over)
    local x = {
        source = src, identifier = 'char1:abc' .. src, variables = { firstName = 'Ann', lastName = 'Lee' },
        job = { name = 'police', grade = 2, onDuty = true },
        accounts = { money = 100, bank = 500, black_money = 0 },
    }
    for k, v in pairs(over or {}) do x[k] = v end
    x.getJob = function() return x.job end
    x.getAccounts = function()
        local copy = {}
        for k, v in pairs(x.accounts) do copy[k] = v end
        return copy
    end
    x.getAccount = function(name) return { name = name, money = x.accounts[name] } end
    x.setAccountMoney = function(name, money, reason)
        x.accounts[name] = money
        TriggerEvent('esx:setAccountMoney', src, name, money, reason)
    end
    state.players[src] = x
    return x
end

local function boot(over)
    state = { players = {}, jobs = { police = {}, ambulance = {} }, dead = {}, objectError = false, lookups = 0, objectCalls = 0 }
    local ESX = {
        GetPlayerFromId = function(src)
            state.lookups = state.lookups + 1
            return state.players[src]
        end,
        GetJobs = function() return state.jobs end,
    }
    fx.boot({
        convars = { ['atlas:token'] = 'atl_live_x' },
        resources = { es_extended = 'started' },
        provided = { es_extended = {
            getSharedObject = function()
                state.objectCalls = state.objectCalls + 1
                if state.objectError then error('not ready') end
                return ESX
            end,
            -- Static export: present in newer ESX versions; state.static turns it on for a spec
            RunStaticPlayerMethod = function(_, src, method, ...)
                if not state.static then error('No such export RunStaticPlayerMethod in resource es_extended') end
                local x = state.players[src]
                if x then return x[method](...) end
            end,
        } },
        load = {
            'server/db.lua', 'server/adapters/detect.lua', 'server/sources.lua', 'server/framework.lua',
            'server/characters.lua', 'server/money.lua', 'server/adapters/esx_data.lua', 'server/adapters/esx.lua',
            'server/adapters/esx_death.lua',
        },
    })
    fx.set('Player', function(src) return { state = { isDead = state.dead[src] } } end)
    state.db = { rows = {}, scalar = nil }
    Atlas.db.available = function() return true end
    Atlas.db.query = function() return state.db.rows end
    Atlas.db.scalar = function() return state.db.scalar end
    if over then over() end
    fx.advance(200)
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

local function login(src, over, isNew)
    fx.addPlayer(src, { ped = { x = 10.0, y = 10.0, z = 30.0, h = 0.0 } })
    Atlas.ensurePlayer(src)
    local x = newPlayer(src, over)
    TriggerEvent('esx:playerLoaded', src, x, isNew == true)
    return x, Atlas.players[src]
end

-- ESX with ox_inventory: an account item change is first copied to the account (a set with the sync reason), then reported as the real add or remove.
local function oxAdd(x, account, amount, reason)
    x.accounts[account] = x.accounts[account] + amount
    TriggerEvent('esx:setAccountMoney', x.source, account, x.accounts[account], 'Sync account with item')
    TriggerEvent('esx:addAccountMoney', x.source, account, amount, reason)
end

local function oxRemove(x, account, amount, reason)
    x.accounts[account] = x.accounts[account] - amount
    TriggerEvent('esx:setAccountMoney', x.source, account, x.accounts[account], 'Sync account with item')
    TriggerEvent('esx:removeAccountMoney', x.source, account, amount, reason)
end

describe('esx adapter attach', function()
    it('registers as the framework and attaches when es_extended is started', function()
        boot()
        expect(Atlas.adapterActive('esx')).toBe(true)
        expect(Atlas.framework.name).toBe('esx')
        expect(Atlas.charFallback).toBe(false)
        fx.teardown()
    end)

    it('retries while es_extended is not ready', function()
        boot(function() state.objectError = true end)
        expect(Atlas.adapterActive('esx')).toBe(false)
        state.objectError = false
        fx.advance(2000)
        expect(Atlas.adapterActive('esx')).toBe(true)
        fx.teardown()
    end)

    it('is not used when another framework is selected', function()
        fx.boot({
            convars = { ['atlas:token'] = 'atl_live_x', ['atlas:framework'] = 'qbox' }, resources = { es_extended = 'started' },
            provided = { es_extended = { getSharedObject = function() return {} end } },
            load = { 'server/db.lua', 'server/adapters/detect.lua', 'server/sources.lua', 'server/framework.lua',
                'server/characters.lua', 'server/money.lua', 'server/adapters/esx_data.lua', 'server/adapters/esx.lua' },
        })
        fx.advance(200)
        expect(Atlas.adapterActive('esx')).toBe(false)
        TriggerEvent('esx:playerLoaded', 4, { identifier = 'x' }, false)
        expect(Atlas.players[4]).toBeNil()
        fx.teardown()
    end)

    it('picks up characters that were loaded before the agent started', function()
        fx.boot({
            convars = { ['atlas:token'] = 'atl_live_x' }, resources = { es_extended = 'started' },
            provided = { es_extended = { getSharedObject = function()
                return { GetPlayerFromId = function(src) return state.players[src] end }
            end } },
            load = { 'server/db.lua', 'server/adapters/detect.lua', 'server/sources.lua', 'server/framework.lua',
                'server/characters.lua', 'server/money.lua', 'server/adapters/esx_data.lua', 'server/adapters/esx.lua' },
        })
        state = { players = {}, dead = {} }
        fx.addPlayer(4, { ped = { x = 1.0, y = 1.0, z = 1.0 } })
        Atlas.ensurePlayer(4)
        newPlayer(4)
        fx.advance(2000)
        local ev = events('session.char_start')[1]
        expect(ev.data.char).toBe('char1:abc4')
        expect(ev.data.resumed).toBe(true)
        expect(#events('teleport.known')).toBe(0)
        fx.teardown()
    end)
end)

describe('esx character lifecycle', function()
    it('loads identity and sends session.char_start with the actor details', function()
        boot()
        local _, p = login(4)
        local ev = events('session.char_start')[1]
        expect(ev.data.char).toBe('char1:abc4')
        expect(ev.data.char_name).toBe('Ann Lee')
        expect(ev.data.job).toBe('police')
        expect(ev.data.is_new_char).toBe(false)
        expect(p.actor.grade).toBe(2)
        expect(p.actor.duty).toBe(true)
        expect(p.money).toEqual({ cash = 100, bank = 500, crypto = 0 })
        expect(events('teleport.known')[1].data.reason).toBe('spawn')
        fx.teardown()
    end)

    it('adds character.create for a new character', function()
        boot()
        login(4, nil, true)
        expect(events('character.create')[1].data.char).toBe('char1:abc4')
        expect(events('session.char_start')[1].data.is_new_char).toBe(true)
        fx.teardown()
    end)

    it('leaves the character name empty when ESX has no first name', function()
        boot()
        local _, p = login(4, { variables = {} })
        expect(events('session.char_start')[1].data.char_name).toBeNil()
        expect(p.actor.name).toBe('Player4')
        fx.teardown()
    end)

    it('counts black money in the cash slot', function()
        boot()
        local _, p = login(4, { accounts = { money = 100, bank = 500, black_money = 40 } })
        expect(p.money.cash).toBe(140)
        fx.teardown()
    end)

    it('starts a character that was dead when it loaded as down', function()
        boot()
        fx.addPlayer(4, {})
        Atlas.ensurePlayer(4)
        state.dead[4] = true
        TriggerEvent('esx:playerLoaded', 4, newPlayer(4), false)
        expect(Atlas.players[4].down).toBe(true)
        expect(#events('combat.death')).toBe(0)
        fx.teardown()
    end)

    it('ignores a repeated load and ends the old character on a switch', function()
        boot()
        local x = login(4)
        TriggerEvent('esx:playerLoaded', 4, x, false)
        expect(#events('session.char_start')).toBe(1)
        TriggerEvent('esx:playerLoaded', 4, newPlayer(4, { identifier = 'char2:abc' }), false)
        local ends = events('session.char_end')
        expect(#ends).toBe(1)
        expect(ends[1].data.reason).toBe('switch')
        expect(Atlas.charOf(4)).toBe('char2:abc')
        fx.teardown()
    end)

    it('rejects malformed load events', function()
        boot()
        fx.addPlayer(4, {})
        Atlas.ensurePlayer(4)
        TriggerEvent('esx:playerLoaded', 4, 'junk', false)
        TriggerEvent('esx:playerLoaded', 4, { identifier = '' }, false)
        TriggerEvent('esx:playerLoaded', 'x', { identifier = 'a' }, false)
        expect(#events('session.char_start')).toBe(0)
        fx.teardown()
    end)

    it('reports a logout to the character screen and a disconnect differently', function()
        boot()
        local _, p = login(4)
        TriggerEvent('esx:playerDropped', 4, 'esx_player_logout')
        expect(events('session.char_end')[1].data.reason).toBe('logout')
        expect(p.char).toBeNil()
        login(5)
        TriggerEvent('esx:playerDropped', 5, 'Disconnected.')
        expect(events('session.char_end')[2].data.reason).toBe('drop')
        fx.teardown()
    end)

    it('ends the character once when both the drop and the ESX event arrive', function()
        boot()
        login(4)
        Atlas.runDrop(Atlas.players[4], 'quit')
        TriggerEvent('esx:playerDropped', 4, 'Disconnected.')
        expect(#events('session.char_end')).toBe(1)
        fx.teardown()
    end)
end)

describe('esx jobs', function()
    it('emits job.change when the job or grade changes', function()
        boot()
        local _, p = login(4)
        TriggerEvent('esx:setJob', 4, { name = 'ambulance', grade = 1, onDuty = true }, { name = 'police' })
        expect(events('job.change')[1].data).toEqual({ from = { job = 'police', grade = 2 }, to = { job = 'ambulance', grade = 1 } })
        expect(p.actor.job).toBe('ambulance')
        TriggerEvent('esx:setJob', 4, { name = 'ambulance', grade = 3, onDuty = true }, { name = 'ambulance' })
        expect(#events('job.change')).toBe(2)
        fx.teardown()
    end)

    it('emits duty.change when only duty flips and nothing when the job is refreshed', function()
        boot()
        login(4)
        TriggerEvent('esx:setJob', 4, { name = 'police', grade = 2, onDuty = true }, { name = 'police' })
        expect(#events('job.change') + #events('duty.change')).toBe(0)
        TriggerEvent('esx:setJob', 4, { name = 'police', grade = 2, onDuty = false }, { name = 'police' })
        local duty = events('duty.change')
        expect(#duty).toBe(1)
        expect(duty[1].data).toEqual({ job = 'police', on = false })
        expect(#events('job.change')).toBe(0)
        fx.teardown()
    end)

    it('keeps duty for a version that does not send it', function()
        boot()
        local _, p = login(4)
        TriggerEvent('esx:setJob', 4, { name = 'ambulance', grade = 0 }, { name = 'police' })
        expect(p.duty).toBe(true)
        expect(#events('duty.change')).toBe(0)
        fx.teardown()
    end)

    it('ignores a job event for a player without a character', function()
        boot()
        fx.addPlayer(4, {})
        Atlas.ensurePlayer(4)
        TriggerEvent('esx:setJob', 4, { name = 'x', grade = 0 }, {})
        TriggerEvent('esx:setJob', 4, 'junk', {})
        expect(#events('job.change')).toBe(0)
        fx.teardown()
    end)
end)

describe('esx shared object and items', function()
    it('fetches the shared object once and again after es_extended stops', function()
        boot()
        Atlas.groups()
        Atlas.groups()
        expect(state.objectCalls).toBe(1)
        TriggerEvent('onResourceStop', 'es_extended')
        TriggerEvent('onResourceStart', 'es_extended')
        fx.advance(200)
        expect(Atlas.adapterActive('esx')).toBe(true)
        expect(state.objectCalls).toBe(2)
        fx.teardown()
    end)

    it('sends the items table as the catalog without ox_inventory', function()
        boot(function() state.db.rows = { { name = 'bread', label = 'Bread', weight = 1 } } end)
        expect(events('items.catalog')[1].data.entries).toEqual({ { 'bread', 'Bread', 1 } })
        fx.teardown()
    end)

    it('leaves the item catalog to ox_inventory when it is installed but starts later', function()
        boot(function()
            fx.state.resources.ox_inventory = 'stopped'
            state.db.rows = { { name = 'bread', label = 'Bread', weight = 1 } }
        end)
        expect(#events('items.catalog')).toBe(0)
        fx.teardown()
    end)
end)

describe('esx money', function()
    it('reads live balances through the static export instead of copying the player', function()
        boot(function() state.static = true end)
        local x = login(4)
        state.lookups = 0
        x.accounts.bank = 600
        TriggerEvent('esx:addAccountMoney', 4, 'bank', 100, 'Paycheck')
        local ev = events('money.change')[1]
        expect(ev.data.balance_after).toBe(600)
        expect(ev.data.delta).toBe(100)
        expect(state.lookups).toBe(0)
        fx.teardown()
    end)

    it('falls back to the player object when the static export is missing', function()
        boot()
        local x = login(4)
        state.lookups = 0
        x.accounts.bank = 600
        TriggerEvent('esx:addAccountMoney', 4, 'bank', 100, 'Paycheck')
        expect(events('money.change')[1].data.balance_after).toBe(600)
        expect(state.lookups).toBe(1)
        fx.teardown()
    end)

    it('emits an add and a remove with the balance after the change', function()
        boot()
        local x = login(4)
        x.accounts.bank = 600
        TriggerEvent('esx:addAccountMoney', 4, 'bank', 100, 'Paycheck')
        x.accounts.bank = 550
        TriggerEvent('esx:removeAccountMoney', 4, 'bank', 50, 'rent')
        local list = events('money.change')
        expect(list[1].data).toEqual({ mtype = 'bank', action = 'add', amount = 100, delta = 100, balance_after = 600, reason = 'Paycheck' })
        expect(list[2].data.delta).toBe(-50)
        expect(list[2].data.balance_after).toBe(550)
        expect(list[2].data.reason).toBe('rent')
        fx.teardown()
    end)

    it('reports reasons ESX fills in as unknown', function()
        boot()
        local x = login(4)
        x.accounts.money = 101
        TriggerEvent('esx:addAccountMoney', 4, 'money', 1, 'Unknown')
        x.accounts.money = 102
        TriggerEvent('esx:addAccountMoney', 4, 'money', 1, nil)
        x.accounts.money = 103
        TriggerEvent('esx:addAccountMoney', 4, 'money', 1, 'unknown')
        for _, ev in ipairs(events('money.change')) do expect(ev.data.reason).toBe('unknown') end
        fx.teardown()
    end)

    it('works out a set from the last known balance', function()
        boot()
        local x = login(4)
        x.accounts.bank = 900
        TriggerEvent('esx:setAccountMoney', 4, 'bank', 900, 'admin')
        local ev = events('money.change')[1]
        expect(ev.data.action).toBe('set')
        expect(ev.data.delta).toBe(400)
        expect(Atlas.players[4].money.bank).toBe(900)
        fx.teardown()
    end)

    it('matches account names without regard to case and skips accounts that are not tracked', function()
        boot()
        local x = login(4)
        x.accounts.bank = 510
        TriggerEvent('esx:addAccountMoney', 4, 'Bank', 10, 'x')
        TriggerEvent('esx:addAccountMoney', 4, 'tokens', 10, 'x')
        local list = events('money.change')
        expect(#list).toBe(1)
        expect(list[1].data.mtype).toBe('bank')
        fx.teardown()
    end)

    it('counts black money in the cash slot and keeps the slot balance', function()
        boot()
        local x = login(4)
        x.accounts.black_money = 30
        TriggerEvent('esx:addAccountMoney', 4, 'black_money', 30, 'drug sale')
        local ev = events('money.change')[1]
        expect(ev.data.mtype).toBe('cash')
        expect(ev.data.balance_after).toBe(130)
        expect(Atlas.players[4].money.cash).toBe(130)
        fx.teardown()
    end)

    it('follows a renamed account mapping from the config', function()
        boot()
        AtlasConfig.esx.accounts = { money = 'cash', bank = 'bank', tokens = 'crypto' }
        local x = login(4)
        x.accounts.tokens = 5
        TriggerEvent('esx:addAccountMoney', 4, 'tokens', 5, 'x')
        expect(events('money.change')[1].data.mtype).toBe('crypto')
        fx.teardown()
    end)

    it('ignores malformed events', function()
        boot()
        login(4)
        TriggerEvent('esx:addAccountMoney', 4, 'bank', 'x', 'r')
        TriggerEvent('esx:addAccountMoney', nil, 'bank', 5, 'r')
        TriggerEvent('esx:addAccountMoney', 4, nil, 5, 'r')
        expect(#events('money.change')).toBe(0)
        fx.teardown()
    end)

    it('reports a change once when ox_inventory copies it to the account first', function()
        boot()
        local x = login(4)
        oxAdd(x, 'money', 50, 'sale')
        fx.advance(100)
        local list = events('money.change')
        expect(#list).toBe(1)
        expect(list[1].data.action).toBe('add')
        expect(list[1].data.delta).toBe(50)
        expect(list[1].data.reason).toBe('sale')
        expect(Atlas.players[4].money.cash).toBe(150)
        fx.teardown()
    end)

    it('reports a removal once when ox_inventory copies it to the account first', function()
        boot()
        local x = login(4)
        oxRemove(x, 'money', 30, 'fine')
        fx.advance(100)
        local list = events('money.change')
        expect(#list).toBe(1)
        expect(list[1].data.action).toBe('remove')
        expect(list[1].data.delta).toBe(-30)
        fx.teardown()
    end)

    it('reports several changes in one frame one by one', function()
        boot()
        local x = login(4)
        oxAdd(x, 'money', 10, 'a')
        oxAdd(x, 'money', 20, 'b')
        oxRemove(x, 'money', 5, 'c')
        fx.advance(100)
        local list = events('money.change')
        expect(#list).toBe(3)
        expect(list[1].data.balance_after).toBe(110)
        expect(list[2].data.balance_after).toBe(130)
        expect(list[3].data.balance_after).toBe(125)
        fx.teardown()
    end)

    it('sends a move made in the ox_inventory window as a set with its own time and delta', function()
        boot()
        local x = login(4)
        x.accounts.money = 70
        local at = Atlas.now()
        TriggerEvent('esx:setAccountMoney', 4, 'money', 70, 'Sync account with item')
        expect(#events('money.change')).toBe(0)
        fx.advance(200)
        local list = events('money.change')
        expect(#list).toBe(1)
        expect(list[1].data.action).toBe('set')
        expect(list[1].data.delta).toBe(-30)
        expect(list[1].data.reason).toBe('Sync account with item')
        expect(list[1].ts).toBe(at)
        fx.teardown()
    end)

    it('sends the held set and the real event when their balances differ', function()
        boot()
        local x = login(4)
        x.accounts.money = 70
        TriggerEvent('esx:setAccountMoney', 4, 'money', 70, 'Sync account with item')
        x.accounts.money = 90
        TriggerEvent('esx:addAccountMoney', 4, 'money', 20, 'sale')
        local list = events('money.change')
        expect(#list).toBe(2)
        expect(list[1].data.action).toBe('set')
        expect(list[2].data.action).toBe('add')
        fx.teardown()
    end)

    it('sends a held set before the character ends', function()
        boot()
        local x = login(4)
        x.accounts.money = 70
        TriggerEvent('esx:setAccountMoney', 4, 'money', 70, 'Sync account with item')
        TriggerEvent('esx:playerDropped', 4, 'esx_player_logout')
        fx.advance(100)
        local money = events('money.change')
        expect(#money).toBe(1)
        expect(money[1].actor.char).toBe('char1:abc4')
        expect(money[1].seq < events('session.char_end')[1].seq).toBe(true)
        fx.teardown()
    end)

    it('measures an explicit set that follows a sync from the balance before the sync', function()
        boot()
        local x = login(4)
        x.accounts.money = 160
        TriggerEvent('esx:setAccountMoney', 4, 'money', 160, 'Sync account with item')
        TriggerEvent('esx:setAccountMoney', 4, 'money', 160, 'admin')
        local list = events('money.change')
        expect(#list).toBe(1)
        expect(list[1].data.reason).toBe('admin')
        expect(list[1].data.delta).toBe(60)
        fx.teardown()
    end)

    it('lets the selftest reach the money hook', function()
        boot()
        login(4)
        Atlas.selftestMoneySeen = false
        expect(Atlas.framework.selftestMoney(4)).toBe(true)
        expect(Atlas.selftestMoneySeen).toBe(true)
        expect(Atlas.framework.selftestMoney(99)).toBe(false)
        fx.teardown()
    end)
end)

describe('esx death', function()
    local function death(src, dead, reason) TriggerEvent('esx_death:stateChanged', src, dead, reason) end

    local function bootDeath()
        fx.boot({
            convars = { ['atlas:token'] = 'atl_live_x' }, resources = { es_extended = 'started', esx_death = 'started' },
            provided = { es_extended = { getSharedObject = function()
                return { GetPlayerFromId = function(src) return state.players[src] end }
            end } },
            load = { 'server/db.lua', 'server/adapters/detect.lua', 'server/sources.lua', 'server/framework.lua',
                'server/characters.lua', 'server/money.lua', 'server/adapters/esx_data.lua', 'server/adapters/esx.lua',
                'server/adapters/esx_death.lua' },
        })
        state = { players = {}, dead = {} }
        fx.advance(200)
    end

    it('emits combat.death and player.state when the character dies', function()
        bootDeath()
        login(4)
        death(4, true, 'death')
        expect(events('combat.death')[1].data.state).toBe('dead')
        local st = events('player.state')[1]
        expect(st.data).toEqual({ key = 'isdead', value = true })
        expect(Atlas.players[4].dead).toBe(true)
        fx.teardown()
    end)

    it('emits medical.revive when the character is revived', function()
        bootDeath()
        login(4)
        death(4, true, 'death')
        death(4, false, 'revive')
        expect(#events('medical.revive')).toBe(1)
        expect(Atlas.players[4].dead).toBe(false)
        fx.teardown()
    end)

    it('emits medical.respawn but no revive for a hospital respawn', function()
        bootDeath()
        login(4)
        death(4, true, 'death')
        death(4, false, 'respawn')
        expect(#events('medical.respawn')).toBe(1)
        expect(#events('medical.revive')).toBe(0)
        fx.teardown()
    end)

    it('does not report a restored death as a new one', function()
        bootDeath()
        login(4)
        death(4, true, 'restore')
        expect(#events('combat.death')).toBe(0)
        expect(Atlas.players[4].down).toBe(true)
        death(4, false, 'admin')
        expect(#events('medical.revive')).toBe(1)
        fx.teardown()
    end)

    it('ignores the logout flip and players without a character', function()
        bootDeath()
        login(4)
        death(4, true, 'death')
        death(4, false, 'logout')
        expect(#events('medical.revive')).toBe(0)
        death(9, true, 'death')
        expect(#events('combat.death')).toBe(1)
        fx.teardown()
    end)

    it('does nothing while ESX is not the framework', function()
        fx.boot({
            convars = { ['atlas:token'] = 'atl_live_x' }, resources = { esx_death = 'started' },
            load = { 'server/adapters/detect.lua', 'server/sources.lua', 'server/framework.lua', 'server/characters.lua',
                'server/adapters/esx_death.lua' },
        })
        fx.advance(200)
        fx.addPlayer(4, {})
        Atlas.ensurePlayer(4)
        Atlas.characters.load(4, { char = 'x' })
        death(4, true, 'death')
        expect(#events('combat.death')).toBe(0)
        fx.teardown()
    end)
end)
