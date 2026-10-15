-- Money: the shared money pipeline that framework adapters feed, so money.change looks the same on every framework.
-- Types: cash, bank and crypto are the slots money snapshots carry; a framework maps its own accounts onto them.

local M = {}
Atlas.money = M

--- Delta: works out the change of a balance and keeps the last known balance up to date.
--- Add and remove carry their own amount; a set carries the new balance, so its delta is the new balance minus the last known one.
--- @param balance number? balance after the change, when the framework can tell
--- @param last number? balance before a set, when the caller knows better than the cache
--- @return number? delta, nil for a set without a known earlier balance
function M.apply(p, mtype, action, amount, balance, last)
    local delta
    if action == 'add' then delta = amount
    elseif action == 'remove' then delta = -amount
    else
        last = last or (p and p.money[mtype])
        local new = balance or amount
        delta = last and (new - last) or nil
    end
    if p and (balance or action == 'set') then p.money[mtype] = balance or amount end
    return delta
end

--- Emit: sends money.change for a player, stamped with `at` when the change happened earlier.
function M.emit(src, p, mtype, action, amount, delta, balance, reason, at)
    if reason == 'atlas_selftest' then Atlas.selftestMoneySeen = true end
    Atlas.emit('money.change', {
        mtype = mtype,
        action = action,
        amount = amount,
        delta = delta,
        balance_after = balance,
        reason = type(reason) == 'string' and reason:sub(1, 128) or 'unknown',
        job_payment = p and p.jobPayment or nil,
    }, src, { fresh = true, at = at })
end

--- Change: records a balance change of an online player and emits it.
function M.change(src, mtype, action, amount, balance, reason)
    local p = Atlas.players[src]
    amount = tonumber(amount) or 0
    local delta = M.apply(p, mtype, action, amount, balance)
    M.emit(src, p, mtype, action, amount, delta, balance, reason)
end

local flushers = {} -- flushers: callbacks that send changes an adapter is still holding for a player

--- On flush: registers a callback that sends the changes held for a player.
function M.onFlush(fn) flushers[#flushers + 1] = fn end

--- Flush: runs before a character unloads, so held changes keep their character.
function M.flush(src)
    for i = 1, #flushers do pcall(flushers[i], src) end
end

--- Online balances: live balances of online characters, which override the saved ones in a money snapshot.
function Atlas.onlineBalances()
    local out = {}
    for _, p in pairs(Atlas.players) do
        if p.char and p.money and p.money.bank then out[p.char] = p.money end
    end
    return out
end
