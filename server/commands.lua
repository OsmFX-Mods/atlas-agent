-- Commands: console only, or ACE command.atlas_bench and command.atlas_selftest.
-- atlas_bench [n] shows what the agent costs; atlas_selftest [id] checks token, connection, adapters, database, clock.

local function out(fmt, ...) print(('^5[atlas]^7 ' .. fmt):format(...)) end
local function mark(ok) return ok and '^2OK^7  ' or '^1FAIL^7' end

local function fmtUs(ns) return ('%.2f'):format((ns or 0) / 1000) end

RegisterCommand('atlas_bench', function(source, args)
    local st = Atlas.stats
    local upS = math.max(1, (GetGameTimer() - st.startedAt) / 1000)
    local js = Atlas.js or {}

    out('--- atlas_bench (uptime %.0f s, %d players) ---', upS, #Atlas.playerList)
    out('emit      : %d events (%.1f/s), avg %s us, recent avg %.2f us, max %s us',
        st.emits, st.emits / upS, fmtUs(st.emits > 0 and st.emitNs / st.emits or 0), st.emitEmaUs, fmtUs(st.emitMaxNs))
    out('sampler   : %d slices, avg %s us/slice, max %s us, %d samples (sample_ms %d)',
        st.samplerRuns, fmtUs(st.samplerRuns > 0 and st.samplerNs / st.samplerRuns or 0), fmtUs(st.samplerMaxNs),
        st.samples, AtlasConfig.sampleMs)
    out('flush     : %d flushes, %d events, avg %s us/flush',
        st.flushes, st.flushed, fmtUs(st.flushes > 0 and st.flushNs / st.flushes or 0))
    -- CPU: adds up the time spent in emit, sampler and flush; time inside event handlers is not counted
    local agentMsPerS = (st.emitNs + st.samplerNs + st.flushNs) / 1e6 / upS
    out('agent CPU : %.3f ms per second (~%.4f ms per 50 ms server tick)', agentMsPerS, agentMsPerS / 20)
    out('lua queue : %d buffered', Atlas.bufferDepth())
    out('js        : state=%s memory=%s inflight=%s spool=%s files/%s events/%.1f MB, acked seq %s, serialize %.2f us/event',
        tostring(js.state), tostring(js.mem), tostring(js.inflight), tostring(js.spoolFiles), tostring(js.spoolEvents),
        (js.spoolBytes or 0) / 1048576, tostring(js.ackedSeq), js.serializeUsAvg or 0)
    local drops = {}
    for k, v in pairs(Atlas.drops) do drops[#drops + 1] = ('%s=%d'):format(k, v) end
    for k, v in pairs(js.drops or {}) do drops[#drops + 1] = ('js.%s=%d'):format(k, v) end
    out('drops     : %s', #drops > 0 and table.concat(drops, ', ') or 'none')

    local count = tonumber(args[1])
    if count and count > 0 then
        count = math.min(count, 1000000)
        local avg, max = Atlas.benchEmit(count, Atlas.playerList[1])
        out('synthetic : %d emits, avg %.3f us, max %.1f us (budget < 5 us)', count, avg, max)
    end
end, true)

RegisterCommand('atlas_selftest', function(source, args)
    CreateThread(function()
        out('--- atlas_selftest ---')
        local token = GetConvar('atlas:token', '') ~= ''
        out('%s token set%s', mark(token and not Atlas.refused), Atlas.refused and (' (refused: ' .. Atlas.refused .. ')') or '')

        local js = Atlas.js
        local jsAlive = js and (GetGameTimer() - (js.receivedAt or 0)) < 5000
        out('%s transport.js alive (state %s, endpoint %s)', mark(jsAlive),
            js and tostring(js.state) or '?', js and tostring(js.endpoint) or '?')
        if js and js.lastError then out('     last transport error: %s', js.lastError) end

        -- Clock: checks the clock was lined up to the second
        out('%s clock calibrated to the second edge', mark(Atlas.clock.calibrated))
        if Atlas.db.available() then
            local t0 = GetGameTimer()
            local dbNow = Atlas.db.now()
            out('%s oxmysql reachable (%d ms)', mark(dbNow ~= nil), GetGameTimer() - t0)
            if dbNow then
                local skew = Atlas.now() - dbNow * 1000
                out('%s agent vs DB clock skew %d ms', mark(math.abs(skew) < 2000), math.floor(skew))
            end
        else
            out('%s oxmysql not started (snapshots disabled)', mark(false))
        end

        -- Adapters: reports each supported resource as attached or skipped
        for _, res in ipairs({ 'qbx_core', 'ox_inventory', 'qbx_vehicles', 'qbx_medical', 'qbx_ambulancejob', 'Renewed-Banking' }) do
            local state = GetResourceState(res)
            local name = res == 'qbx_core' and 'qbox' or res == 'Renewed-Banking' and 'renewed_banking' or res
            if state == 'started' then
                out('%s adapter %s attached', mark(Atlas.adapterActive(name)), name)
            else
                out('     adapter %s skipped (%s is %s)', name, res, state)
            end
        end

        -- Sampler: counts samples taken while waiting one interval
        local before = Atlas.stats.samples
        Wait(math.min(AtlasConfig.sampleMs + 500, 5000))
        local sampled = Atlas.stats.samples - before
        out('%s sampler running (%d samples in the last few seconds, %d players)',
            mark(#Atlas.playerList == 0 or sampled > 0), sampled, #Atlas.playerList)

        -- Money path: a 0-amount AddMoney should reach the Qbox money hook
        local src = tonumber(args[1])
        if src and Atlas.adapterActive('qbox') then
            Atlas.selftestMoneySeen = false
            local ok = pcall(function() return exports.qbx_core:AddMoney(src, 'cash', 0, 'atlas_selftest') end)
            Wait(200)
            out('%s qbx money hook fires (player %s)', mark(ok and Atlas.selftestMoneySeen), src)
        end

        -- End to end: sends a marker event and waits up to 15 s for Atlas to confirm it
        local seq = Atlas.emit('custom.atlas_selftest', { at = os.time() })
        local deadline, acked = GetGameTimer() + 15000, false
        while seq and GetGameTimer() < deadline do
            local j = Atlas.js
            if j and j.ackedBoot == Atlas.boot and (tonumber(j.ackedSeq) or 0) >= seq then acked = true break end
            Wait(250)
        end
        out('%s Atlas confirmed a test event (seq %s)', mark(acked), tostring(seq))
        out('--- done ---')
    end)
end, true)
