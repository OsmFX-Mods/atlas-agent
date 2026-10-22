-- Framework: the one adapter that tells Atlas who is playing and what they own.
-- Contract: docs/frameworks.md lists what a framework adapter provides; the rest of the agent only uses that.

local cfg = AtlasConfig

Atlas.framework = nil      -- framework: the attached definition, nil when none is attached
Atlas.frameworkData = {}   -- frameworkData: data readers per framework name, filled before the adapter registers
Atlas.charFallback = nil   -- charFallback: true when no framework is installed, so account ids stand in for characters

local frameworks = {} -- frameworks: registered definitions in priority order

--- Displaced: the name of a resource that replaces this framework when one is installed, such as qbx_core, which also answers to qb-core.
local function displaced(def)
    for _, res in ipairs(def.displacedBy or {}) do
        if GetResourceState(res) ~= 'missing' then return res end
    end
    return nil
end

local function wanted(def)
    return (cfg.framework == 'auto' or cfg.framework == def.name) and not displaced(def)
end

local warned = false -- warned: the unknown-setting warning is shown once

--- Setting check: a framework name that no adapter has is reported once, since it would silently turn everything off.
local function checkSetting()
    if warned or cfg.framework == 'auto' or cfg.framework == 'none' then return end
    warned = true
    local names = {}
    for _, def in ipairs(frameworks) do
        if def.name == cfg.framework then return end
        names[#names + 1] = def.name
    end
    Atlas.warn('atlas:framework is "%s", which is not supported (use auto, none or one of: %s)', cfg.framework, table.concat(names, ', '))
end

local function installed(def)
    if displaced(def) then return false end
    for i = 1, #def.resources do
        if GetResourceState(def.resources[i]) == 'missing' then return false end
    end
    return true
end

--- Character fallback: servers without a supported framework get the account id as the character id,
--- since maps, rewind, trips and playtime only read positions that carry a character.
function Atlas.refreshFallback()
    checkSetting()
    local fallback = true
    if cfg.framework ~= 'none' then
        for _, def in ipairs(frameworks) do
            if wanted(def) and installed(def) then fallback = false break end
        end
    end
    if fallback == Atlas.charFallback then return end
    Atlas.charFallback = fallback
    Atlas.rebuildActors()
end

--- @param def table { name, resources, attach, detach?, data?, displacedBy? }
--- Data: optional readers for saved data (money, census, vehicles, groups); a missing one skips that snapshot.
--- Displaced by: resources whose presence means another framework runs under this one's name, so this one stays off.
function Atlas.registerFramework(def)
    local attach, detach = def.attach, def.detach
    def.group = 'framework'
    def.enabled = function() return wanted(def) end
    def.displaced = function() return displaced(def) end
    def.data = def.data or Atlas.frameworkData[def.name]
    def.attach = function()
        attach()
        Atlas.framework = def
        Atlas.refreshFallback()
    end
    def.detach = function()
        if Atlas.framework == def then Atlas.framework = nil end
        if detach then detach() end
    end
    frameworks[#frameworks + 1] = def
    Atlas.registerAdapter(def)
end

--- Reader: one data reader of the attached framework, or nil when there is none or it does not provide it.
function Atlas.reader(name)
    local fw = Atlas.framework
    return fw and fw.data and fw.data[name] or nil
end

--- Groups: sets of job and gang names, for classifying bank accounts; nil when unknown.
function Atlas.groups()
    local groups = Atlas.reader('groups')
    if not groups then return nil, nil end
    return groups()
end

-- Added resources: a framework added to the server while it runs turns the fallback off.
AddEventHandler('onResourceStart', function(res)
    for _, def in ipairs(frameworks) do
        for i = 1, #def.resources do
            if def.resources[i] == res then return Atlas.refreshFallback() end
        end
    end
end)
