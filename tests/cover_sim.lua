-- Offline test of the Type Cover logic in lua/gimbal_sp4.lua.
--
-- Loads the module with a stubbed `hl`, a fake clock, a fake
-- /proc/bus/input/devices and a fake fold helper word, drives its 500 ms
-- timer, and checks the published mode and cover state.
--
-- Usage: lua tests/cover_sim.lua   (from the repository root, or any path)
local script_dir = (arg and arg[0] or ""):match("^(.*)/[^/]*$") or "."
local module_path = script_dir .. "/../lua/gimbal_sp4.lua"

local real_open, real_time, real_getenv = io.open, os.time, os.getenv
local pipe = assert(io.popen("mktemp -d"))
local dir = assert(pipe:read("*l"))
pipe:close()
assert(os.execute("mkdir -p '" .. dir .. "/rt' '" .. dir .. "/home/.config/omarchy'"))

local clock = 1000
local devices = "attached" -- "attached", "detached" or "unreadable"
local fold = nil           -- nil: no helper file; otherwise its contents
local helper = true        -- whether the helper's unit file is installed
local timers = {}
local failures, checks = 0, 0

local function file(body)
    return {
        read = function(_, n)
            if type(n) == "number" then return body:sub(1, n) end
            return body
        end,
        close = function() end,
    }
end

local function load_module()
    timers = {}
    _G.hl = {
        config = function() end,
        get_option = function() return 1 end,
        bind = function() end,
        dispatch = function() end,
        dsp = { exec_cmd = function() end },
        timer = function(f, o) timers[#timers + 1] = { f = f, t = o.timeout } end,
    }
    os.getenv = function(k)
        return ({ XDG_RUNTIME_DIR = dir .. "/rt", HOME = dir .. "/home" })[k]
    end
    os.time = function() return math.floor(clock) end
    io.open = function(p, m)
        if p == "/proc/bus/input/devices" then
            if devices == "unreadable" then return nil end
            return file(devices == "attached"
                and 'N: Name="Microsoft Surface Type Cover Keyboard"\n'
                or 'N: Name="Lid Switch"\n')
        end
        if p == "/run/gimbal-sp4-cover/fold" then
            if fold == nil then return nil end
            return file(fold .. "\n")
        end
        if p == "/etc/systemd/system/gimbal-sp4-coverd@.service" then
            return helper and file("") or nil
        end
        return real_open(p, m)
    end
    return dofile(module_path)
end

local function rd(p)
    local f = real_open(dir .. p)
    if not f then return nil end
    local w = f:read("*l")
    f:close()
    return w
end

local function wr(p, w)
    local f = assert(real_open(dir .. p, "w"))
    f:write(w, "\n")
    f:close()
end

local function run(seconds)
    for _ = 1, math.floor(seconds * 2 + 0.5) do
        clock = clock + 0.5
        for _, t in ipairs(timers) do
            if t.t == 500 then t.f() end
        end
    end
end

local function suspend(seconds) clock = clock + seconds end

local function expect(label, mode, cover)
    checks = checks + 1
    local got_mode, got_cover = rd("/rt/gimbal-sp4-mode"), rd("/rt/gimbal-sp4-cover")
    if got_mode ~= mode or got_cover ~= cover then
        failures = failures + 1
        print(string.format("FAIL %-52s want %s/%s, have %s/%s",
            label, mode, cover, tostring(got_mode), tostring(got_cover)))
    end
end

local function fresh(installed)
    assert(os.execute("rm -f '" .. dir .. "'/rt/* '" .. dir .. "'/home/.config/omarchy/*"))
    clock, devices, fold = 1000, "attached", nil
    helper = installed ~= false
    wr("/home/.config/omarchy/gimbal-sp4-mode", "laptop")
    local M = load_module()
    wr("/rt/gimbal-sp4-autocover", "on")
    run(6)
    return M
end

-- 1. Without the helper, behaviour is exactly detach-only detection.
local M = fresh(false)
expect("no helper: attached", "laptop", "attached")
devices = "detached"; run(1.5)
expect("no helper: detach -> tablet", "tablet", "detached")
devices = "attached"; run(1.5)
expect("no helper: reattach -> laptop", "laptop", "attached")
M.set("tablet"); run(3)
expect("no helper: manual tablet holds", "tablet", "attached")
load_module(); run(6)
expect("no helper: manual choice survives reload", "tablet", "attached")
devices = "detached"; run(6); devices = "attached"; run(1.5)
expect("no helper: detach+reattach follows cover again", "laptop", "attached")
suspend(60); devices = "detached"; run(2.5); devices = "attached"; run(2)
expect("no helper: resume with 2.5 s dropout, no flip", "laptop", "attached")
devices = "unreadable"; run(10)
expect("no helper: unreadable list changes nothing", "laptop", "attached")
devices = "attached"
fold = "folded"; run(3)
expect("helper not installed: a fold file is ignored", "laptop", "attached")
fold = nil

-- 1a. The helper installed after the module loaded, as install.sh does (it
-- reloads Hyprland before installing the helper): its word is still read.
M = fresh(false)
helper = true; fold = "typing"; run(1)
expect("helper installed after load: typing", "laptop", "attached")
fold = "folded"; run(1)
expect("helper installed after load: folded -> tablet", "tablet", "folded")
fold = "typing"; run(1)
expect("helper installed after load: unfold -> laptop", "laptop", "attached")
helper, fold = false, nil; run(1)
expect("helper removed after load: detach-only again", "laptop", "attached")

-- 1b. Helper installed but not running: attached once the grace has passed.
M = fresh()
expect("helper installed, no word: attached after grace", "laptop", "attached")
fold = "unknown"; run(3)
expect("helper says unknown: stays attached", "laptop", "attached")

-- 2. Fold back and unfold.
M = fresh()
fold = "typing"; run(1)
expect("typing: laptop", "laptop", "attached")
fold = "between"; run(5)
expect("between from typing never flips", "laptop", "attached")
fold = "folded"; run(0.5)
expect("folded, one read: not yet", "laptop", "attached")
run(0.5)
expect("folded, settled -> tablet", "tablet", "folded")
fold = "between"; run(5)
expect("between from folded never flips", "tablet", "folded")
fold = "unknown"; run(3)
expect("unknown keeps folded", "tablet", "folded")
fold = nil; run(3)
expect("helper gone (restart) keeps folded", "tablet", "folded")
fold = "folded"; run(1)
fold = "typing"; run(1)
expect("unfold -> laptop", "laptop", "attached")

-- 3. A fold change is a cover change: it re-applies the cover's mode.
M = fresh(); fold = "typing"; run(1)
M.set("tablet"); run(3)
expect("manual tablet while typing holds", "tablet", "attached")
fold = "between"; run(3)
expect("... and holds through between", "tablet", "attached")
fold = "folded"; run(1)
expect("fold -> tablet", "tablet", "folded")
M.set("laptop"); run(3)
expect("manual laptop while folded holds", "laptop", "folded")
fold = "between"; run(3)
expect("... and holds through between", "laptop", "folded")
fold = "typing"; run(1)
expect("unfold after manual laptop -> laptop", "laptop", "attached")
fold = "folded"; run(1)
M.set("laptop"); run(1)
fold = nil; devices = "detached"; run(1.5)
expect("detach while folded after manual laptop -> tablet", "tablet", "detached")

-- 4. Detach while folded, then reattach.
M = fresh(); fold = "folded"; run(1)
expect("folded", "tablet", "folded")
fold = nil; devices = "detached"; run(1.5)
expect("detach while folded -> detached, still tablet", "tablet", "detached")
devices = "attached"; run(1.5)
expect("reattach, helper not yet published: waits", "tablet", "detached")
fold = "unknown"; run(1)
expect("helper starts, unknown: still waits", "tablet", "detached")
fold = "typing"; run(1)
expect("helper says typing -> laptop", "laptop", "attached")
fold = nil; devices = "detached"; run(6)
devices = "attached"; run(6)
expect("reattach, helper never publishes: attached after grace", "laptop", "attached")

-- 5. Reload and resume while folded.
M = fresh(); fold = "folded"; run(1)
load_module()
expect("reload while folded: cover unknown at first", "tablet", "unknown")
run(1)
expect("reload while folded: stays tablet", "tablet", "folded")
M = load_module(); run(1); M.set("laptop"); run(1)
load_module(); run(6)
expect("reload keeps a manual laptop made while folded", "laptop", "folded")
fold = "typing"; run(1); fold = "folded"; run(1)
expect("fold again -> tablet", "tablet", "folded")
suspend(60); run(3)
expect("resume while folded, no dropout", "tablet", "folded")
suspend(60); fold = nil; devices = "detached"; run(2.5)
devices = "attached"; run(1)
fold = "folded"; run(2)
expect("resume while folded with re-enumeration", "tablet", "folded")
suspend(60); fold = "typing"; run(1)
expect("unfolded during suspend, helper re-queried -> laptop", "laptop", "attached")

-- 6. Automatic mode off: folding changes nothing.
M = fresh(); wr("/rt/gimbal-sp4-autocover", "off"); fold = "typing"; run(1)
fold = "folded"; run(2)
expect("auto off: fold publishes state only", "laptop", "folded")
wr("/rt/gimbal-sp4-autocover", "on"); run(1)
expect("auto switched on while folded -> tablet", "tablet", "folded")

-- 7. Flapping between typing and folded every read never settles.
M = fresh(); fold = "typing"; run(1)
for i = 1, 10 do
    fold = (i % 2 == 0) and "typing" or "folded"; run(0.5)
    expect("flapping every read -> no flip (read " .. i .. ")", "laptop", "attached")
end

-- 8. Reviewer's reproductions.
-- R1: reattached already folded; the helper publishes 1 s after enumeration.
M = fresh(); fold = "folded"; run(1)
fold = nil; devices = "detached"; run(6)
expect("R1 detached", "tablet", "detached")
devices = "attached"; run(1.0)
expect("R1 reattached folded, before helper: stays tablet", "tablet", "detached")
fold = "unknown"; run(0.5); fold = "folded"; run(1)
expect("R1 after helper", "tablet", "folded")
-- R2: manual laptop while folded, reload while the helper restarts.
M = fresh(); fold = "folded"; run(1); M.set("laptop"); run(1)
fold = nil; load_module(); run(2)
fold = "folded"; run(2)
expect("R2 manual laptop survives reload during helper restart", "laptop", "folded")

-- 9. Only the four words are accepted, from at most 16 bytes.
M = fresh(); fold = "typing"; run(1)
fold = "folded" .. string.rep(" ", 20); run(3)
expect("padded word is ignored", "laptop", "attached")
fold = "FOLDED"; run(3)
expect("unknown spelling is ignored", "laptop", "attached")
fold = "folded\nfolded"; run(3)
expect("two lines are ignored", "laptop", "attached")
fold = "folded"; run(1)
expect("then a real fold still works", "tablet", "folded")

io.open, os.time, os.getenv = real_open, real_time, real_getenv
os.execute("rm -rf '" .. dir .. "'")
if failures > 0 then
    print(string.format("%d of %d checks failed", failures, checks))
    os.exit(1)
end
print(string.format("cover_sim: %d checks passed", checks))
