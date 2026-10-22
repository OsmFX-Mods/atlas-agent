-- Qbox adapter: turns qbx_core events into Atlas events (built against qbx_core 1.23.0).
-- Data: the database readers for snapshots, and the places and prices Qbox resources provide, are in qbox_data.lua.

local cfg = AtlasConfig
local NAME = 'qbox'
local qbx = exports.qbx_core
local C = Atlas.characters

local STATE_KEYS = { isdead = true, inlaststand = true, ishandcuffed = true, injail = true }

local function active() return Atlas.enabled and Atlas.adapterActive(NAME) end

local accountChars = {} -- accountChars: each player's account characters and names, used to confirm deletions

--- Character start: reads the character facts Atlas needs and hands them to the shared character pipeline.
local function charStart(src, pd, resumed)
    local p = Atlas.ensurePlayer(src)
    if not p then return end
    local job = type(pd.job) == 'table' and pd.job or {}
    local gang = type(pd.gang) == 'table' and pd.gang or {}
    local md = type(pd.metadata) == 'table' and pd.metadata or {}
    local state = {
        isdead = md.isdead == true,
        inlaststand = md.inlaststand == true,
        ishandcuffed = md.ishandcuffed == true,
        injail = md.injail,
    }
    p = C.load(src, {
        char = pd.citizenid,
        name = Atlas.qb.charName(pd),
        job = job.name,
        grade = type(job.grade) == 'table' and job.grade.level or nil,
        duty = job.onduty == true,
        jobPayment = job.payment,
        gang = (gang.name and gang.name ~= 'none') and gang.name or nil,
        money = type(pd.money) == 'table' and pd.money or nil,
        dead = state.isdead or state.inlaststand,
        -- New character: qbx sets lastLoggedOut on every save, so a character without it was never saved
        isNew = pd.lastLoggedOut == nil,
        resumed = resumed,
    })
    if not p then return end
    p.state = state
    if accountChars[src] then accountChars[src][p.char] = p.charName end
end

-- PlayerLoaded: runs after login; sends session.char_start, plus character.create for new characters.
AddEventHandler('QBCore:Server:PlayerLoaded', function(player)
    if not active() or type(player) ~= 'table' then return end
    local pd = player.PlayerData
    if type(pd) ~= 'table' or not pd.source or not pd.citizenid then return end
    local src = tonumber(pd.source)
    local p = Atlas.players[src]
    if p and p.char == pd.citizenid then return end
    if p and p.char then C.unload(p, 'switch') end
    charStart(src, pd, false)
end)

-- OnPlayerUnload: fired by Logout(); emits session.char_end with reason 'logout'.
AddEventHandler('QBCore:Server:OnPlayerUnload', function(src)
    if not active() then return end
    local p = Atlas.players[tonumber(src)]
    if p then C.unload(p, 'logout') end
end)

Atlas.onDrop(function(p)
    accountChars[p.src] = nil
end)

-- OnMoneyChange: emits money.change for online players only.
AddEventHandler('QBCore:Server:OnMoneyChange', function(src, mtype, amount, action, reason)
    if not active() then return end
    src = tonumber(src)
    -- Balance: qbx has already applied the change when this event fires
    local ok, bal = pcall(qbx.GetMoney, qbx, src, mtype)
    Atlas.money.change(src, mtype, action, amount, ok and tonumber(bal) or nil, reason)
end)

-- OnJobUpdate: primary job or grade changes; emits job.change.
AddEventHandler('QBCore:Server:OnJobUpdate', function(src, job)
    if not active() or type(job) ~= 'table' then return end
    C.setJob(src, job.name, type(job.grade) == 'table' and job.grade.level or nil, job.onduty == true, job.payment)
end)

-- SetDuty: fired by SetJobDuty(); emits duty.change.
AddEventHandler('QBCore:Server:SetDuty', function(src, onDuty)
    if not active() then return end
    C.setDuty(src, onDuty)
end)

-- OnGangUpdate: primary gang changes; emits gang.change.
AddEventHandler('QBCore:Server:OnGangUpdate', function(src, gang)
    if not active() or type(gang) ~= 'table' then return end
    C.setGang(src, (gang.name and gang.name ~= 'none') and gang.name or nil)
end)

-- onSetMetaData: emits player.state, combat.death and medical.revive.
AddEventHandler('qbx_core:server:onSetMetaData', function(key, old, value, src)
    if not active() or not STATE_KEYS[key] then return end
    if key ~= 'injail' and old == value then return end
    C.setState(tonumber(src), key, value)
end)

-- Character deletion: qbx_core only offers an ox_lib callback and an old net event for it.
-- Check: the character must belong to the player's account and be gone from the database.
local function fetchAccountChars(src)
    local set = Atlas.qb.accountChars(cfg.qbox.tables.characters, Atlas.players[src])
    if set then accountChars[src] = set end
end

Atlas.onJoin(function(p)
    if Atlas.adapterActive(NAME) then CreateThread(function() fetchAccountChars(p.src) end) end
end)

local checking = {} -- checking: characters being checked, so repeated requests cost one query

local function onDeleteRequest(src, citizenId)
    if not active() or type(citizenId) ~= 'string' or checking[citizenId] then return end
    local owned = accountChars[src]
    if not owned or owned[citizenId] == nil then return end -- Kept by reference, so a drop during the wait still counts
    local name = owned[citizenId]
    local player = Atlas.players[src] -- player: compared after the wait, since the id can be reused by someone else
    checking[citizenId] = true
    CreateThread(function()
        Wait(cfg.deleteCheckMs)
        local gone = Atlas.qb.gone(cfg.qbox.tables.characters, citizenId)
        checking[citizenId] = nil
        if gone and owned[citizenId] ~= nil then
            owned[citizenId] = nil
            Atlas.emit('character.delete', { char = citizenId, char_name = name ~= '' and name or nil }, Atlas.players[src] == player and src or nil)
        end
    end)
end

RegisterNetEvent('__ox_cb_qbx_core:server:deleteCharacter', function(_, _, citizenId)
    onDeleteRequest(source, citizenId)
end)

RegisterNetEvent('qbx_core:server:deleteCharacter', function(citizenId)
    onDeleteRequest(source, citizenId)
end)

Atlas.registerFramework({
    name = NAME,
    resources = { 'qbx_core' },
    attach = function()
        -- Probe: a missing export throws, which makes detect.lua retry
        local version = qbx:GetCoreVersion()
        Atlas.debug('qbx_core %s', tostring(version))
        -- Loaded characters: picks up characters already loaded when the agent starts
        CreateThread(function()
            for _, s in ipairs(GetPlayers()) do
                local src = tonumber(s)
                local ok, player = pcall(qbx.GetPlayer, qbx, src)
                if ok and type(player) == 'table' and type(player.PlayerData) == 'table' then
                    local p = Atlas.players[src]
                    if not (p and p.char == player.PlayerData.citizenid) then
                        charStart(src, player.PlayerData, true)
                    end
                end
                fetchAccountChars(src)
            end
        end)
    end,
})
