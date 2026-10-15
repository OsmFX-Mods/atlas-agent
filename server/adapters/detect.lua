-- Adapters: attaches each adapter once all its resources have started, in any order.
-- Re-attach: a restarted resource loses our hooks, so attaching must be safe to repeat.

local defs = {}      -- defs: adapters in the order they were added
local active = {}    -- active: names set to true while attached
local attempt = {}   -- attempt: latest attach number per adapter; an older retry stops when a newer one starts
local owner = {}     -- owner: the adapter holding each exclusive group, such as the framework

--- @param def table { name, resources = { 'res', ... }, attach = fn(), detach = fn()?, group = string?, enabled = fn()? }
--- Group: adapters of one group are exclusive, and the first to attach keeps it until it detaches.
--- Enabled: when it returns false the adapter is skipped.
function Atlas.registerAdapter(def)
    defs[#defs + 1] = def
end

local function allStarted(def)
    for i = 1, #def.resources do
        if GetResourceState(def.resources[i]) ~= 'started' then return false end
    end
    return true
end

local function enabled(def)
    return def.enabled == nil or def.enabled()
end

local function uses(def, res)
    for i = 1, #def.resources do
        if def.resources[i] == res then return true end
    end
    return false
end

-- Retry: a resource may not be ready when it starts (ox_inventory sets up hooks while loading),
-- so attaching is retried for up to 30 s before a warning.
local function attach(def)
    local gen = (attempt[def.name] or 0) + 1
    attempt[def.name] = gen
    CreateThread(function()
        for tries = 1, 30 do
            if attempt[def.name] ~= gen or not allStarted(def) then return end
            if def.group and owner[def.group] and owner[def.group] ~= def.name then
                Atlas.warn('%s is the active %s, so %s is not used. Set atlas:%s to choose another.',
                    owner[def.group], def.group, def.name, def.group)
                return
            end
            local ok, err = pcall(def.attach)
            if ok then
                active[def.name] = true
                if def.group then owner[def.group] = def.name end
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
    if def.group and owner[def.group] == def.name then owner[def.group] = nil end
    Atlas.adapters[def.name] = nil
    if def.detach then pcall(def.detach) end
    Atlas.log('adapter ^3%s^7 detached', def.name)
end

--- List: every registered adapter, for the selftest report.
function Atlas.adapterList()
    return defs
end

--- Owner: the adapter currently holding an exclusive group, or nil.
function Atlas.adapterOwner(group)
    return owner[group]
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
            if allStarted(def) and enabled(def) then attach(def) end
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
        if allStarted(defs[i]) and enabled(defs[i]) then attach(defs[i]) end
    end
end)
