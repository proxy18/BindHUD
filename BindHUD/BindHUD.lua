--[[
    BindHUD - on-screen overlay of your keyboard binds.

    Reads the binds from:
      * Windower scripts/init.txt (and any scripts it `exec`s)
      * the GearSwap file GearSwap loads for your current job, plus
        everything it include()s and any `_Gear` sidecar file
    and draws a key x modifier grid. Hold Ctrl/Alt/Shift/Win to highlight
    that layer (or, in "hold" mode, to show only that layer).
]]

_addon.name = 'BindHUD'
_addon.author = 'ffxiHotbar'
_addon.version = '0.1.0'
_addon.commands = { 'bindhud', 'bh' }

local config = require('config')
local texts = require('texts')
local bp = require('bindparse')

local defaults = {
    visible = true,
    display_mode = 'always',   -- 'always' | 'hold'
    max_label = 14,            -- longest label text before truncating
    hold_idle = 'plain',       -- hold mode, nothing held: 'plain' (no-modifier keys) | 'hide'
    show_next = true,          -- hold mode: also list binds that need one more modifier (dimmed)
    include_init = true,       -- read scripts/init.txt
    follow_includes = true,    -- follow include() in GearSwap files
    extra_files = '',          -- comma separated, {name} and {job} are substituted
    display = {
        pos = { x = 100, y = 300 },
        bg = { alpha = 170, red = 0, green = 0, blue = 0, visible = true },
        flags = { draggable = true, bold = false },
        padding = 6,
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
    title  = { 255, 215, 120 },
    header = { 255, 215, 120 },
    key    = { 150, 200, 255 },
    action = { 235, 235, 235 },
    gs     = { 255, 180, 110 },
    other  = { 190, 190, 255 },
    empty  = { 90, 90, 90 },
    dim    = { 110, 110, 110 },
    active = { 120, 255, 120 },
}

local state = {
    binds = {},       -- "combo|key" -> bind
    files = {},       -- { path, short, count }
    logged_in = false,
    combo = '',       -- modifier combo currently held
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
-- Rendering
-------------------------------------------------------------------------------
local function color(s, c)
    return ('\\cs(%d,%d,%d)'):format(c[1], c[2], c[3]) .. s .. '\\cr'
end

local function pad(s, w)
    if #s >= w then return s end
    return s .. string.rep(' ', w - #s)
end

local function fit(s, w)
    if #s > w then return s:sub(1, w - 1) .. '.' end
    return s
end

-- "hold" mode: one layer as a short list.
--   Nothing held  -> the plain (no modifier) keys, or hidden if hold_idle = 'hide'.
--   Modifier held -> that layer, then (dimmed) binds that need one more modifier.
local function render_layer()
    local layer = state.combo
    if not settings.visible or not state.logged_in or (layer == '' and settings.hold_idle == 'hide') then
        box:hide()
        return
    end

    local direct, nxt = {}, {}
    local layer_mods = {}
    for m in layer:gmatch('[^+]+') do layer_mods[m] = true end

    for _, b in pairs(state.binds) do
        if b.combo == layer then
            direct[#direct + 1] = { key = b.key, b = b, prefix = '' }
        elseif layer ~= '' and settings.show_next then
            local superset = true
            for m in pairs(layer_mods) do if not b.mods[m] then superset = false end end
            if superset then
                local extra = {}
                for m in pairs(b.mods) do if not layer_mods[m] then extra[m] = true end end
                local eid = bp.combo_id(extra)
                nxt[#nxt + 1] = { key = b.key, b = b, extra = eid, prefix = '+' .. bp.combo_label(eid) .. ' ' }
            end
        end
    end
    if #direct + #nxt == 0 then
        box:hide()
        return
    end

    table.sort(direct, function(x, y) return bp.key_less(x.key, y.key) end)
    table.sort(nxt, function(x, y)
        if x.extra ~= y.extra then return bp.combo_less(x.extra, y.extra) end
        return bp.key_less(x.key, y.key)
    end)

    -- Each section gets its own key-column width so the long "+Alt+Win" prefixes
    -- don't push the main list wider.
    local kw, nkw = 3, 3
    for _, r in ipairs(direct) do kw = math.max(kw, #bp.key_label(r.key)) end
    for _, r in ipairs(nxt) do nkw = math.max(nkw, #(r.prefix .. bp.key_label(r.key))) end

    local lines = {
        color('BindHUD  ' .. state.job, COLORS.title) .. color('  [' .. bp.combo_label(layer) .. ']', COLORS.active),
    }
    for _, r in ipairs(direct) do
        local label, kind = bp.label(r.b.command)
        lines[#lines + 1] = color(pad(bp.key_label(r.key), kw), COLORS.key) .. '  '
            .. color(fit(label, settings.max_label), COLORS[kind] or COLORS.other)
    end
    for _, r in ipairs(nxt) do
        local label = bp.label(r.b.command)
        lines[#lines + 1] = color(pad(r.prefix .. bp.key_label(r.key), nkw) .. '  ' .. fit(label, settings.max_label), COLORS.dim)
    end

    box:text(table.concat(lines, '\n'))
    box:show()
end

local function render()
    if settings.display_mode == 'hold' then return render_layer() end
    local hold = false
    local held = state.combo

    -- Build grid[key][combo] = bind
    local grid, rows, cols, rowset, colset = {}, {}, {}, {}, {}
    for _, b in pairs(state.binds) do
        if not hold or b.combo == held then
            if not rowset[b.key] then rowset[b.key] = true; rows[#rows + 1] = b.key end
            if not colset[b.combo] then colset[b.combo] = true; cols[#cols + 1] = b.combo end
            grid[b.key] = grid[b.key] or {}
            grid[b.key][b.combo] = b
        end
    end
    table.sort(rows, bp.key_less)
    table.sort(cols, bp.combo_less)

    local show = settings.visible and state.logged_in and #rows > 0 and (not hold or held ~= '')
    if not show then
        box:hide()
        return
    end

    -- Column widths
    local kw = 3
    for _, k in ipairs(rows) do kw = math.max(kw, #bp.key_label(k)) end
    local widths = {}
    for _, c in ipairs(cols) do
        local w = #bp.combo_label(c)
        for _, k in ipairs(rows) do
            local b = grid[k][c]
            if b then w = math.max(w, #fit(bp.label(b.command), settings.max_label)) end
        end
        widths[c] = w
    end

    local lines = {}
    lines[1] = color(('BindHUD  %s'):format(state.job), COLORS.title)
        .. (hold and color('  [' .. bp.combo_label(held) .. ']', COLORS.active) or '')

    local function col_color(c, base)
        if held == '' or hold then return base end
        return c == held and COLORS.active or COLORS.dim
    end

    local header = { pad('Key', kw) }
    for _, c in ipairs(cols) do
        header[#header + 1] = color(pad(bp.combo_label(c), widths[c]), col_color(c, COLORS.header))
    end
    lines[2] = color(header[1], COLORS.header) .. '  ' .. table.concat(header, '  ', 2)

    for _, k in ipairs(rows) do
        local cells = {}
        for _, c in ipairs(cols) do
            local b = grid[k][c]
            if b then
                local label, kind = bp.label(b.command)
                local text = fit(label, settings.max_label)
                if c ~= cols[#cols] then text = pad(text, widths[c]) end
                cells[#cells + 1] = color(text, col_color(c, COLORS[kind] or COLORS.other))
            else
                cells[#cells + 1] = color(c ~= cols[#cols] and pad('-', widths[c]) or '-', COLORS.empty)
            end
        end
        lines[#lines + 1] = color(pad(bp.key_label(k), kw), COLORS.key) .. '  ' .. table.concat(cells, '  ')
    end

    box:text(table.concat(lines, '\n'))
    box:show()
end

-------------------------------------------------------------------------------
-- Held-modifier tracking
-------------------------------------------------------------------------------
local MOD_DIK = {
    [0x1D] = 'ctrl', [0x9D] = 'ctrl', [0x38] = 'alt', [0xB8] = 'alt',
    [0x2A] = 'shift', [0x36] = 'shift', [0xDB] = 'win', [0xDC] = 'win', [0xDD] = 'apps',
}
local held_dik = {}

windower.register_event('keyboard', function(dik, pressed)
    local m = MOD_DIK[dik]
    if not m then return end
    if (held_dik[dik] == true) == (pressed == true) then return end
    held_dik[dik] = pressed and true or nil
    local mods = {}
    for d in pairs(held_dik) do mods[MOD_DIK[d]] = true end
    local combo = bp.combo_id(mods)
    if combo ~= state.combo then
        state.combo = combo
        render()
    end
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

local function save_pos()
    local bx, by = box:pos()
    settings.display.pos.x, settings.display.pos.y = bx, by
    config.save(settings)
end

windower.register_event('unload', function()
    config.save(settings)
end)

-------------------------------------------------------------------------------
-- Commands
-------------------------------------------------------------------------------
local HELP = {
    '//bh                  toggle the overlay',
    '//bh show | hide',
    '//bh rescan           re-read your files (after editing binds)',
    '//bh mode always|hold always show, or only while holding a modifier',
    '//bh width <n>        max label length (now ' .. settings.max_label .. ')',
    '//bh size <n>         font size',
    '//bh files            list the files that were read',
    '//bh pos <x> <y>      move the box to a screen position, e.g. //bh pos 50 400',
}

windower.register_event('addon command', function(cmd, ...)
    cmd = (cmd or 'toggle'):lower()
    local args = { ... }

    if cmd == 'toggle' then
        settings.visible = not settings.visible
    elseif cmd == 'show' then
        settings.visible = true
    elseif cmd == 'hide' then
        settings.visible = false
    elseif cmd == 'rescan' or cmd == 'reload' or cmd == 'refresh' then
        rescan(true)
    elseif cmd == 'mode' then
        local m = (args[1] or ''):lower()
        if m ~= 'always' and m ~= 'hold' then
            m = settings.display_mode == 'always' and 'hold' or 'always'
        end
        settings.display_mode = m
        msg('Mode: ' .. m)
    elseif cmd == 'width' and tonumber(args[1]) then
        settings.max_label = math.max(4, math.floor(tonumber(args[1])))
    elseif cmd == 'size' and tonumber(args[1]) then
        settings.display.text.size = tonumber(args[1])
        box:size(settings.display.text.size)
    elseif cmd == 'pos' and tonumber(args[1]) and tonumber(args[2]) then
        box:pos(tonumber(args[1]), tonumber(args[2]))
        save_pos()
        return
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
