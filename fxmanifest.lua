fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'atlas-agent'
author 'OsmFX Mods'
description 'Atlas analytics agent: captures gameplay facts and ships them to Atlas'
version '0.1.0' -- Version: stamped from the release tag by .github/workflows/release.yml
repository 'https://github.com/OsmFX-Mods/atlas-agent'

-- Name: code reads its own name from GetCurrentResourceName, so a renamed folder works.
-- Alias: provide 'atlas' keeps exports.atlas:track(...) working for scripts written against the old name.
provide 'atlas'

-- Node: transport.js runs on FXServer's default Node 16 and needs only http, https, zlib and fs.
-- Version: node_version '22' is not set, because of open FXServer crash reports with Node 22 under load.

server_scripts {
    'config.lua',
    -- Libraries: pure helpers, unit-tested in tests/
    'server/lib/common.lua',
    'server/lib/clock.lua',
    'server/lib/motion.lua',
    'server/lib/shots.lua',
    'server/lib/inventory.lua',
    'server/lib/sandbox.lua',
    -- Core: events, database access and the sampler
    'server/core.lua',
    'server/db.lua',
    'server/sampler.lua',
    -- Adapters: attach when their target resource starts, in any start order
    'server/adapters/detect.lua',
    'server/adapters/natives.lua',
    'server/adapters/qbox.lua',
    'server/adapters/ox_inventory.lua',
    'server/adapters/qbx_vehicles.lua',
    'server/adapters/qbx_medical.lua',
    'server/adapters/renewed_banking.lua',
    -- Features: snapshots, places, client reports, exports and commands
    'server/snapshots.lua',
    'server/places.lua',
    'server/client_reports.lua',
    'server/exports.lua',
    'server/commands.lua',
    -- Transport: Node script that sends batches to Atlas
    'server/transport.js',
}

client_scripts {
    'client/combat.lua',
}

dependencies {
    '/onesync', -- OneSync: the sampler reads player peds with server-side natives
}
