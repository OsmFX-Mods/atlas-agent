-- Agent settings. A value read with GetConvar can be set in server.cfg with `set`; the others are edited here.
-- Token: set atlas:token with `set`, never `setr`, which sends it to every player.

AtlasConfig = {
    endpoint = GetConvar('atlas:endpoint', 'http://127.0.0.1:7271'),

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
    -- Money: a full run every moneyFullEveryDays, changes only in between
    moneyFullEveryDays = 7,
    -- Census: daily at this server-local hour, with a full run on this weekday (0 = Sunday)
    censusHour = GetConvarInt('atlas:census_hour', 5),
    censusFullWeekday = GetConvarInt('atlas:census_full_weekday', 0),
    -- Census: a full run also happens when the last one is older than this many days
    censusFullMaxDays = 8,
    moneyPageRows = 500,
    censusPageRows = 200,

    -- ox_inventory createItem: fires for every AddItem, so it is off by default
    oxCreateItem = GetConvarInt('atlas:ox_createitem', 0) == 1,
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
}
