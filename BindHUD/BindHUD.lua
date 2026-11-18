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
_addon.author = 'BindHUD'
_addon.version = '0.3.0'
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
    key_width = 0,             -- label characters per key; 0 = automatic
    fit_width = 65,            -- keep the keyboard within this % of the screen width; 0 = no fitting
    fit_height = 45,           -- ...and this % of the screen height
    show_targets = false,      -- show targeting binds (/ta, /target), e.g. alliance targeting on F1-F6
    layout = 'packed',         -- 'packed': only bound keys, in keyboard order | 'full': every key in its real position
    opacity = 50,              -- 1-100: how solid the overlay is (100 = fully solid)
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
    key_name = { 255, 255, 255 },
    dim     = { 95, 100, 110 },
    active  = { 120, 255, 120 },
    group   = { 170, 175, 190 },
    -- bind categories
    spell   = { 110, 190, 255 },   -- blue
    ability = { 255, 215, 110 },   -- gold (job abilities, weapon skills, items)
    auto    = { 255, 140, 70 },    -- orange (Auto... toggles and settings)
    command = { 205, 170, 255 },   -- violet (everything else)
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
-- Overlay opacity as a 0-1 factor (//bh opacity, 1-100).
local function opacity()
    local o = tonumber(settings.opacity) or 50
    return math.max(1, math.min(100, o)) / 100
end

local PREFIX = 'bindhud_'
local draw_size = nil                   -- text size for this redraw (can be shrunk to fit the screen)
local pool = { prim = {}, text = {} }   -- names created so far
local used = { prim = {}, text = {} }   -- names drawn in the current frame
local next_id = 0

local function cs(c) return ('\\cs(%d,%d,%d)'):format(c[1], c[2], c[3]) end
-- Windower treats "\" as the start of a colour code, so a literal backslash
-- (the \ key, or one inside a command) has to be doubled.
local function color(s, c) return cs(c) .. s:gsub('\\', '\\\\') .. '\\cr' end
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
    windower.prim.set_color(name, math.floor(alpha * opacity() + 0.5), c[1], c[2], c[3])
    windower.prim.set_visibility(name, true)
    used.prim[name] = true
end

local function setup_text(name)
    windower.text.create(name)
    windower.text.set_bg_visibility(name, false)
    -- No outline: every label sits on a solid key/board background, and an
    -- outline on small text is what makes it look grainy.
    windower.text.set_stroke_width(name, 0)
    windower.text.set_color(name, 255, 230, 230, 230)
end

local function label(x, y, str, bold)
    next_id = next_id + 1
    local name = PREFIX .. 't' .. next_id
    if not pool.text[name] then
        setup_text(name)
        pool.text[name] = true
    end
    windower.text.set_font(name, settings.display.text.font)
    windower.text.set_font_size(name, draw_size or settings.display.text.size)
    windower.text.set_bold(name, bold == true)
    windower.text.set_color(name, math.floor(255 * opacity() + 0.5), 230, 230, 230)
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

-- The game's UI resolution (what overlay positions are measured in). This is
-- different for every player, so layouts are fitted to it rather than assumed.
local function screen_size()
    local ok, ws = pcall(windower.get_windower_settings)
    if ok and type(ws) == 'table' and tonumber(ws.ui_x_res) then
        return tonumber(ws.ui_x_res), tonumber(ws.ui_y_res) or 1080
    end
    return 1920, 1080
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

-- Targeting binds (/ta, /target), e.g. alliance targeting on Ctrl/Alt+F1-F6.
local function is_targeting(cmd)
    local c = cmd:lower()
    return c:match('^input%s+/ta%s') or c:match('^input%s+/target%s') or c:match('^/ta%s') or c:match('^/target%s')
end

-- All binds to show, each with a readable label + category.
local function bind_list()
    local list = {}
    for _, b in pairs(state.binds) do
        if settings.show_targets or not is_targeting(b.command) then
            if not b.text then b.text, b.cat = bp.describe(b.command) end
            list[#list + 1] = b
        end
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
        .. color('spell  ', COLORS.spell) .. color('job ability  ', COLORS.ability)
        .. color('auto  ', COLORS.auto) .. color('command', COLORS.command)
    return t .. '\n' .. legend
end

-------------------------------------------------------------------------------
-- Keyboard view
-------------------------------------------------------------------------------
local KEY_PAD_X, KEY_PAD_Y, GAP = 4, 2, 3

local function draw_keyboard(ox, oy)
    local layer = state.combo
    local packed = settings.layout ~= 'full'
    local by_key, labels = {}, {}
    local has_pad, has_nav = false, false
    for _, b in ipairs(bind_list()) do
        by_key[b.key] = by_key[b.key] or {}
        table.insert(by_key[b.key], b)
        labels[#labels + 1] = b.text
        if b.key:match('^numpad') or b.key == 'numlock' then has_pad = true end
        if NAV_KEYS[b.key] then has_nav = true end
    end
    for _, list in pairs(by_key) do
        table.sort(list, function(a, b) return bp.combo_less(a.combo, b.combo) end)
    end
    local show_pad = settings.numpad == 'on' or (settings.numpad == 'auto' and has_pad)
    local blocks = { 'main' }
    if has_nav then blocks[#blocks + 1] = 'nav' end
    if show_pad then blocks[#blocks + 1] = 'pad' end
    local BLOCK_UNITS = { main = 15, nav = 3, pad = 4 }

    -- The keys to draw, row by row: { k, blk, at (key units from the block's
    -- left edge), u (width in key units) }.
    --   packed: in the main block only bound keys, side by side, all 1 unit
    --           wide; rows with no binds anywhere are dropped. The numpad and
    --           the Ins/Del/arrow block keep their real grid (they are small and
    --           known by position).
    --   full:   every key in its real position.
    local function pack(blk) return packed and blk == 'main' end
    local rows, block_units = {}, {}
    for _, blk in ipairs(blocks) do block_units[blk] = pack(blk) and 0 or BLOCK_UNITS[blk] end
    for _, row in ipairs(FULL_ROWS) do
        local keys, any = {}, false
        for _, blk in ipairs(blocks) do
            local at = 0
            for _, slot in ipairs(row[blk]) do
                local k, u = slot[1], slot[2]
                if pack(blk) then
                    if k and by_key[k] then
                        keys[#keys + 1] = { k = k, blk = blk, at = at, u = 1 }
                        at = at + 1
                    end
                else
                    if k then keys[#keys + 1] = { k = k, blk = blk, at = at, u = u } end
                    at = at + u
                end
                if k and by_key[k] then any = true end
            end
            if pack(blk) then block_units[blk] = math.max(block_units[blk], at) end
        end
        if any or not packed then
            rows[#rows + 1] = { keys = keys, has_binds = any, gap_after = row.gap_after and not packed }
        end
    end
    local key_slot = {}
    for _, r in ipairs(rows) do for _, s in ipairs(r.keys) do key_slot[s.k] = s end end

    -- Modifier letters in front of each bind take only what that bind needs:
    -- "C " = 2 characters, "CAW " = 4. A 1u key is sized for the common 2.
    local BASE_BW = 2
    local function bind_bw(b) return math.max(1, #mods_of(b.combo)) + 1 end

    local size = settings.display.text.size
    local cw0, lh0 = metrics.cw, metrics.lh
    local cw, lh = cw0, lh0
    local longest = 6
    for _, t in ipairs(labels) do longest = math.max(longest, #t) end
    local auto_w = (tonumber(settings.key_width) or 0) <= 0
    local w = auto_w and math.min(20, longest) or tonumber(settings.key_width)

    local function unit_px() return (BASE_BW + w) * cw + 2 * KEY_PAD_X + GAP end
    local function key_px(s) return s.u * unit_px() - GAP end
    -- Characters across key k, and how many are left for bind b's label.
    local function label_chars(k, b)
        local s = key_slot[k]
        local chars = math.floor((key_px(s) - 2 * KEY_PAD_X) / cw + 0.01)
        return math.max(4, chars - bind_bw(b))
    end
    local function key_lines(k)
        local n = 1
        for _, b in ipairs(by_key[k]) do n = n + #bp.wrap(b.text, label_chars(k, b)) end
        return n
    end
    -- Each row is as tall as its busiest key; rows without binds stay slim.
    local function row_height(r)
        local n = 1
        for _, s in ipairs(r.keys) do
            if by_key[s.k] then n = math.max(n, key_lines(s.k)) end
        end
        return n * lh + 2 * KEY_PAD_Y + (n > 1 and KEY_PAD_Y or 0)
    end
    local function block_gap() return unit_px() * 0.3 end
    local function board_size()
        local width = -block_gap()
        for _, blk in ipairs(blocks) do
            if block_units[blk] > 0 then width = width + block_units[blk] * unit_px() + block_gap() end
        end
        local height = 6
        for _, r in ipairs(rows) do height = height + row_height(r) + GAP + (r.gap_after and 6 or 0) end
        return width, height
    end

    -- Would any word be split across lines? Words longer than LONG_WORD (e.g.
    -- "game_forceambientlight") may break, so one oddity doesn't widen every key.
    local LONG_WORD = 11
    local function splits_words()
        for k, list in pairs(by_key) do
            if key_slot[k] then
                for _, b in ipairs(list) do
                    local chars = label_chars(k, b)
                    for word in b.text:gmatch('%S+') do
                        if #word > chars and #word <= LONG_WORD then return true end
                    end
                end
            end
        end
        return false
    end

    -- Sizing. Words are never split: labels are at least as wide as the
    -- narrowest width at which every word fits on a line. Then:
    --  1. Largest text size, then widest labels, that fit //bh fit (65% x 45%).
    --  2. Otherwise the largest that fits the screen's width (height ignored).
    --  3. Otherwise the smallest text size at that narrowest width.
    local sw, sh = screen_size()
    local fit_w = (tonumber(settings.fit_width) or 0) / 100
    local fit_h = (tonumber(settings.fit_height) or 0) / 100
    local function set_size(s) cw, lh = cw0 * s / size, lh0 * s / size; draw_size = s < size and s or nil end
    local min_w = w
    if auto_w then
        for lw = 4, 20 do
            w = lw
            if not splits_words() then break end
        end
        min_w = w
    end
    local function search(avail_w, avail_h)
        local top = auto_w and math.max(min_w, math.min(20, longest)) or w
        for s = size, 6, -1 do
            set_size(s)
            for lw = top, min_w, -1 do
                w = lw
                local bwid, bhgt = board_size()
                if bwid <= avail_w and (not avail_h or bhgt <= avail_h) then return true end
            end
        end
        return false
    end
    if fit_w > 0 then
        local found = search(math.min(sw * fit_w, sw - ox - 12), fit_h > 0 and sh * fit_h or nil)
            or search(sw - ox - 12, nil)
        if not found then
            set_size(math.min(size, 6))
            w = min_w
        end
    end
    state.too_wide = (board_size()) > sw - ox - 12

    local unit = unit_px()
    local cap_h = lh + 2 * KEY_PAD_Y

    -- The binds on key k (below its name), wrapped to the key's own width.
    local function key_body(k)
        local lit = false
        local out = {}
        for _, b in ipairs(by_key[k]) do
            local dim = layer ~= '' and b.combo ~= layer
            if layer ~= '' and b.combo == layer then lit = true end
            local c = dim and COLORS.dim or COLORS[b.cat] or COLORS.command
            local bwk = bind_bw(b)
            for i, line in ipairs(bp.wrap(b.text, label_chars(k, b))) do
                local lead = i == 1 and badge(b.combo, bwk, dim) or (' '):rep(bwk)
                out[#out + 1] = lead .. color(line, c)
            end
        end
        return table.concat(out, '\n'), lit
    end

    -- Block x offsets and board size.
    local x_of, x = {}, ox
    for _, blk in ipairs(blocks) do
        x_of[blk] = x
        if block_units[blk] > 0 then x = x + block_units[blk] * unit + block_gap() end
    end
    local total_w, total_h = board_size()

    -- Board background (solid, so the game doesn't show through), then keys.
    rect(ox - 6, oy - 4, total_w + 12, total_h + 8, { 12, 14, 18 }, 245)
    local y = oy
    for _, r in ipairs(rows) do
        local row_h = row_height(r)
        for _, s in ipairs(r.keys) do
            local k = s.k
            local kx = x_of[s.blk] + s.at * unit
            local width = key_px(s)
            local is_mod = k:sub(1, 1) == '@'
            local name = is_mod and (MOD_NAMES[k:sub(2)] or k:sub(2)) or cap_label(k)
            if is_mod then
                local m = k:sub(2)
                local on = state.combo ~= '' and state.combo:find(m, 1, true) ~= nil
                rect(kx, y, width, row_h, on and { 50, 120, 60 } or { 26, 29, 35 }, 255)
                label(kx + KEY_PAD_X, y + KEY_PAD_Y, color(name, on and COLORS.active or COLORS.cap_dim), on)
            elseif by_key[k] then
                -- Bound key: dark body, a strip with the key's name in bold,
                -- then its binds below the strip.
                local body, lit = key_body(k)
                rect(kx, y, width, row_h, lit and { 30, 70, 40 } or { 36, 41, 52 }, 255)
                rect(kx, y, width, cap_h, lit and { 50, 120, 65 } or { 58, 68, 88 }, 255)
                label(kx + KEY_PAD_X, y + KEY_PAD_Y, color(name, COLORS.key_name), true)
                label(kx + KEY_PAD_X, y + cap_h + KEY_PAD_Y, body)
            else
                rect(kx, y, width, row_h, { 24, 27, 32 }, 255)
                label(kx + KEY_PAD_X, y + KEY_PAD_Y, color(name, COLORS.cap_dim))
            end
        end
        y = y + row_h + GAP + (r.gap_after and 6 or 0)
    end
end

-------------------------------------------------------------------------------
-- Cheat sheet view: grouped by kind, alphabetical, with the keys to press.
-------------------------------------------------------------------------------
local GROUPS = {
    { 'spell', 'SPELLS' }, { 'ability', 'JOB ABILITIES' }, { 'auto', 'AUTO' }, { 'command', 'COMMANDS' },
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

    -- Split groups into balanced columns (groups are never split).
    local total = 0
    for _, e in ipairs(entries) do total = total + #e + 1 end
    local cw, lh = metrics.cw, metrics.lh
    local col_gap = cw * 3

    local function layout(ncol)
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
        local widths, max_lines, total_w = {}, 0, -col_gap
        for i, c in ipairs(cols) do
            local wmax = 0
            for _, l in ipairs(c) do wmax = math.max(wmax, l.len) end
            widths[i] = wmax * cw
            max_lines = math.max(max_lines, #c)
            total_w = total_w + widths[i] + col_gap
        end
        return cols, widths, max_lines, total_w
    end

    -- Up to 3 columns, fewer if that is too wide for this screen.
    local avail = screen_size() - ox - 12
    local ncol = math.max(1, math.min(3, math.ceil(total / 14)))
    local cols, widths, max_lines, total_w = layout(ncol)
    while ncol > 1 and total_w > avail do
        ncol = ncol - 1
        cols, widths, max_lines, total_w = layout(ncol)
    end
    state.too_wide = total_w > avail

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
    -- Title bar opacity. Set on the text object directly so the saved title-bar
    -- settings keep their full values.
    local t = settings.display
    windower.text.set_bg_color(box._name, math.floor((t.bg.alpha or 200) * opacity() + 0.5), t.bg.red, t.bg.green, t.bg.blue)
    windower.text.set_color(box._name, math.floor((t.text.alpha or 255) * opacity() + 0.5), t.text.red, t.text.green, t.text.blue)

    -- Keep the title bar on screen (e.g. after switching to a smaller resolution).
    local sw, sh = screen_size()
    local bx, by = box:pos()
    local cx = math.max(0, math.min(bx, sw - 120))
    local cy = math.max(0, math.min(by, sh - 60))
    if cx ~= bx or cy ~= by then
        box:pos(cx, cy)
        bx, by = cx, cy
    end

    -- The board sits just under the title bar.
    local _, bh = box:extents()
    if not bh or bh <= 0 then
        bh = 2 * metrics.lh + 2 * (settings.display.padding or 4)
        measured = false
    end
    local ox, oy = bx + 6, by + bh + 8

    begin_frame()
    draw_size = settings.display.text.size
    if view == 'cheatsheet' then draw_cheatsheet(ox, oy) else draw_keyboard(ox, oy) end
    end_frame()

    -- Say once (in the console) if even the narrowest layout doesn't fit.
    if not state.too_wide then state.warned_wide = false end
    if state.too_wide and measured and not state.warned_wide then
        state.warned_wide = true
        msg('The overlay is wider than your screen. Try //bh size with a smaller number, //bh keywidth 6, or move it left.')
    end

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
local DIK_TAB, DIK_ESC = 0x0F, 0x01

-- Forget every held modifier. Used when the game loses focus: Windows then
-- swallows the key releases, so without this Alt looks stuck after Alt+Tab.
local function clear_mods()
    if next(held_dik) == nil and state.combo == '' then return end
    held_dik = {}
    state.combo = ''
    state.peek_ready = false
    peek_token = peek_token + 1
    render()
end

windower.register_event('keyboard', function(dik, pressed)
    -- Alt+Tab / Alt+Esc switch away from the game: the Alt release will never
    -- arrive, so drop the modifiers now.
    if pressed and (dik == DIK_TAB or dik == DIK_ESC) and (held_dik[0x38] or held_dik[0xB8]) then
        clear_mods()
        return
    end
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

-- Backup for other ways of leaving the game (Win key, clicking another window):
-- if this Windower build can report window focus, clear held modifiers when the
-- game loses it. Checked a few times a second, not every frame.
if type(windower.has_focus) == 'function' then
    local last_check = 0
    windower.register_event('prerender', function()
        local now = os.clock()
        if now - last_check < 0.25 then return end
        last_check = now
        if next(held_dik) ~= nil and not windower.has_focus() then clear_mods() end
    end)
end

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
    '//bh fit <w%> [h%]|off   largest share of the screen the keyboard may use (default 65 45)',
    '//bh targets on|off       show or hide targeting binds (/ta, /target)',
    '//bh layout packed|full   only keys with binds (default), or the full keyboard',
    '//bh opacity <1-100>      how solid the overlay is (100 = fully solid)',
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
    elseif cmd == 'fit' and (arg == 'off' or tonumber(args[1])) then
        if arg == 'off' then
            settings.fit_width = 0
            msg('Fit off: //bh size and //bh keywidth set the size.')
        else
            local clamp = function(v) return math.max(20, math.min(100, math.floor(v))) end
            settings.fit_width = clamp(tonumber(args[1]))
            if tonumber(args[2]) then settings.fit_height = clamp(tonumber(args[2])) end
            msg(('Keyboard fits within %d%% of the screen width and %d%% of its height.'):format(settings.fit_width, settings.fit_height))
        end
    elseif cmd == 'opacity' and tonumber(args[1]) then
        settings.opacity = math.max(1, math.min(100, math.floor(tonumber(args[1]) + 0.5)))
        msg('Opacity: ' .. settings.opacity .. '%')
    elseif cmd == 'opacity' then
        msg('Opacity is ' .. (tonumber(settings.opacity) or 50) .. '%. Set it with //bh opacity <1-100>.')
        return
    elseif cmd == 'layout' then
        if arg == 'packed' or arg == 'full' then settings.layout = arg
        else settings.layout = settings.layout == 'full' and 'packed' or 'full' end
        msg(settings.layout == 'full' and 'Layout: full keyboard, every key in its real position.'
            or 'Layout: packed, only keys with binds, in keyboard order.')
    elseif cmd == 'targets' then
        if arg == 'on' then settings.show_targets = true
        elseif arg == 'off' then settings.show_targets = false
        else settings.show_targets = not settings.show_targets end
        msg(settings.show_targets and 'Showing targeting binds (/ta, /target).' or 'Hiding targeting binds (/ta, /target).')
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
