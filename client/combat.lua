-- Client combat: counts shots per weapon and 25 m cell, sent as a latent event every 15 s or on holster (6 s minimum gap).
-- Trust: the server validates each report (server/client_reports.lua) and labels accepted ones trust = "client".

local UNARMED = `WEAPON_UNARMED`
local CELL = 25.0
local MAX_CELLS = 60      -- MAX_CELLS: per-weapon cap, kept under the server cap of 64
local SEND_EVERY = 15000
local SEND_MIN_GAP = 6000 -- SEND_MIN_GAP: the server accepts one report per 5 s

local agg, cellCount, pending = {}, {}, false
local windowStart, lastSend = GetGameTimer(), 0

local function add(weapon, coords)
    local cx, cy = math.floor(coords.x / CELL), math.floor(coords.y / CELL)
    local w = agg[weapon]
    if not w then w = {}; agg[weapon] = w; cellCount[weapon] = 0 end
    local key = cx * 1000 + cy
    local c = w[key]
    if c then
        c[3] = c[3] + 1
    elseif cellCount[weapon] < MAX_CELLS then
        w[key] = { cx, cy, 1 }
        cellCount[weapon] = cellCount[weapon] + 1
    end
    pending = true
end

local function flush()
    local now = GetGameTimer()
    local reports = {}
    for weapon, cells in pairs(agg) do
        local list = {}
        for _, c in pairs(cells) do list[#list + 1] = c end
        if #list > 0 then reports[#reports + 1] = { weapon = weapon, cells = list } end
        if #reports >= 8 then break end
    end
    if #reports > 0 then
        local window = math.max(1, math.min(60, math.ceil((now - windowStart) / 1000)))
        TriggerLatentServerEvent('atlas:c:shots', 2048, { window_s = window, reports = reports })
    end
    agg, cellCount, pending = {}, {}, false
    windowStart, lastSend = now, now
end

CreateThread(function()
    -- Token check: once per session; a readable atlas:token means it was set with setr, and only its hash is reported
    local token = GetConvar('atlas:token', '')
    if token ~= '' then
        TriggerServerEvent('atlas:c:env', { tokenHash = GetHashKey(token) })
    end
    token = nil

    while true do
        if not GlobalState.atlasClientCombat then
            Wait(5000)
        else
            local ped = PlayerPedId()
            local weapon = GetSelectedPedWeapon(ped)
            local now = GetGameTimer()
            if weapon == 0 or weapon == UNARMED then
                -- Holstered: sends what is pending, within the server rate limit
                if pending and now - lastSend >= SEND_MIN_GAP then flush() end
                if not pending then windowStart = GetGameTimer() end
                Wait(500)
            else
                if not pending then windowStart = now end
                -- Armed: checks shooting every frame for 250 ms, then re-checks the weapon
                local untilT = now + 250
                repeat
                    if IsPedShooting(ped) then add(weapon, GetEntityCoords(ped)) end
                    Wait(0)
                until GetGameTimer() >= untilT
                if pending and GetGameTimer() - lastSend >= SEND_EVERY then flush() end
            end
        end
    end
end)
