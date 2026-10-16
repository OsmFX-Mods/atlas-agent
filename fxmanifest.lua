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

-- Node: transport.js needs only http, https, zlib and fs, so it runs on FXServer's default Node 16.
-- node_version '22' is left unset because FXServer has open crash reports with it under load.

server_scripts {
    'config.lua',
    -- Libraries: helpers with no FiveM dependency, tested in tests/
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
    -- Foundation: what every framework adapter builds on (sources, framework registry, characters, money)
    'server/sources.lua',
    'server/adapters/detect.lua',
    'server/framework.lua',
    'server/characters.lua',
    'server/money.lua',
    -- Adapters: attach when their target resource starts, in any start order
    'server/adapters/natives.lua',
    'server/adapters/qbox_data.lua',
    'server/adapters/qbox.lua',
    'server/adapters/esx_data.lua',
    'server/adapters/esx.lua',
    'server/adapters/esx_death.lua',
    'server/adapters/ox_inventory_data.lua',
    'server/adapters/ox_inventory.lua',
    'server/adapters/qbx_vehicles.lua',
    'server/adapters/qbx_medical.lua',
    'server/adapters/renewed_banking.lua',
    -- Console: script errors and warnings from the server console
    'server/console.lua',
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
    '/onesync', -- OneSync: the sampler reads player positions on the server
}
