-- Sources: registry of optional data readers that adapters add for the resources they know.
-- Kinds: places (map locations), prices (price catalog), accounts (society and business balances), census (inventory kinds).

local sandbox = AtlasLib.sandbox

local defs = {} -- defs: source definitions per kind, in registration order

--- @param kind string 'places' | 'prices' | 'accounts' | 'census'
--- @param def table { name, resources = { 'res', ... }, read = fn, ... }, other fields depend on the kind
function Atlas.registerSource(kind, def)
    local list = defs[kind]
    if not list then list = {}; defs[kind] = list end
    list[#list + 1] = def
end

local function allStarted(def)
    for i = 1, #def.resources do
        if GetResourceState(def.resources[i]) ~= 'started' then return false end
    end
    return true
end

--- Active sources: those of one kind whose resources are all started.
function Atlas.sources(kind)
    local out = {}
    for _, def in ipairs(defs[kind] or {}) do
        if allStarted(def) then out[#out + 1] = def end
    end
    return out
end

--- Source resources: the set of resource names that any source of this kind reads.
function Atlas.sourceResources(kind)
    local set = {}
    for _, def in ipairs(defs[kind] or {}) do
        for _, res in ipairs(def.resources) do set[res] = true end
    end
    return set
end

--- Config file: runs a plain-data Lua file of another resource in the sandbox.
--- @return any result, table? env  (result is the value the file returns; env holds the globals it set)
function Atlas.loadConfig(res, path, globals)
    if GetResourceState(res) == 'missing' then return nil end
    local src = LoadResourceFile(res, path)
    if not src then return nil end
    local result, env, err = sandbox.load(src, res .. '/' .. path, Atlas.vectorCtors(), globals)
    if err then Atlas.debug('could not read %s/%s: %s', res, path, tostring(err)) end
    return result, env
end

--- Accounts rows: [[account_id, kind, amount]] gathered from every active accounts source, or nil and an error.
--- A source that fails makes the whole list nil, since a partial list would look like accounts disappearing.
--- Thread only: sources read the database, which yields.
function Atlas.accountsRows()
    local active = Atlas.sources('accounts')
    if #active == 0 then return nil, 'no account source started' end
    local out = {}
    for _, def in ipairs(active) do
        local rows, err = def.read()
        if type(rows) ~= 'table' then return nil, err end
        for i = 1, #rows do out[#out + 1] = rows[i] end
    end
    return out
end
