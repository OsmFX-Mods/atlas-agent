-- Renewed-Banking adapter: the resource has no balance event, so balances come from accounts.snapshot.

local common = AtlasLib.common
local sandbox = AtlasLib.sandbox
local NAME = 'renewed_banking'

Atlas.registerAdapter({
    name = NAME,
    resources = { 'Renewed-Banking' },
    attach = function() end,
})

-- Accounts: [[account_id, kind, amount]], classified with the job and gang names of the framework.
Atlas.registerSource('accounts', {
    name = NAME,
    resources = { 'Renewed-Banking' },
    read = function()
        local rows, err = Atlas.db.query('SELECT id, amount, creator FROM bank_accounts_new')
        if type(rows) ~= 'table' then return nil, err end
        local jobs, gangs = Atlas.groups()
        local out = {}
        for i = 1, #rows do
            local r = rows[i]
            out[#out + 1] = { tostring(r.id), common.accountKind(r.id, r.creator, jobs, gangs), tonumber(r.amount) or 0 }
        end
        return out
    end,
})

-- Places: bank teller peds.
Atlas.registerSource('places', {
    name = NAME,
    resources = { 'Renewed-Banking' },
    read = function(add)
        local _, env = Atlas.loadConfig('Renewed-Banking', 'config.lua')
        local conf = env and rawget(env, 'Config')
        if type(conf) ~= 'table' or type(conf.peds) ~= 'table' then return end
        for _, ped in sandbox.items(conf.peds) do
            if type(ped) == 'table' then add('Bank', 'bank', ped.coords) end
        end
    end,
})
