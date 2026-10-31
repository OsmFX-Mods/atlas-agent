-- Agent settings. A value read with GetConvar can be set in server.cfg with `set`; the others are edited here.
-- Token: set atlas:token with `set`, never `setr`, which sends it to every player.

AtlasConfig = {
    endpoint = GetConvar('atlas:endpoint', 'http://127.0.0.1:7271'),

    -- Framework: 'auto' uses the one that is installed; name one (qbox, qbcore, esx) to force it; 'none' sends the account id as the character id
    framework = GetConvar('atlas:framework', 'auto'):lower(),

    -- Positions: ms between samples per player (500 or more)
    sampleMs = math.max(500, GetConvarInt('atlas:sample_ms', 3000)),
    -- Fights: players within boostRadius metres are sampled every boostSampleMs for boostMs
    combatBoost = GetConvarInt('atlas:combat_boost', 1) == 1,
    boostRadius = 150.0,
    boostMs = 60000,
    boostSampleMs = 1000,
    -- Standing still: moving moveMeters or turning turnDegrees counts as moved; otherwise a still marker goes out every stillEveryMs
    moveMeters = 1.0,
    turnDegrees = 20,
    stillEveryMs = 30000,

    -- Shots fired: clients report shots in groups
    clientCombat = GetConvarInt('atlas:client_combat', 1) == 1,
    -- Flood limits: most damage and explosion events accepted per second from one player
    damageRatePerSec = 100,
    explosionRatePerSec = 20,
    -- Kills: a hit counts as the cause of a death if it landed within this many ms
    killWindowMs = 10000,

    -- Chat: length and command name only, unless enabled
    chatContent = GetConvarInt('atlas:chat_content', 0) == 1,

    -- Snapshots: database reads through oxmysql, with intervals in minutes
    snapshots = GetConvarInt('atlas:snapshots', 1) == 1,
    moneyEveryMin = 15,
    accountsEveryMin = 15,
    -- Money: a full run every moneyFullEveryDays, changes only in between; a framework that cannot list
    -- changed rows runs a full one every moneyFullEveryMin minutes instead
    moneyFullEveryDays = 7,
    moneyFullEveryMin = 60,
    -- Census: daily at this server-local hour, with a full run on this weekday (0 = Sunday)
    censusHour = GetConvarInt('atlas:census_hour', 5),
    censusFullWeekday = GetConvarInt('atlas:census_full_weekday', 0),
    -- Census: a full run also happens when the last one is older than this many days
    censusFullMaxDays = 8,
    moneyPageRows = 500,
    censusPageRows = 200,
    -- Most bytes of inventory text in one census event; a bigger page is sent as several (the daemon takes 4 MB a line)
    censusPageBytes = 2000000,

    -- ox_inventory createItem: fires for every AddItem, so it is off by default
    oxCreateItem = GetConvarInt('atlas:ox_createitem', 0) == 1,
    -- qb-inventory ItemAdded: fires for every AddItem, so it is off by default
    qbCreateItem = GetConvarInt('atlas:qb_createitem', 0) == 1,
    -- Place visits: shop and stash opens become place.visit
    placeVisits = GetConvarInt('atlas:place_visits', 1) == 1,
    -- Place size: radius in metres per kind of place; custom is used for places added by other scripts
    placeRadius = { shop = 15.0, garage = 30.0, hospital = 40.0, police = 40.0, bank = 20.0, custom = 30.0 },

    -- Console: script errors and warnings are sent to Atlas. A line is kept if it has a word from
    -- consoleWords (any letter case); at most consoleMaxLines per second, cut to consoleMaxChars characters
    console = GetConvarInt('atlas:console', 1) == 1,
    consoleWords = { 'error', 'failed', 'warning', 'hitch' },
    consoleMaxLines = 100,
    consoleMaxChars = 1000,
    -- Console: lines that follow a script error (stack lines) are kept for this many ms
    consoleStackMs = 2000,

    -- Buffer: events held in Lua between sends; overflow is counted
    luaBufferMax = 20000,
    flushMs = 250,
    heartbeatMs = 10000,

    -- Spool: disk space for unsent events is set with the atlas:spool_mb convar (200 by default), read by transport.js

    debug = GetConvarInt('atlas:debug', 0) == 1,

    -- Character deletion: ms to wait after a delete request before checking the character is gone from the database
    deleteCheckMs = 3000,

    -- Staff ranks: ACE permissions that make a player staff and the rank each one means, highest first;
    -- Qbox and QBCore grant god, admin and mod, and server.cfg usually gives admins command
    staffAces = { { 'god', 'god' }, { 'admin', 'admin' }, { 'mod', 'mod' }, { 'command', 'admin' } },

    -- Qbox: database table names, for servers that renamed them
    qbox = {
        tables = { characters = 'players', vehicles = 'player_vehicles', properties = 'properties' },
    },

    -- ESX: account mapping and database table names, for servers that renamed them
    esx = {
        -- Accounts: ESX account name to the money type it counts as; cash, bank and crypto are part of money snapshots,
        -- any other name (such as black_money) is reported in money changes only; accounts left out are not tracked
        accounts = { money = 'cash', bank = 'bank', black_money = 'black_money' },
        tables = {
            characters = 'users', vehicles = 'owned_vehicles', vehiclePrices = 'vehicles',
            items = 'items', societyAccounts = 'addon_account_data',
        },
        -- Death events: esx_ambulancejob (ESX before 1.16) sets the dead state before its matching event arrives, so a change waits this long
        -- for it (ms), and an event counts for a death or respawn if it came within the signal time (ms)
        deathSettleMs = 500,
        deathSignalMs = 5000,
        -- Changed column: the users timestamp that updates with the row, so only changed rows are read; leave empty to read every row
        changedColumn = 'last_seen',
        -- Created column: the users timestamp set when a character is made; characters made from 2026-10-23 on are keyed by
        -- identifier and this time, so a new character in an emptied slot starts fresh; leave empty to key by identifier only
        createdColumn = 'created_at',
        -- Key reads: tries at reading a new character's key before it is sent by its plain identifier, one second apart
        keyTries = 3,
    },

    -- QBCore: money types and database table names, for servers that renamed them
    qbcore = {
        -- Money types: QBCore money type to the type it counts as; cash, bank and crypto are part of money snapshots,
        -- any other name (such as black_money) is reported in money changes only; types left out keep their own name
        moneyTypes = { cash = 'cash', bank = 'bank', crypto = 'crypto', blackmoney = 'black_money' },
        tables = {
            characters = 'players', vehicles = 'player_vehicles', bankAccounts = 'bank_accounts', managementFunds = 'management_funds',
            inventories = 'inventories', stashItems = 'stashitems', trunkItems = 'trunkitems', gloveboxItems = 'gloveboxitems',
        },
        -- Changed column: the players timestamp that updates with the row, so only changed rows are read; leave empty to read every row
        changedColumn = 'last_updated',
    },
}
