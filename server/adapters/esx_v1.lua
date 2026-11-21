-- ESX v1: for ESX from before accounts moved into the users table as JSON (1.0 to early 1.2.0, up to March 2020).
-- Live data: read through the standard xPlayer, whose accounts and inventory come in different shapes between these versions.
-- Saved data: cash and bank are users columns or user_accounts rows, and items are user_inventory rows or JSON in users;
-- the layout is read from the database, so a server that upgraded and kept its old tables reads the ones in use.
-- Money events: ESX v1 has no server-side money event. esx.lua listens for esx:addAccountMoney, esx:removeAccountMoney and
-- esx:setAccountMoney, so money.change only flows when es_extended fires them; balances in snapshots are correct without them.
-- Characters: money, items and vehicles belong to the users row, so that row is the Atlas character.

local cfg = AtlasConfig
local common = AtlasLib.common
local db = Atlas.db
local C = Atlas.characters
local data = Atlas.frameworkData.esx

local V1 = {}
data.v1 = V1

local RESPAWN_WAIT_MS = 2500 -- RESPAWN_WAIT_MS: esx_ambulancejob clears the dead state, fades the screen, and only then asks for its respawn callback

local ESX -- ESX: the shared object of es_extended, nil unless ESX v1 is in use
local schema -- schema: what the database holds, nil until read
local legacyReaders = { money = data.money, census = data.census, groups = data.groups } -- legacyReaders: restored when ESX Legacy attaches
local deathWait = {} -- deathWait[src]: the cleared dead state waiting to be told apart as a revive or a respawn
local respawnAt = {} -- respawnAt[src]: game time of the last respawn callback

local function running() return ESX ~= nil and Atlas.enabled and Atlas.adapterActive('esx') end

local TABLES = { userAccounts = 'user_accounts', inventory = 'user_inventory', jobs = 'jobs' } -- TABLES: used when a config.lua predates these names

--- Table name: the configured name of a table, or its default.
local function tableName(key) return cfg.esx.tables[key] or TABLES[key] end

--- Table: a configured table name as a quoted identifier, nil with a warning when it is not a valid name.
local function tbl(key)
    local name = common.sqlName(tableName(key))
    if not name then Atlas.warn('config: esx.tables.%s is not a valid table name', key) end
    return name
end

--- Schema: the saved-data layout; nil after a database error, false when there is no users table.
local function readSchema()
    if schema then return schema end
    local usersName, accountsName, itemsName = cfg.esx.tables.characters, tableName('userAccounts'), tableName('inventory')
    local rows = db.query('SELECT TABLE_NAME AS t, COLUMN_NAME AS c FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME IN (?, ?, ?)',
        { usersName, accountsName, itemsName })
    if type(rows) ~= 'table' then return nil end
    local has = {}
    for i = 1, #rows do
        local name, column = tostring(rows[i].t):lower(), tostring(rows[i].c):lower()
        has[name] = has[name] or {}
        has[name][column] = true
    end
    local users = has[usersName:lower()]
    if not users then return false end
    local accounts = has[accountsName:lower()]
    local items = has[itemsName:lower()]
    local found = {
        accountsJson = users.accounts == true,
        moneyColumns = users.money == true and users.bank == true,
        inventoryColumn = users.inventory == true,
        inventoryTable = items ~= nil and items.item == true and items.count == true,
        names = users.firstname == true and users.lastname == true,
        deadColumn = users.is_dead == true,
        accountRows = accounts ~= nil and accounts.identifier == true and accounts.name == true and accounts.money == true,
        bankInAccounts = false,
    }
    -- Accounts: a bank row means user_accounts holds cash and bank, even when older users columns were left behind;
    -- without those columns it is the only place they can be, even while the table is still empty
    if found.accountRows and not found.accountsJson then
        local name = tbl('userAccounts')
        if not name then return nil end
        local row, err = db.scalar(("SELECT 1 FROM %s WHERE name = 'bank' LIMIT 1"):format(name))
        if err then return nil end
        found.bankInAccounts = row ~= nil or not found.moneyColumns
    end
    schema = found
    return schema
end

-- xPlayer: every read of a live player goes through the functions below.

local function xPlayerOf(src)
    if not ESX then return nil end
    local ok, x = pcall(ESX.GetPlayerFromId, src)
    return ok and type(x) == 'table' and x or nil
end

--- Method: one xPlayer method, nil when it fails.
local function method(x, name, ...)
    local ok, value = pcall(x[name], ...)
    if ok then return value end
end

--- Accounts: balances by account name, from a list of accounts or a name to balance table, with cash as `money`.
local function accountsOf(x)
    local list = method(x, 'getAccounts')
    if type(list) ~= 'table' then return nil end
    local out = {}
    for key, account in pairs(list) do
        if type(account) == 'table' and type(account.name) == 'string' then
            out[account.name] = tonumber(account.money)
        elseif type(key) == 'string' then
            out[key] = tonumber(account)
        end
    end
    if out.money == nil then out.money = tonumber(method(x, 'getMoney')) end
    return out
end

--- Items: item name to count, from a list of items or a name to count table; empty entries are left out.
local function itemsOf(x)
    local list = method(x, 'getInventory', true)
    if type(list) ~= 'table' then return nil end
    local out = {}
    for key, item in pairs(list) do
        local name, count = key, item
        if type(item) == 'table' then name, count = item.name, item.count end
        count = tonumber(count)
        if type(name) == 'string' and count and count > 0 then out[name] = count end
    end
    return out
end

--- Accounts of a source: live balances by account name, nil when the player is not loaded.
function V1.accounts(src)
    local x = xPlayerOf(src)
    return x and accountsOf(x)
end

--- Player: the parts of an xPlayer that esx.lua reads, with the shapes of these versions evened out.
function V1.player(src)
    local x = xPlayerOf(src)
    if not x then return nil end
    local identifier = x.identifier or method(x, 'getIdentifier')
    if type(identifier) ~= 'string' or identifier == '' then return nil end
    return {
        identifier = identifier,
        variables = {},
        getJob = function() return method(x, 'getJob') end,
        getAccounts = function() return accountsOf(x) end,
        getAccount = function(name)
            local accounts = accountsOf(x)
            return { money = accounts and accounts[name] }
        end,
        setAccountMoney = function(name, money, reason) return x.setAccountMoney(name, money, reason) end,
        getInventory = function() return itemsOf(x) end,
    }
end

--- Group: the player's staff group.
function V1.group(src)
    local x = xPlayerOf(src)
    return x and method(x, 'getGroup') or nil
end

--- Identity: the saved name and dead state of a character, since the xPlayer of these versions has neither.
--- @return table? { firstName, lastName, dead }
function V1.identity(identifier)
    local s = readSchema()
    local users = tbl('characters')
    if not s or not users or not (s.names or s.deadColumn) then return nil end
    local columns = {}
    if s.names then columns[#columns + 1] = 'firstname, lastname' end
    if s.deadColumn then columns[#columns + 1] = 'is_dead' end
    local row = db.single(('SELECT %s FROM %s WHERE identifier = ? LIMIT 1'):format(table.concat(columns, ', '), users), { identifier })
    if type(row) ~= 'table' then return nil end
    return { firstName = row.firstname, lastName = row.lastname, dead = row.is_dead == true or tonumber(row.is_dead) == 1 }
end

-- Money snapshot: users has no column that follows every balance change, so this runs as a full read on the short cycle.
local money = { delta = false }

--- Init: online balances are read fresh, since without money events the ones kept since login are out of date.
function money.init()
    if not ESX then return end
    -- List: copied first, since players can join or leave during the pauses
    local list = {}
    for src in pairs(Atlas.players) do list[#list + 1] = src end
    for i, src in ipairs(list) do
        local p = Atlas.players[src]
        local live = p and p.char and V1.accounts(src)
        if live and Atlas.players[src] == p then p.money = data.slots(live) end
        if i % 25 == 0 then Wait(0) end
    end
end

local function countUsers()
    local t = tbl('characters')
    return t and db.scalar('SELECT COUNT(*) FROM ' .. t)
end

money.count = countUsers

--- Balances page: result rows per holder and account, grouped into one snapshot row per holder.
--- From columns: cash and bank come from users, so account rows with those names are not counted as well.
local function balancePage(sql, cursor, fromColumns)
    local rows = db.query(sql, { cursor or '' })
    if type(rows) ~= 'table' then return nil end
    local out, balances, last = {}, nil, nil
    local function close()
        if not balances then return end
        local slots = data.slots(balances)
        out[#out + 1] = { last, slots.cash, slots.bank, slots.crypto }
    end
    for i = 1, #rows do
        local r = rows[i]
        if r.identifier ~= last then
            close()
            last, balances = r.identifier, fromColumns and { money = r.money, bank = r.bank } or {}
        end
        local name = type(r.account) == 'string' and r.account:lower()
        if name and not (fromColumns and (name == 'money' or name == 'bank')) then
            balances[name] = (tonumber(balances[name]) or 0) + (tonumber(r.amount) or 0)
        end
    end
    close()
    return out, last, #out
end

function money.page(_, cursor, per)
    local s = readSchema()
    local t = tbl('characters')
    if not s or not t or not (s.bankInAccounts or s.moneyColumns) then return nil end
    if not s.accountRows then
        return balancePage(('SELECT identifier, money, bank FROM %s WHERE identifier > ? ORDER BY identifier LIMIT %d'):format(t, per), cursor, true)
    end
    local accounts = tbl('userAccounts')
    if not accounts then return nil end
    local fromColumns = not s.bankInAccounts
    return balancePage(([[SELECT u.identifier%s, a.name AS account, a.money AS amount
        FROM (SELECT identifier%s FROM %s WHERE identifier > ? ORDER BY identifier LIMIT %d) u
        LEFT JOIN %s a ON a.identifier = u.identifier ORDER BY u.identifier]]):format(
        fromColumns and ', u.money, u.bank' or '', fromColumns and ', money, bank' or '', t, per, accounts), cursor, fromColumns)
end

-- Census: items per holder, from JSON in users or from one row per item in user_inventory.
local players = { kind = 'player', order = 10, delta = false }

function players.count()
    local s = readSchema()
    if not s then return nil end
    if s.inventoryColumn then return countUsers() end
    local t = tbl('inventory')
    return t and db.scalar(('SELECT COUNT(DISTINCT identifier) FROM %s WHERE `count` > 0'):format(t))
end

local function jsonPage(cursor, per)
    local t = tbl('characters')
    if not t then return nil end
    local rows = db.query(('SELECT identifier, inventory FROM %s WHERE identifier > ? ORDER BY identifier LIMIT %d'):format(t, per), { cursor or '' })
    if type(rows) ~= 'table' then return nil end
    local out = {}
    for i = 1, #rows do out[i] = { rows[i].identifier, AtlasLib.inventory.census(rows[i].inventory, json) } end
    return out, rows[#rows] and rows[#rows].identifier, #rows
end

local function tablePage(cursor, per)
    local t = tbl('inventory')
    if not t then return nil end
    local rows = db.query(([[SELECT i.identifier, i.item, i.`count` AS n FROM %s i
        JOIN (SELECT DISTINCT identifier FROM %s WHERE identifier > ? AND `count` > 0 ORDER BY identifier LIMIT %d) h
        ON h.identifier = i.identifier WHERE i.`count` > 0 ORDER BY i.identifier, i.item]]):format(t, t, per), { cursor or '' })
    if type(rows) ~= 'table' then return nil end
    local out, list, last = {}, nil, nil
    for i = 1, #rows do
        local r = rows[i]
        if r.identifier ~= last then
            if list then out[#out + 1] = { last, json.encode(list) } end
            list, last = {}, r.identifier
        end
        list[#list + 1] = { name = r.item, count = tonumber(r.n) or 0 }
    end
    if list then out[#out + 1] = { last, json.encode(list) } end
    return out, last, #out
end

function players.page(_, cursor, per)
    local s = readSchema()
    if not s then return nil end
    if s.inventoryColumn then return jsonPage(cursor, per) end
    if s.inventoryTable then return tablePage(cursor, per) end
    return nil
end

--- Groups: job names from the database, since these versions have no ESX.GetJobs.
local function groups()
    local t = tbl('jobs')
    local rows = t and db.query('SELECT name FROM ' .. t)
    if type(rows) ~= 'table' then return nil, nil end
    local jobs = {}
    for i = 1, #rows do
        if type(rows[i].name) == 'string' then jobs[rows[i].name] = true end
    end
    return jobs, {}
end

--- Detect: whether this es_extended is ESX v1, from the users table; without a database, from the resource's version.
function V1.detect()
    schema = nil -- schema: read again on every attach, since the database may have been migrated while the agent ran
    for _ = 1, 5 do
        if not db.available() then break end
        local s = readSchema()
        if s then return not s.accountsJson end
        if s == false then break end
        Wait(1000)
    end
    local major, minor = tostring(GetResourceMetadata('es_extended', 'version', 0)):match('^(%d+)%.(%d+)')
    return tonumber(major) == 1 and tonumber(minor) ~= nil and tonumber(minor) <= 2
end

--- Use: switches the data readers to ESX v1; characters are keyed by identifier only.
function V1.use(esx)
    ESX = esx
    data.keys.plain(true)
    data.money, data.census, data.groups = money, function() return { players } end, groups
end

--- Stop: back to the ESX Legacy readers.
function V1.stop()
    ESX = nil
    data.keys.plain(false)
    data.money, data.census, data.groups = legacyReaders.money, legacyReaders.census, legacyReaders.groups
end

-- Persona: an esx_identity that reports a character change renames the same users row; a player's first identity is a new character.
AddEventHandler('esx_identity:characterChanged', function(identity, isNew)
    if not running() or type(identity) ~= 'table' then return end
    local src = tonumber(identity.source)
    local p = src and Atlas.players[src]
    if not p or not p.char or type(identity.firstname) ~= 'string' or identity.firstname == '' then return end
    local name = ('%s %s'):format(identity.firstname, type(identity.lastname) == 'string' and identity.lastname or '')
    if name == p.charName then return end
    local first = not p.charName
    Atlas.setChar(src, p.char, name)
    if isNew == true and first then Atlas.emit('character.create', { char = p.char, char_name = name }, src) end
end)

--- Apply death: records a death, revive or respawn once.
local function applyDeath(src, p, isDead, respawned)
    if Atlas.players[src] ~= p or not p.char then return end
    if isDead == (type(p.state) == 'table' and p.state.isdead == true) then return end
    -- Respawn: announced first, so the state change that follows is not reported as a revive
    if not isDead and respawned then C.respawn(src) end
    C.setState(src, 'isdead', isDead)
end

--- Respawned: whether the respawn callback came recently; it counts once.
local function takeRespawn(src)
    local at = respawnAt[src]
    respawnAt[src] = nil
    return at ~= nil and GetGameTimer() - at <= cfg.esx.deathSignalMs
end

-- Respawn: esx_ambulancejob asks for this callback only on a hospital respawn, not on a revive.
RegisterNetEvent('esx:triggerServerCallback', function(name)
    if running() and name == 'esx_ambulancejob:removeItemsAfterRPDeath' then respawnAt[tonumber(source)] = GetGameTimer() end
end)

-- Death: the client reports each death, revive and respawn. A cleared state waits for the respawn callback that may follow it,
-- unless the client already says it is a respawn with a true third value.
RegisterNetEvent('esx_ambulancejob:setDeathStatus', function(isDead, _, respawned)
    local src = tonumber(source)
    if not running() or type(isDead) ~= 'boolean' then return end
    local p = Atlas.players[src]
    if not p or not p.char then return end
    -- New death: a cleared state still waiting is settled first, so its revive or respawn is not lost
    if isDead and deathWait[src] then
        deathWait[src] = nil
        applyDeath(src, p, false, takeRespawn(src))
    end
    if isDead then respawnAt[src] = nil end -- Late callback: one from before this death does not describe how it ends
    if isDead or respawned == true then
        deathWait[src] = nil
        return applyDeath(src, p, isDead, respawned == true)
    end
    local token = {}
    deathWait[src] = token
    CreateThread(function()
        Wait(RESPAWN_WAIT_MS)
        if deathWait[src] ~= token then return end
        deathWait[src] = nil
        applyDeath(src, p, false, takeRespawn(src))
    end)
end)

Atlas.onDrop(function(p) deathWait[p.src], respawnAt[p.src] = nil, nil end)

-- Groups: a server that reports staff group changes has its rank read again.
AddEventHandler('esx:playerGroupChanged', function(src)
    src = tonumber(src)
    if running() and src then Atlas.staff.check(src) end
end)
