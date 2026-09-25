-- Tablet mode for Surface Pro 4. The Omarchy shell, keyboard daemon, and lock
-- view consume only the runtime mode word; the Type Cover adapter below is
-- the one place that knows what Surface hardware looks like.
local M = {}
local runtime = (os.getenv("XDG_RUNTIME_DIR") or "/tmp")
local home = assert(os.getenv("HOME"), "HOME is required")
local mode_path = runtime .. "/gimbal-sp4-mode"
local keyboard_path = runtime .. "/gimbal-sp4-osk"
local autoshow_path = runtime .. "/gimbal-sp4-autoshow"
local cover_path = runtime .. "/gimbal-sp4-cover"
local autocover_path = runtime .. "/gimbal-sp4-autocover"
local saved_path = home .. "/.config/omarchy/gimbal-sp4-mode"
local saved_cover_path = home .. "/.config/omarchy/gimbal-sp4-cover"
local previous_follow_mouse = nil
local applied_follow_mouse = nil

local function read_word(path)
    local file = io.open(path, "r")
    if not file then return nil end
    local word = file:read("*l")
    file:close()
    return word
end

local function write_word(path, word)
    local file, err = io.open(path, "w")
    if not file then error("cannot write " .. path .. ": " .. tostring(err)) end
    file:write(word, "\n")
    file:close()
end

local function refresh_focus()
    local want = read_word(keyboard_path) == "visible" and 2 or previous_follow_mouse
    if want == applied_follow_mouse then return end
    hl.config({ input = { follow_mouse = want } })
    applied_follow_mouse = want
end

-- Every mode change goes through here. The cover state it was made under is
-- saved with it, so automatic mode can tell a cover change it has not acted
-- on from one it has, across reloads and restarts.
local function apply(mode)
    M.tablet = mode == "tablet"
    write_word(saved_path, mode)
    write_word(mode_path, mode)
    if M.cover then write_word(saved_cover_path, M.cover) end
    refresh_focus()
    return mode
end

-- Called by the bar, the CLI helper, and tests. With automatic mode on, a
-- choice made here holds until the Type Cover next changes state: detached,
-- reattached, folded back or unfolded.
function M.set(mode)
    assert(mode == "tablet" or mode == "laptop", "mode must be tablet or laptop")
    return apply(mode)
end

function M.toggle()
    return M.set(M.tablet and "laptop" or "tablet")
end

function M.status()
    return M.tablet and "tablet" or "laptop"
end

-- The first install defaults to tablet mode so an SP4 without its Type Cover
-- immediately has touch access. Later reloads use the user's saved choice.
M.tablet = read_word(saved_path) ~= "laptop"
write_word(mode_path, M.status())
if not read_word(autoshow_path) then write_word(autoshow_path, "off") end

-- ---------------------------------------------------------------------------
-- Type Cover
--
-- The SP4 cover is a USB device that comes and goes with the magnets; there
-- is no SW_TABLET_MODE switch, and Hyprland's Lua has no device events. So
-- the input device list is read twice a second (about 0.25 ms each) and the
-- cover is present while any device is named "... Surface Type Cover
-- Keyboard". Matching the name rather than an event node or USB port keeps
-- it working across re-enumeration.
--
-- Resume can drop the cover for a few seconds while USB re-enumerates, and
-- at login it may not have enumerated yet. A detached reading therefore
-- only counts after COVER_GRACE seconds have passed since load or resume.
-- An unreadable list counts as neither, so the mode is left alone.
--
-- Folding the cover behind the screen keeps it on USB. Its fold position is
-- only visible on its root-only hidraw node, which also carries keystrokes,
-- so the optional fold helper (coverd/, a hardened system service) reads it
-- and publishes one word to FOLD_PATH: typing, between, folded or unknown.
-- While the cover is present, `folded` counts as folded and `typing` as
-- attached. Folded back, this SP4's cover reports `between` (0x33) once it
-- is still; `folded` (0x43) lasts only a few seconds. So `between` held for
-- BETWEEN_HOLD seconds also counts as folded, while a shorter one (the
-- cover on its way round) keeps the last settled reading, as do `unknown`
-- and no word. With nothing settled since load or reattach, the helper gets
-- COVER_GRACE seconds to publish before the cover counts as attached, so a
-- cover reattached folded, or a reload while the helper restarts, does not
-- pass through laptop mode. If the helper is not installed its file is not
-- read at all, and this is exactly detach-only detection.
-- ---------------------------------------------------------------------------
local COVER_POLL_MS = 500
local COVER_SETTLE = 2   -- consecutive agreeing reads
local COVER_GRACE = 5    -- seconds
local BETWEEN_HOLD = 2   -- seconds
local FOLD_PATH = "/run/gimbal-sp4-cover/fold"
local FOLD_WORDS = { typing = true, between = true, folded = true, unknown = true }
local HELPER_UNIT = "/etc/systemd/system/gimbal-sp4-coverd@.service"

-- Checked on every poll rather than once at load: install.sh reloads
-- Hyprland before it installs the helper, and the helper can be added or
-- removed at any time.
local function helper_installed()
    local unit = io.open(HELPER_UNIT, "r")
    if not unit then return false end
    unit:close()
    return true
end
local present_since = nil
local between_since = nil
local candidate, candidate_reads = nil, 0
local last_poll = os.time()
local grace_until = last_poll + COVER_GRACE
local auto_word = read_word(autocover_path)

-- One of FOLD_WORDS, or nil. Reads at most 16 bytes.
local function read_fold()
    local file = io.open(FOLD_PATH, "r")
    if not file then return nil end
    local text = file:read(16)
    file:close()
    local word = text and text:match("^(%l+)\n?$")
    return FOLD_WORDS[word] and word or nil
end

local function read_cover(now)
    local file = io.open("/proc/bus/input/devices", "r")
    if not file then return nil end
    local text = file:read("*a")
    file:close()
    if not text or text == "" then return nil end
    if not text:find('Name="[^"\n]*Surface Type Cover Keyboard"') then
        present_since = nil
        return "detached"
    end
    if not helper_installed() then return "attached" end
    present_since = present_since or now
    local fold = read_fold()
    if fold ~= "between" then
        between_since = nil
    else
        between_since = between_since or now
        if now >= between_since + BETWEEN_HOLD then return "folded" end
    end
    if fold == "folded" then return "folded" end
    if fold == "typing" then return "attached" end
    if M.cover == "folded" or M.cover == "attached" then return M.cover end
    if now < present_since + COVER_GRACE then return nil end
    return "attached"
end

local function cover_mode()
    return (M.cover == "detached" or M.cover == "folded") and "tablet" or "laptop"
end

local function poll_cover()
    local now = os.time()
    -- Timers stop while suspended, so a long gap between polls is a resume.
    if now - last_poll >= 3 then grace_until = now + COVER_GRACE end
    last_poll = now

    -- A missing word (the shell has not started yet) is not "off", so a
    -- fresh login does not look like the switch being turned on.
    local auto = read_word(autocover_path)
    local switched_on = auto == "on" and auto_word == "off"
    auto_word = auto

    local seen = read_cover(now)
    if seen ~= candidate then candidate, candidate_reads = seen, 0 end
    candidate_reads = candidate_reads + 1
    local settled = seen and candidate_reads >= COVER_SETTLE
        and (seen ~= "detached" or now >= grace_until)

    if settled and seen ~= M.cover then
        M.cover = seen
        write_word(cover_path, seen)
        if auto == "on" and seen ~= read_word(saved_cover_path) then
            apply(cover_mode())
            return
        end
    end
    if switched_on and M.cover then apply(cover_mode()) end
end

-- Until the first settled read the cover is unknown to the panel as well.
write_word(cover_path, "unknown")

-- The stock Omarchy configuration on this machine uses follow_mouse=1.
-- Capture the configured value before changing it so laptop mode restores it.
local option = hl.get_option and hl.get_option("input:follow_mouse")
previous_follow_mouse = (type(option) == "number" and option) or 1
hl.bind("SUPER + B", function()
    hl.dispatch(hl.dsp.exec_cmd(
        "omarchy-shell shell call io.github.spitfulfr0g.gimbal-sp4 toggle ''"))
end, { description = "Toggle the Surface on-screen keyboard" })

hl.timer(refresh_focus, { timeout = 250, type = "repeat" })
hl.timer(poll_cover, { timeout = COVER_POLL_MS, type = "repeat" })
return M
