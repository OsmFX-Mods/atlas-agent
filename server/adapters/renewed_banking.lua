-- Renewed-Banking adapter: the resource fires no event on balance changes, so account.change cannot come from events.
-- Balances: society and business accounts come from accounts.snapshot (server/snapshots.lua), which the daemon diffs.

local common = AtlasLib.common
local NAME = 'renewed_banking'

Atlas.registerAdapter({
    name = NAME,
    resources = { 'Renewed-Banking' },
    attach = function() end,
})

--- Accounts rows: [[account_id, kind, amount]] for one snapshot, or nil and an error; thread only, the database call yields.
function Atlas.accountsRows()
    if not Atlas.adapterActive(NAME) then return nil, 'Renewed-Banking not started' end
    local rows, err = Atlas.db.query('SELECT id, amount, creator FROM bank_accounts_new')
    if type(rows) ~= 'table' then return nil, err end
    local jobs, gangs = Atlas.qbxGroups()
    local out = {}
    for i = 1, #rows do
        local r = rows[i]
        out[#out + 1] = { tostring(r.id), common.accountKind(r.id, r.creator, jobs, gangs), tonumber(r.amount) or 0 }
    end
    return out
end
