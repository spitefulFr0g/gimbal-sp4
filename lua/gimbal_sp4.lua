-- Manual tablet mode for Surface Pro 4. The Omarchy shell, keyboard daemon,
-- and later lock view consume only the runtime mode word; hardware detection
-- can be added here without changing those readers.
local M = {}
local runtime = (os.getenv("XDG_RUNTIME_DIR") or "/tmp")
local home = assert(os.getenv("HOME"), "HOME is required")
local mode_path = runtime .. "/gimbal-sp4-mode"
local keyboard_path = runtime .. "/gimbal-sp4-osk"
local autoshow_path = runtime .. "/gimbal-sp4-autoshow"
local saved_path = home .. "/.config/omarchy/gimbal-sp4-mode"
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

-- Called by the bar, the CLI helper, and tests. Persist only explicit choices.
function M.set(mode)
    assert(mode == "tablet" or mode == "laptop", "mode must be tablet or laptop")
    M.tablet = mode == "tablet"
    write_word(saved_path, mode)
    write_word(mode_path, mode)
    refresh_focus()
    return mode
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

-- The stock Omarchy configuration on this machine uses follow_mouse=1.
-- Capture the configured value before changing it so laptop mode restores it.
local option = hl.get_option and hl.get_option("input:follow_mouse")
previous_follow_mouse = (type(option) == "number" and option) or 1
hl.bind("SUPER + B", function()
    hl.dispatch(hl.dsp.exec_cmd(
        "omarchy-shell shell call io.github.spitfulfr0g.gimbal-sp4 toggle ''"))
end, { description = "Toggle the Surface on-screen keyboard" })

hl.timer(refresh_focus, { timeout = 250, type = "repeat" })
return M
