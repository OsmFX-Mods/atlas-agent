-- Console capture: sends script errors, warnings and hitch lines from the server console as console.lines events.
-- Speed: the listener runs for every console line, so it creates nothing unless a line is kept.

local cfg = AtlasConfig
local find = string.find

local lines, count = {}, 0
local errorAt = {}         -- errorAt: game time of the last SCRIPT ERROR per channel

--- Case-blind pattern: turns a word into a pattern that matches it in any letter case.
local function caseBlind(word)
    return (word:gsub('.', function(c)
        if c:find('%a') then return '[' .. c:lower() .. c:upper() .. ']' end
        if c:find('%p') then return '%' .. c end
        return c
    end))
end

local words = {}           -- words: patterns for cfg.consoleWords
for i = 1, #cfg.consoleWords do words[i] = caseBlind(cfg.consoleWords[i]) end

--- Matches: whether the text contains one of the configured words.
local function matches(text)
    for i = 1, #words do
        if find(text, words[i]) then return true end
    end
    return false
end

--- Stack line: a line that follows a SCRIPT ERROR on the same channel.
local function continues(channel, text)
    local at = errorAt[channel]
    if not at or GetGameTimer() - at > cfg.consoleStackMs then return false end
    return find(text, '^%s*>') or find(text, '^%s*stack traceback:') or find(text, '^%s*at ') or find(text, '^%s*in function')
end

local function onLine(channel, text)
    if not Atlas.enabled or type(text) ~= 'string' then return end
    channel = channel or ''
    local isError = find(text, 'SCRIPT ERROR', 1, true)
    if not (isError or matches(text) or continues(channel, text)) then return end
    if count >= cfg.consoleMaxLines then
        Atlas.drop('console_cap')
        return
    end
    count = count + 1
    lines[count] = { ts = Atlas.now(), c = channel, t = #text > cfg.consoleMaxChars and text:sub(1, cfg.consoleMaxChars) or text }
    if isError then errorAt[channel] = GetGameTimer() end
end

-- Flush: one event per second with the kept lines; old error markers are removed.
local function flush()
    local gt = GetGameTimer()
    for channel, at in pairs(errorAt) do
        if gt - at > cfg.consoleStackMs then errorAt[channel] = nil end
    end
    if count == 0 then return end
    local out = lines
    lines, count = {}, 0
    Atlas.emit('console.lines', { lines = out })
end

-- State: if the RegisterConsoleListener native is missing or fails, capture reports 'unsupported'.
local function register()
    if not cfg.console then return 'off' end
    if type(RegisterConsoleListener) ~= 'function' then return 'unsupported' end
    return pcall(RegisterConsoleListener, onLine) and 'on' or 'unsupported'
end

Atlas.consoleState = register()

if Atlas.consoleState == 'on' then
    CreateThread(function()
        while true do
            Wait(1000)
            flush()
        end
    end)
elseif Atlas.consoleState == 'unsupported' then
    Atlas.log('console capture is off: this server does not provide RegisterConsoleListener')
end
