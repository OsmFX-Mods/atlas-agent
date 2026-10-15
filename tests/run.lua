-- Test runner: minimal busted-style runner for the pure Lua modules, run with `lua5.4 tests/run.lua`.
-- Specs: each tests/*_spec.lua file uses the describe, it and expect functions defined here.

local base = (arg and arg[0] and arg[0]:match('^(.*)[/\\]tests[/\\]run%.lua$')) or '.'
package.path = base .. '/?.lua;' .. package.path

local passed, failed, failures = 0, 0, {}
local stack = {}
local hooks = {}

--- After each: registers a cleanup that runs after every test, passed or failed.
function after_each(fn) hooks[#hooks + 1] = fn end

function describe(name, fn)
    stack[#stack + 1] = name
    fn()
    stack[#stack] = nil
end

function it(name, fn)
    local full = table.concat(stack, ' > ') .. ' > ' .. name
    local ok, err = pcall(fn)
    for _, hook in ipairs(hooks) do pcall(hook) end
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        failures[#failures + 1] = full .. '\n      ' .. tostring(err)
    end
end

local function fmt(v)
    if type(v) == 'string' then return string.format('%q', v) end
    return tostring(v)
end

local function deepEq(a, b)
    if a == b then return true end
    if type(a) ~= 'table' or type(b) ~= 'table' then return false end
    for k, v in pairs(a) do if not deepEq(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

function expect(actual)
    return {
        toBe = function(expected)
            if actual ~= expected then error(('expected %s, got %s'):format(fmt(expected), fmt(actual)), 2) end
        end,
        toEqual = function(expected)
            if not deepEq(actual, expected) then error('tables differ', 2) end
        end,
        toBeNear = function(expected, eps)
            if math.abs(actual - expected) > (eps or 1e-9) then error(('expected ~%s, got %s'):format(fmt(expected), fmt(actual)), 2) end
        end,
        toBeTruthy = function()
            if not actual then error('expected truthy, got ' .. fmt(actual), 2) end
        end,
        toBeNil = function()
            if actual ~= nil then error('expected nil, got ' .. fmt(actual), 2) end
        end,
    }
end

--- Load module: loads a module file fresh; modules return their table.
function load_module(rel)
    return dofile(base .. '/' .. rel)
end

local specs = { 'common', 'clock', 'motion', 'shots', 'inventory', 'sandbox', 'core', 'sampler', 'client_reports', 'exports', 'adapters', 'snapshots', 'natives', 'qbox', 'ox_inventory', 'vehicles_places', 'commands', 'db', 'console' }
for _, name in ipairs(specs) do
    dofile(base .. '/tests/' .. name .. '_spec.lua')
end

print(('%d passed, %d failed'):format(passed, failed))
for _, f in ipairs(failures) do print('  FAIL ' .. f) end
if failed > 0 then os.exit(1) end
