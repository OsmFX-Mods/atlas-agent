-- Adapters: registry that attaches each adapter once all its resources are started, in any start order.
-- Re-attach: a restarted resource loses our hooks, so attach() must be safe to call again.

local defs = {}      -- defs: adapter definitions in registration order
local active = {}    -- active: names marked true while attached
local attempt = {}   -- attempt: generation per adapter, so a newer attach replaces a retry loop still running

--- @param def table { name, resources = { 'res', ... }, attach = fn(), detach = fn()? }
function Atlas.registerAdapter(def)
    defs[#defs + 1] = def
end

local function allStarted(def)
    for i = 1, #def.resources do
        if GetResourceState(def.resources[i]) ~= 'started' then return false end
    end
    return true
end

local function uses(def, res)
    for i = 1, #def.resources do
        if def.resources[i] == res then return true end
    end
    return false
end

-- Retry: attach() can run before a resource finishes initialising (ox_inventory registers hooks while loading),
-- so it is retried for up to 30 s before warning.
local function attach(def)
    local gen = (attempt[def.name] or 0) + 1
    attempt[def.name] = gen
    CreateThread(function()
        for tries = 1, 30 do
            if attempt[def.name] ~= gen or not allStarted(def) then return end
            local ok, err = pcall(def.attach)
            if ok then
                active[def.name] = true
                Atlas.adapters[def.name] = true
                Atlas.log('adapter ^2%s^7 attached', def.name)
                return
            end
            if tries == 30 then
                Atlas.warn('adapter %s failed to attach: %s', def.name, tostring(err))
                Atlas.drop('adapter_attach_failed')
                return
            end
            Wait(1000)
        end
    end)
end

local function detach(def)
    if not active[def.name] then return end
    active[def.name] = nil
    Atlas.adapters[def.name] = nil
    if def.detach then pcall(def.detach) end
    Atlas.log('adapter ^3%s^7 detached', def.name)
end

--- Active: whether the adapter is currently attached.
function Atlas.adapterActive(name)
    return active[name] == true
end

AddEventHandler('onResourceStart', function(res)
    if res == Atlas.resource then return end
    for i = 1, #defs do
        local def = defs[i]
        if uses(def, res) then
            -- Restart: the dependency lost our hooks, so the adapter attaches again
            if active[def.name] then detach(def) end
            if allStarted(def) then attach(def) end
        end
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res == Atlas.resource then return end
    for i = 1, #defs do
        local def = defs[i]
        if uses(def, res) then detach(def) end
    end
end)

-- Initial detection: runs on the first tick, after every adapter file has loaded.
CreateThread(function()
    for i = 1, #defs do
        if allStarted(defs[i]) then attach(defs[i]) end
    end
end)
