local fx = load_module('tests/fivem.lua')

-- Stacks copied from FXServer: QBCore, Qbox and ESX with a paying script, then ESX with ox_inventory and a move in the inventory window.
local QB = '^3> handler^7 (^5@atlas-agent/server/adapters/qbcore.lua^7:131)\n> [global chunk] (@qb-core/server/player.lua:204)\n> [global chunk] (@lab_shop/s.lua:21)\n> step (@lab_shop/s.lua:5)\n> fn (@lab_shop/s.lua:21)\n'
local QBX = '> handler (@atlas-agent/server/adapters/qbox.lua:71)\n> emitMoneyEvents (@qbx_core/server/player.lua:1402)\n> ref (@qbx_core/server/player.lua:1469)\n> [global chunk] (@lab_shop/s.lua:13)\n'
local ESX_OX = '> handler (@atlas-agent/server/adapters/esx.lua:250)\n> ref (@es_extended/server/classes/overrides/oxinventory.lua:501)\n> syncInventory (@ox_inventory/modules/bridge/esx/server.lua:84)\n> ref (@ox_inventory/modules/inventory/server.lua:1213)\n> [global chunk] (@lab_shop/s.lua:28)\n'
local WINDOW = '> handler (@atlas-agent/server/adapters/qbox.lua:71)\n> emitMoneyEvents (@qbx_core/server/player.lua:1402)\n> syncInventory (@ox_inventory/modules/bridge/qbx/server.lua:75)\n> fn (@ox_inventory/modules/inventory/server.lua:2031)\n> cb (citizen:/scripting/lua/scheduler.lua:12)\n'
local PAYCHECK = '> handler (@atlas-agent/server/adapters/qbcore.lua:131)\n> AddMoney (@qb-core/server/player.lua:204)\n> PaycheckInterval (@qb-core/server/functions.lua:88)\n'
local COMMAND = '> handler (@atlas-agent/server/adapters/qbox.lua:71)\n> AddMoney (@qbx_core/server/player.lua:1469)\n> fn (@qbx_core/server/commands.lua:244)\n> cb (@ox_lib/imports/addCommand/server.lua:90)\n'
local THROUGH_LIB = '> handler (@atlas-agent/server/adapters/esx.lua:250)\n> ref (@es_extended/server/classes/player.lua:300)\n> cb (@ox_lib/imports/callback/server.lua:50)\n> fn (@job_taxi/server/main.lua:7)\n'

local CORE = { ['qb-core'] = 'framework', qbx_core = 'framework', es_extended = 'framework', ox_inventory = 'inventory' }
local LIBS = { ['atlas-agent'] = true, ox_lib = true }

describe('caller', function()
    local caller = load_module('server/lib/caller.lua')
    local function check(text, res, origin, kind)
        local r, o, k = caller.pick(caller.frames(text), CORE, LIBS)
        expect(r).toBe(res)
        expect(o).toBe(origin)
        expect(k).toBe(kind)
    end

    it('reads frames newest first, past colour codes and runtime frames', function()
        local f = caller.frames(WINDOW)
        expect(#f).toBe(4)
        expect(f[1].res).toBe('atlas-agent')
        expect(f[4]).toEqual({ res = 'ox_inventory', path = 'modules/inventory/server.lua', line = 2031 })
        expect(caller.frames(QB)[1].res).toBe('atlas-agent')
        expect(#caller.frames(nil)).toBe(0)
    end)

    it('names the script that asked the framework for the money', function()
        check(QB, 'lab_shop', 's.lua:21', 'script')
        check(QBX, 'lab_shop', 's.lua:13', 'script')
    end)

    it('reads past the inventory when a script paid with a money item', function()
        check(ESX_OX, 'lab_shop', 's.lua:28', 'script')
    end)

    it('reads past a library that carried the call', function()
        check(THROUGH_LIB, 'job_taxi', 'server/main.lua:7', 'script')
    end)

    it('says the inventory did it when a player moved cash in the window', function()
        check(WINDOW, 'ox_inventory', 'modules/inventory/server.lua:2031', 'inventory')
    end)

    it('says the framework did it for its own paycheck loop', function()
        check(PAYCHECK, 'qb-core', 'server/functions.lua:88', 'framework')
    end)

    it('recognises a staff command in a core resource', function()
        check(COMMAND, 'qbx_core', 'server/commands.lua:244', 'staff_command')
    end)

    it('says nothing when the stack holds only the agent', function()
        check('> handler (@atlas-agent/server/core.lua:1)\n', nil, nil, nil)
    end)
end)

describe('attribution', function()
    local function boot(convars)
        convars = convars or {}
        convars['atlas:token'] = 'atl_live_x'
        fx.boot({ convars = convars, load = { 'server/adapters/detect.lua', 'server/sources.lua', 'server/framework.lua', 'server/characters.lua', 'server/staff.lua', 'server/money.lua' } })
        fx.addPlayer(4, {})
        Atlas.ensurePlayer(4)
        Atlas.characters.load(4, { char = 'C1', money = { cash = 100, bank = 500 } })
        Atlas.framework = { name = 'qbcore', resources = { 'qb-core' } }
    end
    local function moneyEvents()
        Atlas.jsReady = true
        Atlas.flush()
        local out = {}
        for _, call in ipairs(fx.triggered('atlas:internal:batch')) do
            for _, ev in ipairs(call[1]) do
                if ev.type == 'money.change' then out[#out + 1] = ev end
            end
        end
        return out
    end

    it('puts the script on the money change, with its file and line', function()
        boot()
        fx.state.stack = QB
        Atlas.money.change(4, 'bank', 'add', 50, 550, 'unknown')
        local ev = moneyEvents()[1]
        expect(ev.res).toBe('lab_shop')
        expect(ev.data.origin).toBe('s.lua:21')
        expect(ev.data.caller).toBe('script')
        fx.teardown()
    end)

    it('sends the change without a script when no stack is available, and counts that', function()
        boot()
        fx.state.stack = nil
        Atlas.money.change(4, 'bank', 'add', 50, 550, 'unknown')
        local ev = moneyEvents()[1]
        expect(ev.res).toBeNil()
        expect(ev.data.amount).toBe(50)
        expect(Atlas.drops.attribution_no_stack).toBe(1)
        fx.teardown()
    end)

    it('can be switched off', function()
        boot({ ['atlas:attribute'] = 0 })
        fx.state.stack = QB
        Atlas.money.change(4, 'bank', 'add', 50, 550, 'unknown')
        expect(moneyEvents()[1].res).toBeNil()
        fx.teardown()
    end)
end)

describe('item ledger', function()
    local L
    local function boot()
        fx.boot({ convars = { ['atlas:token'] = 'atl_live_x' } })
        L = Atlas.itemLedger
    end

    it('finds what no adapter reported and ignores what one did', function()
        boot()
        local d = L.residual({ water = 5, bread = 1 }, { water = 3, fish = 2 }, { water = -1 })
        expect(d).toEqual({ water = -1, fish = 2, bread = -1 })
        fx.teardown()
    end)

    it('leaves fractions of durability alone', function()
        boot()
        expect(L.residual({ water = 5 }, { water = 5 }, { water = -0.2 })).toEqual({})
        fx.teardown()
    end)

    it('only sets the starting point for a new character', function()
        boot()
        fx.addPlayer(4, {})
        Atlas.ensurePlayer(4)
        Atlas.setChar(4, 'C1', 'One')
        local now = { water = 5 }
        L.use(function() return now end)
        L.check(4)
        Atlas.setChar(4, 'C2', 'Two')
        now = { water = 1 }
        L.check(4)
        Atlas.jsReady = true
        Atlas.flush()
        expect(#fx.triggered('atlas:internal:batch')).toBe(0)
        fx.teardown()
    end)
end)
