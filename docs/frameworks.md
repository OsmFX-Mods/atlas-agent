# Frameworks

The agent reads a server through one **framework adapter**. The adapter turns the framework's own events into Atlas events, and tells the snapshots where the framework keeps its data. Everything else in the agent (sessions, positions, combat, items, places) works the same on every framework.

## Supported

| Framework | Resource | Built against |
| :--- | :--- | :--- |
| Qbox | `qbx_core` | 1.23.0 |
| QBCore | `qb-core` | 1.3.0, also checked against the 2022 to 2025 releases |
| ESX Legacy | `es_extended` | 1.16.0, also checked against 1.13 to 1.15 (the events used are the same back to 1.9.4) |

`ox_inventory` works with Qbox and ESX; QBCore uses `qb-inventory`. Other framework resources start in any order; the agent attaches to each one as it starts.

## Choosing a framework

By default the agent uses the framework that is installed. Only one is used at a time: if two are installed, the first to start is used. Qbox also answers to the `qb-core` name, so on a Qbox server the QBCore adapter always stays off. `atlas_selftest` says which one, and you can pick the other with the setting below.

```cfg
set atlas:framework "auto"   # auto (default), qbox, qbcore, esx or none
```

With `none`, or when no supported framework is installed, the agent sends the account id as the character id. Maps, rewind, playtime and trips keep working. Money, item and vehicle snapshots are skipped, because there is no framework to read them from.

## What the agent reads per framework

| | Qbox | QBCore | ESX |
| :--- | :--- | :--- | :--- |
| Sessions, characters, jobs, duty | Events | Events | Events |
| Gangs | Events | Events | None (ESX has jobs only) |
| Money changes | Events | Events | Events |
| Character deletion | Events | `qb-core`'s deletion log | `esx_multicharacter` requests |
| Money snapshot | `players` table | `players` table | `users` table |
| Item census | `players`, trunks, gloveboxes | `players`, `qb-inventory` trunks, gloveboxes and stashes | `users`, stashes through `ox_inventory` |
| Item events | `ox_inventory` | `qb-inventory` (2.2.3 on) | `ox_inventory` |
| Vehicles owned | `player_vehicles` | `player_vehicles` | `owned_vehicles` |
| Deaths and revives | `qbx_core` state | `isdead` and `inlaststand` metadata, respawns and check-ins from `qb-ambulancejob` | `esx_death` (ESX 1.16), or `esx_ambulancejob` (older ESX) |
| Society accounts | `Renewed-Banking` | `qb-banking` (or `qb-management` funds before it), `Renewed-Banking` | `esx_addonaccount` (and `Renewed-Banking`) |
| Places | `qbx_garages`, `qbx_ambulancejob`, `qbx_police` | `qb-garages`, `qb-ambulancejob`, `qb-policejob`, `qb-shops` | `esx_garage`, `esx_ambulancejob`, `esx_policejob`, `esx_shops` |
| Prices | `qbx_core` vehicles, `qbx_properties` | `qb-core` vehicles, `qb-shops` items | `vehicles` table, `esx_shops` items |
| Staff rank | ACE permissions (`god`, `admin`, `mod`) | ACE permissions (older releases: qb-core's own rank) | The player's ESX group |
| Admin menu actions | `qbx_adminmenu` | `qb-adminmenu` | None (ESX's admin commands send no event) |

Qbox and ESX also use `ox_inventory` shops, stashes and items when it is installed.

**Which script moved the money.** No framework tells its money event which script called it, so `money.change` never names one for framework money. Only the `money` export below records the calling resource.

**Staff.** When a player joins, when a character starts and when their rank changes, the agent sends `player.staff` with the player's staff rank (or without one when it was taken away). Qbox and QBCore rank staff with ACE permissions, read in the order of `staffAces` in `config.lua`; ESX ranks them by group, and every group but `user` counts. Atlas uses the rank to mark teleports by staff, including noclip and `/tpm`, which run on the player's game and send no event.

**Admin menus.** `qbx_adminmenu` and `qb-adminmenu` actions become `admin.action` (revive, kill, freeze, kick, ban, permission and data changes, weapons) and their teleports (go to player, bring, enter a player's vehicle) become `admin.teleport` for the player who moved. The agent makes the same permission check as the menu, so a request the menu refuses sends nothing. Chat commands such as `/goto` or `/givemoney` send no event in any framework, so only the staff rank covers them.

### QBCore notes

- **Versions.** qb-core 1.3.0 reports each change of a player's data with the part that changed; older releases send the whole player data before every change. The agent reads both, so the balance after a money change comes from qb-core itself. When neither arrives it is worked out from the last known balance.
- **Money types.** `cash`, `bank` and `crypto` count as themselves and `blackmoney` as `black_money`, which is reported in money changes only. Change the mapping in `config.lua` (`qbcore.moneyTypes`); a type left out keeps its own name.
- **Deaths.** Any ambulance script that sets the `isdead` and `inlaststand` metadata works. `qb-ambulancejob` adds hospital respawns (not counted as revives) and check-ins with the bill.
- **Deletion.** qb-core logs every deletion to `qb-log` once the rows are gone, whether or not `qb-log` runs. The agent takes that line, checks the character is gone and sends `character.delete`.
- **Items.** `qb-inventory` 2.2.3 and later have listeners, which give moves, gives, drops, uses, purchases and shop and stash visits. Item additions by scripts fire for every added item, so they are off unless `atlas:qb_createitem` is `1`. Older versions and forks such as `ps-inventory` have no listeners; there the daily census counts items, read from the `inventories` table or the older `stashitems`, `trunkitems` and `gloveboxitems` tables. Trunks and gloveboxes are named by a hash of the plate.
- **Not covered.** Vehicle purchases (the next snapshot picks them up), and trunks and gloveboxes of old `ox_inventory` releases on QBCore.
- **Table names.** Renamed tables can be set in `config.lua` (`qbcore.tables`).

### ESX notes

- **Money accounts.** `money` counts as cash and `bank` as bank. `black_money` is reported as its own money type, so dirty money never mixes with cash or shows in the city's money supply. Change the mapping in `config.lua` (`esx.accounts`): map an account to `cash`, `bank` or `crypto` to include it in money snapshots, or give it any other name to report it in money changes only. Accounts left out are not tracked.
- **Money with `ox_inventory`.** On ESX 1.16, each money change is reported twice when `ox_inventory` is installed: once as a copy of the item into the account, then as the real change. The agent sends one event for it. Older versions report it once. A move made in the inventory window, which ESX reports only as the copy, is sent as a set.
- **Older ESX.** `esx_garage` and `esx_shops` are read in both their 1.16 layout and the older single `config.lua` layout. Deaths and revives come from `esx_death` on 1.16. On older versions they come from `esx_ambulancejob`: the agent reads the dead state it sets, takes a new death from the client's death event, and tells a hospital respawn from a revive by the respawn callback. A death saved before login is not reported as new. When `esx_death` is running, it is used instead.
- **Snapshots.** ESX has no reliable change time on every setup. The agent checks whether `users.last_seen` updates with the row; if it does, snapshots read only changed rows, and if not, it sends a full money snapshot every hour (`moneyFullEveryMin`).
- **Character keys.** ESX names a character after its slot (`char1:<license>`) and gives that name to the next character made in the slot once the old one is deleted. Characters created from 23 October 2026 on are sent as the identifier plus their creation time (`char1:<license>#1761200000`), read from `users.created_at`, so a new character never inherits a deleted one's money or history. Older characters keep the plain identifier their history was recorded under. Without a fixed `created_at` column (ESX before 1.9), or with `esx.createdColumn` empty, every character keeps its plain identifier.
- **Deletion.** When `esx_multicharacter` is asked to delete a character, the agent checks a few seconds later that the slot is empty (or holds a different character) and sends `character.delete`.
- **Not covered.** ESX sends no server event when a vehicle is bought, so it shows up in the next snapshot instead.
- **Table names.** Renamed tables can be set in `config.lua` (`esx.tables`, `qbox.tables`).

## Servers with their own framework

A server with a custom framework can report its characters through exports. `character`, `logout`, `job`, `duty` and `gang` work only while no framework adapter is attached, so they never double up with one. `money` works on any server.

```lua
local atlas = exports['atlas-agent']

-- A player started playing a character. A different id ends the previous character first.
atlas:character(source, { id = 'ABC123', name = 'Ann Lee', job = 'police', grade = 2, duty = true,
    gang = 'ballas', cash = 500, bank = 12000, new = false })

atlas:job(source, 'ambulance', 1)       -- job or grade changed; a fourth argument sets duty
atlas:duty(source, false)               -- went off duty
atlas:gang(source, nil)                 -- left the gang
atlas:logout(source)                    -- stopped playing the character
atlas:money(source, -250, 'bank', 'rent')  -- money changed: amount (negative removes), type, reason
```

Only `id` is required. A player who leaves is handled by the agent.

## Adding a framework

A framework adapter is two files in `server/adapters/`, listed in `fxmanifest.lua` before the other adapters, and a spec.

1. **`<name>_data.lua`** (optional) sets `Atlas.frameworkData.<name>` to the data readers below, and registers places, prices and account sources for the resources that come with the framework.
2. **`<name>.lua`** registers the adapter and turns events into calls on the shared pipelines.

```lua
Atlas.registerFramework({
    name = 'myfw',
    resources = { 'myfw_core' },
    displacedBy = { 'other_core' },    -- optional: resources that mean another framework runs under this one's name
    attach = function() end,           -- runs when the resource is started; may error to be retried
    detach = function() end,           -- optional
    inventoryAccounts = { 'money' },   -- optional: money kept as items, left out of the item census
    selftestMoney = function(src) end, -- optional: makes a harmless money call for atlas_selftest
})
```

### Characters

Call these from the framework's events. They send the same events on every framework.

| Call | When |
| :--- | :--- |
| `Atlas.characters.load(src, c)` | A character became active. `c` has `char` (required), `name`, `job`, `grade`, `duty`, `gang`, `jobPayment`, `money` (`cash`, `bank`, `crypto`), `dead`, `isNew` and `resumed` (the character was already playing when the agent started). |
| `Atlas.characters.unload(p, reason)` | The character left: `logout`, `drop` or `switch`. A player who disconnects is handled by the agent. |
| `Atlas.characters.setJob(src, job, grade, duty, payment)` | Job or grade changed. A refresh of the same job sends nothing. |
| `Atlas.characters.setDuty(src, on)` / `setGang(src, gang)` | Duty or gang changed. |
| `Atlas.characters.markDown(src, kind)` / `markUp(src)` / `respawn(src)` | The character died or fell, was revived, or respawned at a hospital. |
| `Atlas.characters.setState(src, key, value)` | A flag changed: `isdead`, `inlaststand`, `ishandcuffed` (true or false) or `injail` (months). Sends `player.state`, and a death or revive for the two life flags. |

A character id must stay with one character for good. If the framework hands a deleted character's id to a new one, add something that tells them apart (the ESX adapter adds the creation time), and send `character.delete` when a character is deleted.

### Money

`Atlas.money.change(src, type, action, amount, balance, reason)` sends one `money.change`. The type is `cash`, `bank` or `crypto`; the action is `add`, `remove` or `set`. For `set`, the change is the new balance minus the last known one. Pass `balance` when the framework reports it.

Every account that sends changes must also be in the money snapshot, under the same type. Otherwise Atlas shows money it cannot explain.

### Data readers

Set on `Atlas.frameworkData.<name>`. A reader that is missing skips that snapshot.

| Reader | Shape |
| :--- | :--- |
| `money` | `{ delta, init?, count(since), page(since, cursor, limit) }`. Rows are `{ char, cash, bank, crypto }`. `delta` says whether `since` finds changed rows; without it the agent sends full snapshots on the `moneyFullEveryMin` cycle. |
| `census` | A function returning kinds `{ kind, order, delta, count(since), page(since, cursor, limit) }`, for example players. Rows are `{ holder id, inventory }`. A kind without `delta` is always sent in full. |
| `vehicles` | `{ census?, owned = { count(), page(cursor, limit) } }`. `census()` returns the rows of a per-model count, and is optional. Owned rows are `{ char, model hash, plate hash }`; plates are never sent. |
| `groups` | A function returning two sets: job names and gang names. |

`page` returns the rows, the cursor for the next page and how many rows the query returned, or `nil` when the query failed. Use `common.sqlName` for table names that come from the config.

### Sources

`Atlas.registerSource(kind, def)` adds data from any resource the framework works with. The source is used while all of its `resources` are started.

| Kind | `def` |
| :--- | :--- |
| `places` | `read(add)`, where `add(name, kind, coords)` suggests a place. |
| `prices` | `read(emit)`, where `emit(kind, entries)` sends price entries. |
| `accounts` | `read()` returning `{ id, kind, amount }` rows, or `nil` and an error. |
| `census` | An inventory kind such as stashes, with the same fields as a `census` reader kind. |

`Atlas.loadConfig(resource, path, globals)` reads another resource's plain-data config file safely.

### Tests

Run `lua5.4 tests/run.lua`. `tests/qbcore_spec.lua`, `tests/esx_spec.lua` and `tests/esx_data_spec.lua` show how to fake a framework and cover events, money and snapshots. `tests/manifest_spec.lua` loads every script in manifest order.
