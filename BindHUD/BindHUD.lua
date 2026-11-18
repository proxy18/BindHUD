--[[
    BindHUD - on-screen overlay of your keyboard binds.

    Reads the binds from:
      * Windower scripts/init.txt (and any scripts it `exec`s)
      * the GearSwap file GearSwap loads for your current job, plus
        everything it include()s, any `_Gear` sidecar and *globals*.lua files
    and draws them in one of two views:
      * keyboard   - a full keyboard in real key positions; every bound key
                     lists all its binds with a coloured modifier letter
      * cheatsheet - every action grouped by kind, alphabetical, with its keys
    Holding Ctrl/Alt/Shift/Win highlights that layer. In peek mode the overlay
    only appears while a modifier is held.

    Display-only: no packets, no game commands, nothing in the chat log.
]]

_addon.name = 'BindHUD'
_addon.author = 'ffxiHotbar'
_addon.version = '0.2.0'
_addon.commands = { 'bindhud', 'bh' }

local config = require('config')
local texts = require('texts')
local bp = require('bindparse')

local defaults = {
    visible = true,
    view = 'keyboard',         -- 'keyboard' | 'cheatsheet'
    peek = false,              -- false: always shown; true: only while a modifier is held
    peek_delay = 0.25,         -- seconds a modifier must be held before peek shows
    numpad = 'auto',           -- 'auto' (only when a numpad key is bound) | 'on' | 'off'
    key_width = 0,             -- label characters per key; 0 = automatic (up to 10)
    include_init = true,       -- read scripts/init.txt
    follow_includes = true,    -- follow include() in GearSwap files
    extra_files = '',          -- comma separated, {name} and {job} are substituted
    display = {                -- the title bar (also the drag handle)
        pos = { x = 100, y = 300 },
        bg = { alpha = 200, red = 8, green = 10, blue = 14, visible = true },
        flags = { draggable = true, bold = false },
        padding = 4,
        text = {
            font = 'Consolas', size = 10, alpha = 255, red = 230, green = 230, blue = 230,
            stroke = { width = 1, alpha = 200, red = 0, green = 0, blue = 0 },
        },
    },
}

local settings = config.load(defaults)
-- Dragging is handled by Windower's texts library (the same way Skillchains does it),
-- which also saves the new position when you let go.
settings.display.flags.draggable = true
local box = texts.new('', settings.display, settings)

local COLORS = {
    title   = { 255, 215, 120 },
    cap     = { 150, 200, 255 },
    cap_dim = { 95, 105, 125 },
    dim     = { 95, 100, 110 },
    active  = { 120, 255, 120 },
    group   = { 170, 175, 190 },
    -- bind categories
    spell   = { 159, 211, 255 },
    ability = { 255, 227, 163 },
    toggle  = { 255, 173, 102 },
    cycle   = { 212, 173, 255 },
    set     = { 127, 227, 198 },
    other   = { 201, 204, 214 },
    -- modifier letters
    ctrl    = { 108, 182, 255 },
    alt     = { 126, 224, 126 },
    shift   = { 255, 209, 102 },
    win     = { 224, 140, 255 },
    apps    = { 200, 200, 200 },
    none    = { 122, 130, 146 },
}

local state = {
    binds = {},       -- "combo|key" -> bind
    files = {},       -- { path, short, count }
    logged_in = false,
    combo = '',       -- modifier combo currently held
    peek_ready = false,
    job = '',
}

-------------------------------------------------------------------------------
-- File helpers
-------------------------------------------------------------------------------
local root = windower.windower_path:gsub('\\', '/')
if root:sub(-1) ~= '/' then root = root .. '/' end
local gs_root = root .. 'addons/GearSwap/'

local function read_file(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local s = f:read('*a')
    f:close()
    return s
end

local function short(path)
    if path:sub(1, #root):lower() == root:lower() then return path:sub(#root + 1) end
    return path
end

-- Messages go to the Windower console only (never the in-game chat log).
local function msg(text)
    print('[BindHUD] ' .. text)
end

-- Same search order GearSwap uses: <name>/, common/, data/, then libs.
local function gs_find(names, player_name)
    local bases = {
        gs_root .. 'data/' .. player_name .. '/', gs_root .. 'data/common/', gs_root .. 'data/',
        gs_root .. 'libs/', root .. 'addons/libs/',
    }
    for _, base in ipairs(bases) do
        for _, n in ipairs(names) do
            if windower.file_exists(base .. n) then return base .. n end
        end
    end
end

-------------------------------------------------------------------------------
-- Scanning
-------------------------------------------------------------------------------
local function rescan(verbose)
    local player = windower.ffxi.get_player()
    if not player then return end

    local name, job, sub = player.name, player.main_job or '', player.sub_job or ''
    local job_full = player.main_job_full or job
    local vars = {
        ['player.name'] = name,
        ['player.main_job'] = job,
        ['player.sub_job'] = sub,
        ['player.main_job_full'] = job_full,
        ['player.sub_job_full'] = player.sub_job_full or sub,
    }

    local collected, files, seen = {}, {}, {}
    local do_lua, do_script

    local function add_all(list)
        for _, b in ipairs(list) do collected[#collected + 1] = b end
    end

    local function first_visit(path)
        local k = path:lower()
        if seen[k] then return false end
        seen[k] = true
        return true
    end

    function do_script(path)
        if not first_visit(path) then return end
        local src = read_file(path)
        if not src then return end
        local binds, execs = bp.parse_script(src, short(path))
        files[#files + 1] = { short = short(path), count = #binds }
        add_all(binds)
        for _, e in ipairs(execs) do
            if not e:find('%.') then e = e .. '.txt' end
            do_script(root .. 'scripts/' .. e)
        end
    end

    function do_lua(path)
        if not first_visit(path) then return end
        local src = read_file(path)
        if not src then return end
        local binds, includes, execs = bp.parse_lua(src, vars, short(path))
        files[#files + 1] = { short = short(path), count = #binds }
        -- Included libraries load first, so this file's own binds win on conflicts.
        if settings.follow_includes then
            for _, inc in ipairs(includes) do
                local names = { inc }
                if not inc:lower():match('%.lua$') then names[2] = inc .. '.lua' end
                local p = gs_find(names, name)
                if p then do_lua(p) end
            end
        end
        add_all(binds)
        for _, e in ipairs(execs) do
            if not e:find('%.') then e = e .. '.txt' end
            do_script(root .. 'scripts/' .. e)
        end
    end

    if settings.include_init then
        do_script(root .. 'scripts/init.txt')
    end

    -- Globals files (e.g. Globals.lua, Name-Globals.lua, user-globals.lua) next to the job luas.
    -- Loaded before the job file so job binds win on conflicts. Skips other characters'
    -- globals (e.g. "Othername-Globals.lua") when multi-boxing.
    for _, dir in ipairs({ gs_root .. 'data/', gs_root .. 'data/' .. name .. '/' }) do
        local entries = windower.dir_exists(dir) and windower.get_dir(dir) or {}
        table.sort(entries)
        for _, fname in ipairs(entries) do
            local lower = fname:lower()
            if lower:match('%.lua$') and lower:find('globals', 1, true) then
                local prefix = lower:match('^(.-)[%-_ ]?globals') or ''
                if prefix == '' or prefix == name:lower() or prefix == 'user' then
                    do_lua(dir .. fname)
                end
            end
        end
    end

    local job_file = gs_find({
        name .. '_' .. job .. '.lua', name .. '-' .. job .. '.lua',
        name .. '_' .. job_full .. '.lua', name .. '-' .. job_full .. '.lua',
        name .. '.lua', job .. '.lua', job_full .. '.lua', 'default.lua',
    }, name)
    if job_file then do_lua(job_file) end

    local sidecar = gs_find({
        name .. '_' .. job .. '_Gear.lua', name .. '-' .. job .. '_Gear.lua', job .. '_Gear.lua',
    }, name)
    if sidecar then do_lua(sidecar) end

    for entry in tostring(settings.extra_files or ''):gmatch('[^,]+') do
        entry = bp.trim(entry):gsub('{name}', name):gsub('{job}', job)
        if entry ~= '' then
            local p = gs_find({ entry }, name) or (windower.file_exists(root .. entry) and root .. entry)
                or (windower.file_exists(entry) and entry)
            if p and p:lower():match('%.txt$') then do_script(p) elseif p then do_lua(p) end
        end
    end

    -- Later binds override earlier ones for the same key + modifiers.
    local binds = {}
    for _, b in ipairs(collected) do binds[b.combo .. '|' .. b.key] = b end

    state.binds, state.files, state.job = binds, files, job .. (sub ~= '' and ('/' .. sub) or '')

    if verbose then
        local n = 0
        for _ in pairs(binds) do n = n + 1 end
        msg(('%d binds from %d files.%s'):format(n, #files,
            job_file and '' or ' (No GearSwap job file found for ' .. job .. ')'))
    end
end

-------------------------------------------------------------------------------
-- Drawing objects. Rectangles are windower.prim, text is windower.text. They are
-- pooled by id and reused between redraws; ids are handed out in draw order so a
-- key's rectangle is always created before (and so drawn under) its text.
-------------------------------------------------------------------------------
local PREFIX = 'bindhud_'
local pool = { prim = {}, text = {} }   -- names created so far
local used = { prim = {}, text = {} }   -- names drawn in the current frame
local next_id = 0

local function cs(c) return ('\\cs(%d,%d,%d)'):format(c[1], c[2], c[3]) end
local function color(s, c) return cs(c) .. s .. '\\cr' end
local function px(v) return math.floor(v + 0.5) end

local function rect(x, y, w, h, c, alpha)
    next_id = next_id + 1
    local name = PREFIX .. 'p' .. next_id
    if not pool.prim[name] then
        windower.prim.create(name)
        pool.prim[name] = true
    end
    windower.prim.set_position(name, px(x), px(y))
    windower.prim.set_size(name, px(w), px(h))
    windower.prim.set_color(name, alpha, c[1], c[2], c[3])
    windower.prim.set_visibility(name, true)
    used.prim[name] = true
end

local function setup_text(name)
    windower.text.create(name)
    windower.text.set_bg_visibility(name, false)
    windower.text.set_stroke_width(name, 1)
    windower.text.set_stroke_color(name, 200, 0, 0, 0)
    windower.text.set_color(name, 255, 230, 230, 230)
end

local function label(x, y, str)
    next_id = next_id + 1
    local name = PREFIX .. 't' .. next_id
    if not pool.text[name] then
        setup_text(name)
        pool.text[name] = true
    end
    windower.text.set_font(name, settings.display.text.font)
    windower.text.set_font_size(name, settings.display.text.size)
    windower.text.set_location(name, px(x), px(y))
    windower.text.set_text(name, str)
    windower.text.set_visibility(name, true)
    used.text[name] = true
end

local function begin_frame()
    used = { prim = {}, text = {} }
    next_id = 0
end

local function end_frame()
    for name in pairs(pool.prim) do
        if not used.prim[name] then windower.prim.set_visibility(name, false) end
    end
    for name in pairs(pool.text) do
        if not used.text[name] and name ~= PREFIX .. 'probe' then windower.text.set_visibility(name, false) end
    end
end

local function destroy_all()
    for name in pairs(pool.prim) do windower.prim.delete(name) end
    for name in pairs(pool.text) do windower.text.delete(name) end
    pool = { prim = {}, text = {} }
end

-------------------------------------------------------------------------------
-- Font metrics: measured from an invisible probe text so key sizes match the
-- real font in game. Falls back to an estimate until the probe has a size.
-------------------------------------------------------------------------------
local metrics = { size = nil, cw = nil, lh = nil }
local PROBE = PREFIX .. 'probe'

local function measure()
    local size = settings.display.text.size
    if metrics.size == size and metrics.cw then return true end
    if not pool.text[PROBE] then
        setup_text(PROBE)
        windower.text.set_color(PROBE, 0, 0, 0, 0)
        windower.text.set_stroke_width(PROBE, 0)
        windower.text.set_location(PROBE, 0, 0)
        windower.text.set_text(PROBE, ('M'):rep(20) .. '\nM\nM\nM')
        windower.text.set_visibility(PROBE, true)
        pool.text[PROBE] = true
    end
    windower.text.set_font(PROBE, settings.display.text.font)
    windower.text.set_font_size(PROBE, size)
    local w, h = windower.text.get_extents(PROBE)
    if w and w > 0 and h and h > 0 then
        metrics.size, metrics.cw, metrics.lh = size, w / 20, h / 4
        return true
    end
    -- Estimate (Consolas is ~0.55em wide; Windower sizes are points).
    metrics.size, metrics.cw, metrics.lh = nil, size * 0.74, size * 1.6
    return false
end

-------------------------------------------------------------------------------
-- Keyboard layout: a standard full-size keyboard. Each entry is { key, width in
-- key units }; false = empty slot. '@' keys are modifiers (drawn, lit when held).
-------------------------------------------------------------------------------
local FULL_ROWS = {
    { gap_after = true,
      main = { {'escape',1},{false,1},{'f1',1},{'f2',1},{'f3',1},{'f4',1},{false,.5},{'f5',1},{'f6',1},{'f7',1},{'f8',1},{false,.5},{'f9',1},{'f10',1},{'f11',1},{'f12',1} },
      nav  = { {'sysrq',1},{'scrolllock',1},{'pause',1} },
      pad  = { {false,4} } },
    { main = { {'`',1},{'1',1},{'2',1},{'3',1},{'4',1},{'5',1},{'6',1},{'7',1},{'8',1},{'9',1},{'0',1},{'-',1},{'=',1},{'backspace',2} },
      nav  = { {'insert',1},{'home',1},{'pageup',1} },
      pad  = { {'numlock',1},{'numpad/',1},{'numpad*',1},{'numpad-',1} } },
    { main = { {'tab',1.5},{'q',1},{'w',1},{'e',1},{'r',1},{'t',1},{'y',1},{'u',1},{'i',1},{'o',1},{'p',1},{'[',1},{']',1},{'\\',1.5} },
      nav  = { {'delete',1},{'end',1},{'pagedown',1} },
      pad  = { {'numpad7',1},{'numpad8',1},{'numpad9',1},{'numpad+',1} } },
    { main = { {'capslock',1.75},{'a',1},{'s',1},{'d',1},{'f',1},{'g',1},{'h',1},{'j',1},{'k',1},{'l',1},{';',1},{"'",1},{'enter',2.25} },
      nav  = { {false,3} },
      pad  = { {'numpad4',1},{'numpad5',1},{'numpad6',1},{false,1} } },
    { main = { {'@shift',2.25},{'z',1},{'x',1},{'c',1},{'v',1},{'b',1},{'n',1},{'m',1},{',',1},{'.',1},{'/',1},{'@shift',2.75} },
      nav  = { {false,1},{'up',1},{false,1} },
      pad  = { {'numpad1',1},{'numpad2',1},{'numpad3',1},{'numpadenter',1} } },
    { main = { {'@ctrl',1.25},{'@win',1.25},{'@alt',1.25},{'space',6.25},{'@alt',1.25},{'@win',1.25},{'@apps',1.25},{'@ctrl',1.25} },
      nav  = { {'left',1},{'down',1},{'right',1} },
      pad  = { {'numpad0',2},{'numpad.',1},{false,1} } },
}
local NAV_KEYS = { sysrq = true, scrolllock = true, pause = true, insert = true, home = true, pageup = true,
    delete = true, ['end'] = true, pagedown = true, up = true, down = true, left = true, right = true }
local MOD_NAMES = { ctrl = 'Ctrl', alt = 'Alt', shift = 'Shift', win = 'Win', apps = 'Menu' }
local BADGE = { ctrl = 'C', alt = 'A', shift = 'S', win = 'W', apps = 'M' }

local CAP = {
    backspace = 'Bksp', delete = 'Del', insert = 'Ins', home = 'Home', ['end'] = 'End', pageup = 'PgUp',
    pagedown = 'PgDn', pause = 'Pause', scrolllock = 'ScrLk', sysrq = 'PrtSc', escape = 'Esc', enter = 'Enter',
    tab = 'Tab', capslock = 'Caps', space = 'Space', numlock = 'NumLk', up = 'Up', down = 'Down', left = 'Left',
    right = 'Right', numpadenter = 'Enter', ['numpad/'] = '/', ['numpad*'] = '*', ['numpad-'] = '-',
    ['numpad+'] = '+', ['numpad.'] = '.',
}
local function cap_label(k)
    if CAP[k] then return CAP[k] end
    local n = k:match('^numpad(%d)$')
    if n then return n end
    return bp.key_label(k)
end

local function mods_of(combo)
    local list = {}
    for m in combo:gmatch('[^+]+') do list[#list + 1] = m end
    return list
end

-- Coloured modifier letters, padded to `width` characters ("-" = no modifier).
local function badge(combo, width, dim)
    local mods = mods_of(combo)
    local s, n = '', 0
    if #mods == 0 then
        s, n = color('-', dim and COLORS.dim or COLORS.none), 1
    else
        for _, m in ipairs(mods) do
            s = s .. color(BADGE[m] or '?', dim and COLORS.dim or COLORS[m] or COLORS.none)
            n = n + 1
        end
    end
    return s .. (' '):rep(math.max(0, width - n))
end

-- All binds as a list with readable label + category, sorted by modifiers.
local function bind_list()
    local list = {}
    for _, b in pairs(state.binds) do
        if not b.text then b.text, b.cat = bp.describe(b.command) end
        list[#list + 1] = b
    end
    return list
end

local function title_text(view_name)
    local layer = state.combo
    local t = color('BindHUD  ' .. state.job, COLORS.title)
    if layer ~= '' then t = t .. color('  holding ' .. bp.combo_label(layer), COLORS.active) end
    t = t .. color('  [' .. view_name .. ']', COLORS.dim)
    local legend = color('- none ', COLORS.none) .. color('C Ctrl ', COLORS.ctrl) .. color('A Alt ', COLORS.alt)
        .. color('S Shift ', COLORS.shift) .. color('W Win', COLORS.win) .. '   '
        .. color('spell ', COLORS.spell) .. color('ability ', COLORS.ability) .. color('toggle ', COLORS.toggle)
        .. color('cycle ', COLORS.cycle) .. color('mode ', COLORS.set) .. color('other', COLORS.other)
    return t .. '\n' .. legend
end

-------------------------------------------------------------------------------
-- Keyboard view
-------------------------------------------------------------------------------
local KEY_PAD_X, KEY_PAD_Y, GAP = 4, 2, 3

local function draw_keyboard(ox, oy)
    local layer = state.combo
    local by_key, labels, max_mods = {}, {}, 1
    local has_pad, has_nav = false, false
    for _, b in ipairs(bind_list()) do
        by_key[b.key] = by_key[b.key] or {}
        table.insert(by_key[b.key], b)
        labels[#labels + 1] = b.text
        max_mods = math.max(max_mods, #mods_of(b.combo))
        if b.key:match('^numpad') or b.key == 'numlock' then has_pad = true end
        if NAV_KEYS[b.key] then has_nav = true end
    end
    for _, list in pairs(by_key) do
        table.sort(list, function(a, b) return bp.combo_less(a.combo, b.combo) end)
    end
    local show_pad = settings.numpad == 'on' or (settings.numpad == 'auto' and has_pad)

    local bw = max_mods + 1                         -- badge column, in characters
    -- Label column, in characters: fixed by //bh keywidth, or the smallest width
    -- (up to 10) that fits every label in two lines.
    local w = (tonumber(settings.key_width) or 0) > 0 and tonumber(settings.key_width)
        or bp.pick_width(labels, 7, 10, 2)
    local cw, lh = metrics.cw, metrics.lh
    local unit = (bw + w) * cw + 2 * KEY_PAD_X      -- width of a 1u key in pixels
    local function kw(u) return u * (unit + GAP) - GAP end
    local block_gap = unit * 0.35

    -- Text for each bound key, and the number of lines it needs.
    local function key_text(k)
        local list = by_key[k]
        local lit = false
        local out = { color(cap_label(k), COLORS.cap) }
        for _, b in ipairs(list) do
            local dim = layer ~= '' and b.combo ~= layer
            if layer ~= '' and b.combo == layer then lit = true end
            local c = dim and COLORS.dim or COLORS[b.cat] or COLORS.other
            for i, line in ipairs(bp.wrap(b.text, w)) do
                local lead = i == 1 and badge(b.combo, bw, dim) or (' '):rep(bw)
                out[#out + 1] = lead .. color(line, c)
            end
        end
        return table.concat(out, '\n'), #out, lit
    end

    -- Pass 1: row heights (every key in a keyboard row shares one height).
    local blocks = { 'main' }
    if has_nav then blocks[#blocks + 1] = 'nav' end
    if show_pad then blocks[#blocks + 1] = 'pad' end
    local rows = {}
    for i, row in ipairs(FULL_ROWS) do
        local lines = 1
        for _, blk in ipairs(blocks) do
            for _, slot in ipairs(row[blk]) do
                local k = slot[1]
                if k and by_key[k] then
                    local _, n = key_text(k)
                    lines = math.max(lines, n)
                end
            end
        end
        rows[i] = { h = lines * lh + 2 * KEY_PAD_Y, gap_after = row.gap_after }
    end

    -- Block x offsets.
    local x_of = { main = ox }
    local x = ox + kw(15) + block_gap
    if has_nav then x_of.nav = x; x = x + kw(3) + block_gap end
    if show_pad then x_of.pad = x; x = x + kw(4) + block_gap end
    local total_w = x - block_gap - ox
    local total_h = 0
    for _, r in ipairs(rows) do total_h = total_h + r.h + GAP + (r.gap_after and 6 or 0) end

    -- Board background, then keys.
    rect(ox - 6, oy - 4, total_w + 12, total_h + 8, { 8, 10, 14 }, 200)
    local y = oy
    for i, row in ipairs(FULL_ROWS) do
        local h = rows[i].h
        for _, blk in ipairs(blocks) do
            local kx = x_of[blk]
            for _, slot in ipairs(row[blk]) do
                local k, u = slot[1], slot[2]
                local width = kw(u)
                if k and k:sub(1, 1) == '@' then
                    local m = k:sub(2)
                    local on = state.combo ~= '' and state.combo:find(m, 1, true) ~= nil
                    rect(kx, y, width, h, on and { 50, 120, 60 } or { 30, 33, 40 }, on and 235 or 140)
                    label(kx + KEY_PAD_X, y + KEY_PAD_Y, color(MOD_NAMES[m] or m, on and COLORS.active or COLORS.cap_dim))
                elseif k and by_key[k] then
                    local str, _, lit = key_text(k)
                    rect(kx, y, width, h, lit and { 38, 82, 48 } or { 48, 55, 70 }, 230)
                    label(kx + KEY_PAD_X, y + KEY_PAD_Y, str)
                elseif k then
                    rect(kx, y, width, h, { 36, 40, 48 }, 120)
                    label(kx + KEY_PAD_X, y + KEY_PAD_Y, color(cap_label(k), COLORS.cap_dim))
                end
                kx = kx + width + GAP
            end
        end
        y = y + h + GAP + (rows[i].gap_after and 6 or 0)
    end
end

-------------------------------------------------------------------------------
-- Cheat sheet view: grouped by kind, alphabetical, with the keys to press.
-------------------------------------------------------------------------------
local GROUPS = {
    { 'spell', 'SPELLS' }, { 'ability', 'ABILITIES & WS' }, { 'toggle', 'TOGGLES' },
    { 'cycle', 'CYCLES' }, { 'set', 'MODES' }, { 'other', 'OTHER' },
}

local function draw_cheatsheet(ox, oy)
    local layer = state.combo
    local list = bind_list()
    local name_w = 4
    for _, b in ipairs(list) do name_w = math.max(name_w, #b.text) end

    -- Build lines as { text = coloured string, len = visible length }.
    local entries = {}   -- one entry per group: list of lines
    for _, g in ipairs(GROUPS) do
        local items = {}
        for _, b in ipairs(list) do if b.cat == g[1] then items[#items + 1] = b end end
        if #items > 0 then
            table.sort(items, function(a, b) return a.text:lower() < b.text:lower() end)
            local lines = { { text = color(g[2], COLORS[g[1]]), len = #g[2] } }
            for _, b in ipairs(items) do
                local dim = layer ~= '' and b.combo ~= layer
                local parts, plain = {}, {}
                for _, m in ipairs(mods_of(b.combo)) do
                    parts[#parts + 1] = color(MOD_NAMES[m] or m, dim and COLORS.dim or COLORS[m])
                    plain[#plain + 1] = MOD_NAMES[m] or m
                end
                parts[#parts + 1] = color(cap_label(b.key), dim and COLORS.dim or COLORS.cap)
                plain[#plain + 1] = cap_label(b.key)
                local keys = table.concat(parts, color('+', COLORS.dim))
                local name = b.text .. (' '):rep(name_w - #b.text)
                lines[#lines + 1] = {
                    text = color(name, dim and COLORS.dim or COLORS[g[1]]) .. '  ' .. keys,
                    len = name_w + 2 + #table.concat(plain, '+'),
                }
            end
            entries[#entries + 1] = lines
        end
    end

    -- Split groups into up to 3 balanced columns (groups are never split).
    local total = 0
    for _, e in ipairs(entries) do total = total + #e + 1 end
    local ncol = math.max(1, math.min(3, math.ceil(total / 14)))
    local target = math.ceil(total / ncol)
    local cols, cur, count = {}, {}, 0
    for _, e in ipairs(entries) do
        if count > 0 and count + #e > target and #cols < ncol - 1 then
            cols[#cols + 1] = cur
            cur, count = {}, 0
        end
        for _, l in ipairs(e) do cur[#cur + 1] = l end
        cur[#cur + 1] = { text = '', len = 0 }
        count = count + #e + 1
    end
    cols[#cols + 1] = cur

    local cw, lh = metrics.cw, metrics.lh
    local col_gap = cw * 3
    local widths, max_lines = {}, 0
    for i, c in ipairs(cols) do
        local wmax = 0
        for _, l in ipairs(c) do wmax = math.max(wmax, l.len) end
        widths[i] = wmax * cw
        max_lines = math.max(max_lines, #c)
    end
    local total_w = -col_gap
    for _, wv in ipairs(widths) do total_w = total_w + wv + col_gap end

    rect(ox - 6, oy - 4, total_w + 12, max_lines * lh + 8, { 8, 10, 14 }, 200)
    local x = ox
    for i, c in ipairs(cols) do
        local strs = {}
        for _, l in ipairs(c) do strs[#strs + 1] = l.text end
        label(x, oy, table.concat(strs, '\n'))
        x = x + widths[i] + col_gap
    end
end

-------------------------------------------------------------------------------
-- Render
-------------------------------------------------------------------------------
local retry_pending = false

local function should_show()
    if not settings.visible or not state.logged_in then return false end
    if next(state.binds) == nil then return false end
    if settings.peek then return state.combo ~= '' and state.peek_ready end
    return true
end

local function render()
    if not should_show() then
        box:hide()
        begin_frame()
        end_frame()
        return
    end

    local measured = measure()
    local view = settings.view == 'cheatsheet' and 'cheatsheet' or 'keyboard'
    box:text(title_text(view))
    box:show()

    -- The board sits just under the title bar.
    local bx, by = box:pos()
    local _, bh = box:extents()
    if not bh or bh <= 0 then
        bh = 2 * metrics.lh + 2 * (settings.display.padding or 4)
        measured = false
    end
    local ox, oy = bx + 6, by + bh + 8

    begin_frame()
    if view == 'cheatsheet' then draw_cheatsheet(ox, oy) else draw_keyboard(ox, oy) end
    end_frame()

    -- Font sizes are only known after Windower has laid the text out once;
    -- redraw shortly with the real measurements.
    if not measured and not retry_pending then
        retry_pending = true
        coroutine.schedule(function()
            retry_pending = false
            render()
        end, 0.2)
    end
end

-- Moving the title bar moves the board with it.
box:register_event('drag', function() render() end)

-------------------------------------------------------------------------------
-- Held-modifier tracking (watch only; keys are never blocked)
-------------------------------------------------------------------------------
local MOD_DIK = {
    [0x1D] = 'ctrl', [0x9D] = 'ctrl', [0x38] = 'alt', [0xB8] = 'alt',
    [0x2A] = 'shift', [0x36] = 'shift', [0xDB] = 'win', [0xDC] = 'win', [0xDD] = 'apps',
}
local held_dik = {}
local peek_token = 0

windower.register_event('keyboard', function(dik, pressed)
    local m = MOD_DIK[dik]
    if not m then return end
    if (held_dik[dik] == true) == (pressed == true) then return end
    held_dik[dik] = pressed and true or nil
    local mods = {}
    for d in pairs(held_dik) do mods[MOD_DIK[d]] = true end
    local combo = bp.combo_id(mods)
    if combo == state.combo then return end

    local was_empty = state.combo == ''
    state.combo = combo
    if combo == '' then
        state.peek_ready = false
    elseif was_empty and settings.peek then
        -- Peek: only show once the modifier has been held for a moment, so a
        -- quick Ctrl+key press doesn't flash the overlay.
        state.peek_ready = false
        peek_token = peek_token + 1
        local token = peek_token
        coroutine.schedule(function()
            if token == peek_token and state.combo ~= '' then
                state.peek_ready = true
                render()
            end
        end, settings.peek_delay or 0.25)
    end
    render()
end)

-------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------
local scan_token = 0
local function schedule_rescan(delay)
    scan_token = scan_token + 1
    local token = scan_token
    coroutine.schedule(function()
        if token == scan_token then
            rescan(false)
            render()
        end
    end, delay)
end

windower.register_event('load', function()
    local info = windower.ffxi.get_info()
    state.logged_in = info and info.logged_in or false
    if state.logged_in then
        rescan(false)
        render()
    end
end)

windower.register_event('login', function()
    state.logged_in = true
    schedule_rescan(3)
end)

windower.register_event('logout', function()
    state.logged_in = false
    state.binds = {}
    render()
end)

windower.register_event('job change', function()
    schedule_rescan(2)
end)

windower.register_event('unload', function()
    destroy_all()
    config.save(settings)
end)

-------------------------------------------------------------------------------
-- Commands
-------------------------------------------------------------------------------
local HELP = {
    '//bh                 show or hide the overlay',
    '//bh view            switch between keyboard and cheat sheet',
    '//bh peek            switch between always shown and peek (only while holding a modifier)',
    '//bh size <n>        text size (keys resize to fit)',
    '//bh keywidth <n>|auto    label characters per key (smaller = narrower keyboard)',
    '//bh numpad auto|on|off   numpad block: only when bound (auto), always, or never',
    '//bh pos <x> <y>     move the overlay (or drag its title bar)',
    '//bh rescan          re-read your files after editing binds',
    '//bh files           list the files that were read',
}

local function save_pos()
    local bx, by = box:pos()
    settings.display.pos.x, settings.display.pos.y = bx, by
    config.save(settings)
end

windower.register_event('addon command', function(cmd, ...)
    cmd = (cmd or 'toggle'):lower()
    local args = { ... }
    local arg = (args[1] or ''):lower()

    if cmd == 'toggle' then
        settings.visible = not settings.visible
    elseif cmd == 'show' then
        settings.visible = true
    elseif cmd == 'hide' then
        settings.visible = false
    elseif cmd == 'view' then
        if arg == 'keyboard' or arg == 'kb' then
            settings.view = 'keyboard'
        elseif arg == 'cheatsheet' or arg == 'list' or arg == 'sheet' then
            settings.view = 'cheatsheet'
        else
            settings.view = settings.view == 'keyboard' and 'cheatsheet' or 'keyboard'
        end
        msg('View: ' .. settings.view)
    elseif cmd == 'peek' then
        if arg == 'on' then settings.peek = true
        elseif arg == 'off' then settings.peek = false
        else settings.peek = not settings.peek end
        msg(settings.peek and 'Peek: shows only while you hold a modifier.' or 'Always shown.')
    elseif cmd == 'size' and tonumber(args[1]) then
        local n = math.max(6, math.min(30, tonumber(args[1])))
        settings.display.text.size = n
        box:size(n)
    elseif cmd == 'numpad' and (arg == 'auto' or arg == 'on' or arg == 'off') then
        settings.numpad = arg
    elseif cmd == 'keywidth' and (arg == 'auto' or tonumber(args[1])) then
        settings.key_width = arg == 'auto' and 0 or math.max(5, math.min(20, math.floor(tonumber(args[1]))))
    elseif cmd == 'pos' and tonumber(args[1]) and tonumber(args[2]) then
        box:pos(tonumber(args[1]), tonumber(args[2]))
        save_pos()
        render()
        return
    elseif cmd == 'rescan' or cmd == 'reload' or cmd == 'refresh' then
        rescan(true)
    elseif cmd == 'files' then
        if #state.files == 0 then msg('No files read yet.') end
        for _, f in ipairs(state.files) do msg(('%s  (%d binds)'):format(f.short, f.count)) end
        return
    else
        for _, line in ipairs(HELP) do msg(line) end
        return
    end

    config.save(settings)
    render()
end)
