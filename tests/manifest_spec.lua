local fx = load_module('tests/fivem.lua')

--- Manifest scripts: the server Lua files in the order fxmanifest.lua lists them.
local function manifestScripts()
    local f = assert(io.open('fxmanifest.lua', 'r'))
    local text = f:read('a')
    f:close()
    local block = text:match('server_scripts%s*(%b{})')
    local out = {}
    for path in block:gmatch("'([^']+%.lua)'") do out[#out + 1] = path end
    return out
end

local function loadOrder()
    local out = {}
    -- Shared by every boot: the stub already loads these first
    local preloaded = { ['config.lua'] = true, ['server/core.lua'] = true }
    for _, path in ipairs(manifestScripts()) do
        if not preloaded[path] and not path:find('^server/lib/') then out[#out + 1] = path end
    end
    return out
end

describe('manifest load order', function()
    it('loads every server script in the order the manifest lists them', function()
        fx.boot({ convars = { ['atlas:token'] = 'atl_live_x' }, load = loadOrder() })
        expect(Atlas.registerFramework ~= nil).toBe(true)
        expect(Atlas.characters ~= nil).toBe(true)
        expect(Atlas.frameworkData.qbox ~= nil).toBe(true)
        expect(Atlas.frameworkData.esx ~= nil).toBe(true)
        fx.teardown()
    end)

    it('registers both frameworks and the shared sources', function()
        fx.boot({ convars = { ['atlas:token'] = 'atl_live_x' }, load = loadOrder() })
        local names = {}
        for _, def in ipairs(Atlas.adapterList()) do names[def.name] = true end
        for _, name in ipairs({ 'natives', 'qbox', 'esx', 'esx_death', 'esx_ambulancejob', 'ox_inventory', 'qbx_vehicles', 'qbx_medical', 'renewed_banking' }) do
            expect(names[name]).toBe(true)
        end
        expect(#Atlas.sourceResources('places') > 0 or next(Atlas.sourceResources('places')) ~= nil).toBe(true)
        expect(next(Atlas.sourceResources('prices')) ~= nil).toBe(true)
        fx.teardown()
    end)

    it('lists the framework and data files', function()
        local listed = {}
        for _, path in ipairs(manifestScripts()) do listed[path] = true end
        for _, path in ipairs({
            'server/sources.lua', 'server/framework.lua', 'server/characters.lua', 'server/money.lua',
            'server/adapters/qbox_data.lua', 'server/adapters/esx.lua', 'server/adapters/esx_data.lua',
            'server/adapters/esx_death.lua', 'server/adapters/ox_inventory_data.lua',
        }) do
            expect(listed[path]).toBe(true)
        end
    end)
end)
