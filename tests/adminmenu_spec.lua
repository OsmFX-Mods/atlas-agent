local fx = load_module('tests/fivem.lua')

local optin -- optin: the qbx_core admin messages setting by server id

local function boot(files)
    optin = {}
    fx.boot({
        convars = { ['atlas:token'] = 'atl_live_x' },
        resources = { ['qb-adminmenu'] = 'started', ['qbx_adminmenu'] = 'started' },
        provided = { qbx_core = { IsOptin = function(_, src) return optin[src] ~= false end } },
        files = files or {},
        load = {
            'server/adapters/detect.lua', 'server/sources.lua', 'server/framework.lua', 'server/characters.lua', 'server/staff.lua',
            'server/money.lua', 'server/adapters/natives.lua', 'server/adapters/qb_adminmenu.lua', 'server/adapters/qbx_adminmenu.lua',
        },
    })
    fx.advance(1500)
    local aces = { [1] = { god = true, admin = true, mod = true }, [2] = { mod = true }, [3] = {} }
    for src = 1, 4 do
        fx.addPlayer(src, { name = 'P' .. src, aces = aces[src] or {} })
        Atlas.ensurePlayer(src)
        Atlas.setChar(src, 'CID' .. src, 'Char ' .. src)
    end
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

describe('qb-adminmenu', function()
    it('records staff actions and sends goto and bring as admin teleports of the player who moved', function()
        boot()
        fx.net('qb-admin:server:revive', 1, { id = 4 })
        fx.net('qb-admin:server:ban', 1, { id = 4 }, 3600, 'cheating')
        fx.net('qb-admin:server:goto', 1, { id = 4 })
        fx.net('qb-admin:server:bring', 1, { id = 4 })
        local acts = events('admin.action')
        expect(#acts).toBe(2)
        expect(acts[1].data.action).toBe('revive')
        expect(acts[1].data.target_char).toBe('CID4')
        expect(acts[1].data.by).toBe('P1')
        expect(acts[2].data.detail).toBe('cheating')
        local tps = events('admin.teleport')
        expect(#tps).toBe(2)
        expect(tps[1].actor.char).toBe('CID1')
        expect(tps[1].data.target_char).toBe('CID4')
        expect(tps[2].actor.char).toBe('CID4')
        expect(#events('teleport.known')).toBe(0)
        fx.teardown()
    end)

    it('ignores a request the menu refuses: no admin rank, or god needed for permissions', function()
        boot()
        fx.net('qb-admin:server:goto', 3, { id = 4 })
        fx.net('qb-admin:server:kill', 2, { id = 4 })
        fx.net('qb-admin:server:setPermissions', 2, 4, { { rank = 'admin' } })
        fx.net('qb-admin:server:setPermissions', 1, 4, { { rank = 'admin' } })
        local acts = events('admin.action')
        expect(#acts).toBe(1)
        expect(acts[1].data.action).toBe('set permission')
        expect(acts[1].data.detail).toBe('admin')
        expect(#events('admin.teleport')).toBe(0)
        fx.teardown()
    end)
end)

describe('qbx_adminmenu', function()
    it('maps the menu options in order and checks the configured permission and opt-in', function()
        boot({ ['qbx_adminmenu/config/server.lua'] = "return { eventPerms = { playerOptionsGeneral = 'mod', kick = 'admin', ban = 'admin' } }" })
        fx.net('qbx_admin:server:playerOptionsGeneral', 2, 2, { id = 4 })
        fx.net('qbx_admin:server:playerOptionsGeneral', 2, 5, { id = 4 })
        fx.net('qbx_admin:server:playerAdministration', 2, 1, { id = 4 }, 'afk')
        fx.net('qbx_admin:server:playerAdministration', 1, 2, { id = 4 }, { 'cheating', 0, 1, 0 })
        optin[1] = false
        fx.net('qbx_admin:server:playerOptionsGeneral', 1, 1, { id = 4 })
        local acts = events('admin.action')
        expect(#acts).toBe(2)
        expect(acts[1].data.action).toBe('revive')
        expect(acts[2].data.action).toBe('ban')
        expect(acts[2].data.detail).toBe('cheating')
        local tps = events('admin.teleport')
        expect(#tps).toBe(1)
        expect(tps[1].data.action).toBe('bring')
        expect(tps[1].actor.char).toBe('CID4')
        fx.teardown()
    end)
end)
