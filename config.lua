-- Config: defaults for the agent; every value can be overridden with a convar in server.cfg.
-- Token: set atlas:token with `set`, never `setr`, which replicates it to every client; only transport.js reads it.

AtlasConfig = {
    endpoint = GetConvar('atlas:endpoint', 'http://127.0.0.1:7271'),

    -- Sampler: sample interval and the combat boost (radius in m, durations in ms)
    sampleMs = math.max(500, GetConvarInt('atlas:sample_ms', 3000)),
    combatBoost = GetConvarInt('atlas:combat_boost', 1) == 1,
    boostRadius = 150.0,
    boostMs = 60000,
    boostSampleMs = 1000,

    -- Client combat: shots-fired reports from clients
    clientCombat = GetConvarInt('atlas:client_combat', 1) == 1,

    -- Chat: length and command name only, unless enabled
    chatContent = GetConvarInt('atlas:chat_content', 0) == 1,

    -- Snapshots: database reads through oxmysql, with intervals in minutes
    snapshots = GetConvarInt('atlas:snapshots', 1) == 1,
    moneyEveryMin = 15,
    accountsEveryMin = 15,
    -- Census: daily at this server-local hour, with a full run on this weekday (os.date %w, 0 = Sunday)
    censusHour = GetConvarInt('atlas:census_hour', 5),
    censusFullWeekday = GetConvarInt('atlas:census_full_weekday', 0),
    moneyPageRows = 500,
    censusPageRows = 200,

    -- createItem: ox_inventory fires it for every AddItem (gives, money sync, failed adds), so it is off by default
    oxCreateItem = GetConvarInt('atlas:ox_createitem', 0) == 1,
    -- Place visits: shop and stash opens become place.visit
    placeVisits = GetConvarInt('atlas:place_visits', 1) == 1,

    -- Buffer: Lua-side events held between flushes; overflow is counted
    luaBufferMax = 20000,
    flushMs = 250,
    heartbeatMs = 10000,

    debug = GetConvarInt('atlas:debug', 0) == 1,
}
