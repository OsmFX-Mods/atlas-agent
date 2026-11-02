-- Attribution: names the script behind a money or item change, on any framework and without ox_lib.
-- Why here: frameworks fire their money event themselves, so GetInvokingResource in a listener is only ever the framework;
-- the stack of the same call still holds the script that asked, across resources.
-- Native: called by hash because the lazy FormatStackTrace wrapper returns nothing on a second call in one run, and one
-- script often moves money twice in a run (measured on FXServer: 2004 of 2004 calls answered).

local cfg = AtlasConfig
local caller = AtlasLib.caller
local FORMAT_STACK_TRACE = 0xd70c3bca
local AS_STRING = Citizen.ResultAsString()

local A = {}
Atlas.attribution = A

local core = {} -- core: resources that move money or items on behalf of scripts, as name to kind
local libs = { [Atlas.resource] = true } -- libs: resources that only carry a call and never mean anything themselves
for _, name in ipairs(cfg.attributionLibs) do libs[name] = true end

--- Core: registers a resource that moves money or items on behalf of other scripts.
function A.addCore(name, kind) core[name] = kind end

--- Frames: the stack of the change being handled, newest first; empty when attribution is off.
function A.frames()
    if not cfg.attribute then return {} end
    local ok, text = pcall(Citizen.InvokeNative, FORMAT_STACK_TRACE, nil, 0, AS_STRING)
    if not ok or type(text) ~= 'string' then
        Atlas.drop('attribution_no_stack')
        return {}
    end
    return caller.frames(text)
end

--- Pick: who a stack from A.frames belongs to.
--- @return string? res, string? origin `file:line`, string? kind
function A.pick(frames)
    local fw = Atlas.framework
    for _, name in ipairs(fw and fw.resources or {}) do core[name] = core[name] or 'framework' end
    return caller.pick(frames, core, libs)
end

--- Who: the script behind the change being handled; call it inside the handler of the framework's or inventory's event.
--- @return string? res, string? origin `file:line`, string? kind
function A.who() return A.pick(A.frames()) end
