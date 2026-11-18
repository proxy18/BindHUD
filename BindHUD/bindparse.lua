--[[
    bindparse.lua
    Pure-Lua helpers (no Windower APIs) that pull key binds out of
    GearSwap .lua files and Windower .txt scripts (e.g. init.txt).
]]

local M = {}

-- Windower bind modifier prefixes.
local MOD_CHARS = { ['^'] = 'ctrl', ['!'] = 'alt', ['~'] = 'shift', ['@'] = 'win', ['#'] = 'apps' }
-- '%' = only when chat is closed, '$' = only when chat is open. Not modifiers.
local FLAG_CHARS = { ['%'] = true, ['$'] = true }

M.MOD_ORDER = { 'ctrl', 'alt', 'shift', 'win', 'apps' }
local MOD_RANK = {}
for i, m in ipairs(M.MOD_ORDER) do MOD_RANK[m] = i end

local MOD_LABEL = { ctrl = 'Ctrl', alt = 'Alt', shift = 'Shift', win = 'Win', apps = 'Apps' }

local function trim(s) return (s:gsub('^%s+', ''):gsub('%s+$', '')) end
M.trim = trim

-------------------------------------------------------------------------------
-- Combos (a set of modifiers) <-> canonical id strings like "ctrl+alt"
-------------------------------------------------------------------------------
function M.combo_id(mods)
    local parts = {}
    for _, m in ipairs(M.MOD_ORDER) do
        if mods[m] then parts[#parts + 1] = m end
    end
    return table.concat(parts, '+')
end

function M.combo_label(id)
    if id == '' then return 'No mod' end
    local parts = {}
    for m in id:gmatch('[^+]+') do parts[#parts + 1] = MOD_LABEL[m] or m end
    return table.concat(parts, '+')
end

-- Sort key for combos: fewer modifiers first, then Ctrl < Alt < Shift < Win.
function M.combo_less(a, b)
    local function info(id)
        local n, rank = 0, 0
        for m in id:gmatch('[^+]+') do
            n = n + 1
            rank = rank * 10 + (MOD_RANK[m] or 9)
        end
        return n, rank
    end
    local na, ra = info(a)
    local nb, rb = info(b)
    if na ~= nb then return na < nb end
    return ra < rb
end

-------------------------------------------------------------------------------
-- Keys: display names and keyboard ordering
-------------------------------------------------------------------------------
local KEY_NAMES = {
    backspace = 'Bksp', delete = 'Del', insert = 'Ins', home = 'Home', ['end'] = 'End',
    pageup = 'PgUp', pagedown = 'PgDn', pause = 'Pause', sysrq = 'PrtSc', escape = 'Esc',
    enter = 'Enter', ['return'] = 'Enter', space = 'Space', tab = 'Tab', capslock = 'Caps',
    scrolllock = 'ScrLk', numlock = 'NumLk', up = 'Up', down = 'Down', left = 'Left', right = 'Right',
    numpadenter = 'NumEnt', ['numpad/'] = 'Num /', ['numpad*'] = 'Num *', ['numpad-'] = 'Num -',
    ['numpad+'] = 'Num +', ['numpad.'] = 'Num .',
}

function M.key_label(key)
    if KEY_NAMES[key] then return KEY_NAMES[key] end
    local n = key:match('^numpad(%d)$')
    if n then return 'Num ' .. n end
    local f = key:match('^f(%d+)$')
    if f then return 'F' .. f end
    if #key == 1 then return key:upper() end
    return key:sub(1, 1):upper() .. key:sub(2)
end

local KEY_ORDER = {}
do
    local list = { 'escape' }
    for i = 1, 12 do list[#list + 1] = 'f' .. i end
    for _, k in ipairs({ '`', '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '-', '=', 'backspace',
        'tab', 'q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p', '[', ']', '\\',
        'capslock', 'a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l', ';', "'", 'enter',
        'z', 'x', 'c', 'v', 'b', 'n', 'm', ',', '.', '/', 'space',
        'sysrq', 'scrolllock', 'pause', 'insert', 'home', 'pageup', 'delete', 'end', 'pagedown',
        'up', 'left', 'down', 'right', 'numlock', 'numpad/', 'numpad*', 'numpad-', 'numpad+' }) do
        list[#list + 1] = k
    end
    for i = 0, 9 do list[#list + 1] = 'numpad' .. i end
    list[#list + 1] = 'numpad.'
    list[#list + 1] = 'numpadenter'
    for i, k in ipairs(list) do KEY_ORDER[k] = i end
end

function M.key_less(a, b)
    local ra, rb = KEY_ORDER[a] or 1000, KEY_ORDER[b] or 1000
    if ra ~= rb then return ra < rb end
    return a < b
end

-------------------------------------------------------------------------------
-- Command -> short label, kind ('action' | 'gs' | 'other')
-------------------------------------------------------------------------------
local ACTION_VERBS = {
    ma = true, magic = true, ja = true, jobability = true, ws = true, weaponskill = true,
    item = true, pet = true, petcommand = true, ra = true, ninjutsu = true, nin = true,
    song = true, so = true, ms = true, monsterskill = true, mount = true, trigger = true,
    target = true, ta = true, assist = true, follow = true, equipset = true, lockstyleset = true,
}

local function split_words(s)
    local w = {}
    for word in s:gmatch('%S+') do w[#w + 1] = word end
    return w
end

function M.label(cmd)
    local c = trim(cmd)

    -- input /ma "Cure IV" <t>   |   /ja Provoke <t>
    local slash = c:match('^input%s+(/.*)$') or c:match('^(/.*)$')
    if slash then
        local verb, args = slash:match('^/(%S+)%s*(.*)$')
        if verb and (verb:lower() == 'target' or verb:lower() == 'ta') and args ~= '' then
            return 'Target ' .. args, 'action'
        end
        if verb and ACTION_VERBS[verb:lower()] then
            local name = args:match('^"([^"]+)"') or args:match("^'([^']+)'") or args:match('^(%S+)')
            if name then return name, 'action' end
        end
        return slash, 'other'
    end

    -- gs c cycle OffenseMode / gs c toggle AutoCaress / gs c set X Y
    local gsc = c:match('^gs%s+c%s+(.+)$') or c:match('^gearswap%s+c%s+(.+)$')
    if gsc then
        local w = split_words(gsc)
        -- "AutoStunMode" -> "AutoStun" keeps labels short.
        if w[2] and #w[2] > 6 then w[2] = w[2]:gsub('[Mm]ode$', '') end
        local verb = (w[1] or ''):lower()
        local label = gsc
        if verb == 'cycle' and w[2] then label = 'Cyc ' .. w[2]
        elseif verb == 'cycleback' and w[2] then label = 'Cyc< ' .. w[2]
        elseif verb == 'toggle' and w[2] then label = 'Tog ' .. w[2]
        elseif verb == 'set' and w[2] and w[3] then label = w[2] .. '=' .. table.concat(w, ' ', 3)
        elseif verb == 'reset' and w[2] then label = 'Reset ' .. w[2]
        end
        return label, 'gs'
    end

    local set = c:match('^gs%s+equip%s+(%S+)')
    if set then return 'Equip ' .. set:gsub('^sets%.', ''), 'gs' end

    return c, 'other'
end

-------------------------------------------------------------------------------
-- "bind <keyspec> [up] <command>" -> bind record
-------------------------------------------------------------------------------
function M.parse_bind(line)
    local rest = line:match('^%s*bind%s+(.+)$')
    if not rest then return nil end
    local keyspec, cmd = rest:match('^(%S+)%s*(.*)$')
    -- Skip string.format templates like "bind %s ..." / "bind %s%s ...".
    if not keyspec or keyspec:find('%%[sdq]') then return nil end

    local mods = {}
    local i = 1
    -- The last character is always part of the key (e.g. "!=" is Alt + '=').
    while i < #keyspec do
        local ch = keyspec:sub(i, i)
        if MOD_CHARS[ch] then
            mods[MOD_CHARS[ch]] = true
        elseif not FLAG_CHARS[ch] then
            break
        end
        i = i + 1
    end
    local key = keyspec:sub(i):lower():gsub('\\\\', '\\')
    -- Skip template junk like "bind %s ..." built by string.format.
    if key == '' or key:find('%%') then return nil end

    local up = false
    local first = cmd:match('^(%S+)')
    if first == 'up' or first == 'down' then
        up = (first == 'up')
        cmd = cmd:gsub('^%S+%s*', '')
    end
    cmd = trim(cmd)
    if cmd == '' then return nil end

    return { key = key, mods = mods, combo = M.combo_id(mods), command = cmd, up = up }
end

-- Split "a;b;c" on semicolons that are not inside double quotes.
function M.split_commands(s)
    local out, buf, inq = {}, {}, false
    for i = 1, #s do
        local ch = s:sub(i, i)
        if ch == '"' then inq = not inq end
        if ch == ';' and not inq then
            out[#out + 1] = table.concat(buf)
            buf = {}
        else
            buf[#buf + 1] = ch
        end
    end
    out[#out + 1] = table.concat(buf)
    return out
end

-- Handles one console command string; returns bind or exec target (or nothing).
local function scan_command(seg, binds, execs, src)
    seg = trim(seg)
    local b = M.parse_bind(seg)
    if b then
        b.source = src
        binds[#binds + 1] = b
        return
    end
    local ex = seg:match('^exec%s+(%S+)')
    if ex then execs[#execs + 1] = ex end
end

-------------------------------------------------------------------------------
-- Minimal Lua tokenizer: strings, identifiers (with dots), "..", punctuation.
-- Comments are dropped so commented-out binds are ignored.
-------------------------------------------------------------------------------
local ESC = { n = '\n', t = '\t', r = '\r', a = '\a', b = '\b', f = '\f', v = '\v',
    ['\\'] = '\\', ['"'] = '"', ["'"] = "'", ['\n'] = '\n' }

function M.tokenize(src)
    local tokens = {}
    local i, n = 1, #src
    while i <= n do
        local c = src:sub(i, i)
        if c:match('%s') then
            i = i + 1
        elseif c == '-' and src:sub(i + 1, i + 1) == '-' then
            local lvl = src:match('^%[(=*)%[', i + 2)
            if lvl then
                local close = ']' .. lvl .. ']'
                local e = src:find(close, i + 4 + #lvl, true)
                i = e and (e + #close) or (n + 1)
            else
                local e = src:find('\n', i, true)
                i = e and (e + 1) or (n + 1)
            end
        elseif c == '"' or c == "'" then
            local j, buf = i + 1, {}
            while j <= n do
                local d = src:sub(j, j)
                if d == '\\' then
                    local e = src:sub(j + 1, j + 1)
                    if ESC[e] then
                        buf[#buf + 1] = ESC[e]; j = j + 2
                    elseif e:match('%d') then
                        local digits = src:match('^%d%d?%d?', j + 1)
                        buf[#buf + 1] = string.char(tonumber(digits) % 256)
                        j = j + 1 + #digits
                    else
                        buf[#buf + 1] = e; j = j + 2
                    end
                elseif d == c or d == '\n' then
                    break
                else
                    buf[#buf + 1] = d; j = j + 1
                end
            end
            tokens[#tokens + 1] = { t = 'str', v = table.concat(buf) }
            i = j + 1
        elseif c == '[' and src:match('^%[=*%[', i) then
            local lvl = src:match('^%[(=*)%[', i)
            local start = i + 2 + #lvl
            local close = ']' .. lvl .. ']'
            local e = src:find(close, start, true)
            local s = src:sub(start, (e or (n + 1)) - 1):gsub('^\r?\n', '')
            tokens[#tokens + 1] = { t = 'str', v = s }
            i = e and (e + #close) or (n + 1)
        elseif c:match('[%a_]') then
            local j = i
            local id = src:match('^[%a_][%w_]*', j)
            j = j + #id
            while src:sub(j, j) == '.' and src:sub(j + 1, j + 1):match('[%a_]') do
                local part = src:match('^[%a_][%w_]*', j + 1)
                id = id .. '.' .. part
                j = j + 1 + #part
            end
            tokens[#tokens + 1] = { t = 'id', v = id }
            i = j
        elseif c:match('%d') then
            local num = src:match('^%d[%w]*', i)
            tokens[#tokens + 1] = { t = 'num', v = num }
            i = i + #num
        elseif src:sub(i, i + 1) == '..' then
            tokens[#tokens + 1] = { t = '..' }
            i = i + 2
        else
            tokens[#tokens + 1] = { t = c }
            i = i + 1
        end
    end
    return tokens
end

-- Resolve "a" .. player.main_job .. "_Gear.lua" style expressions.
local function resolve_expr(parts, vars)
    local out = {}
    for _, tok in ipairs(parts) do
        if tok.t == 'str' then
            out[#out + 1] = tok.v
        elseif tok.t == 'id' and vars[tok.v] then
            out[#out + 1] = vars[tok.v]
        elseif tok.t ~= '..' then
            return nil
        end
    end
    if #out == 0 then return nil end
    return table.concat(out)
end

local INCLUDE_FUNCS = { include = true, optional_include = true }

-- Returns names passed to include()/optional_include() that can be resolved.
local function find_includes(tokens, vars)
    local found = {}
    local i = 1
    while i <= #tokens do
        local tok = tokens[i]
        if tok.t == 'id' and INCLUDE_FUNCS[tok.v] then
            local nxt = tokens[i + 1]
            if nxt and nxt.t == 'str' then
                found[#found + 1] = nxt.v
                i = i + 2
            elseif nxt and nxt.t == '(' then
                local depth, j, cur = 1, i + 2, {}
                local function flush()
                    local name = resolve_expr(cur, vars)
                    if name then found[#found + 1] = name end
                    cur = {}
                end
                while j <= #tokens and depth > 0 do
                    local t = tokens[j]
                    if t.t == '(' then
                        depth = depth + 1; cur[#cur + 1] = { t = '?' }
                    elseif t.t == ')' then
                        depth = depth - 1
                        if depth > 0 then cur[#cur + 1] = { t = '?' } end
                    elseif t.t == ',' and depth == 1 then
                        flush()
                    elseif t.t ~= '{' and t.t ~= '}' then
                        cur[#cur + 1] = t
                    end
                    j = j + 1
                end
                flush()
                i = j
            else
                i = i + 1
            end
        else
            i = i + 1
        end
    end
    return found
end

-------------------------------------------------------------------------------
-- Public parsers
-------------------------------------------------------------------------------

-- Parse GearSwap lua source. Returns binds, includes, execs.
function M.parse_lua(src, vars, source_name)
    local tokens = M.tokenize(src)
    local binds, execs = {}, {}
    for _, tok in ipairs(tokens) do
        if tok.t == 'str' and (tok.v:find('bind', 1, true) or tok.v:find('exec', 1, true)) then
            for _, seg in ipairs(M.split_commands(tok.v)) do
                scan_command(seg, binds, execs, source_name)
            end
        end
    end
    return binds, find_includes(tokens, vars or {}), execs
end

-- Parse a Windower script (init.txt etc). Returns binds, execs.
function M.parse_script(src, source_name)
    local binds, execs = {}, {}
    for line in (src .. '\n'):gmatch('([^\r\n]*)\r?\n') do
        local l = trim(line)
        if l ~= '' and not l:match('^//') and not l:match('^%-%-') then
            -- In scripts a backslash is written as "\\" just like in the console.
            for _, seg in ipairs(M.split_commands(l)) do
                scan_command(seg, binds, execs, source_name)
            end
        end
    end
    return binds, execs
end

return M
