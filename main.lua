--[[--
TP-1 Ring Page Turner — v4.6
Kobo Libra Colour (Kobo_monza, MTK)

═══════════════════════════════════════════════════════════════
CONFIRMED FACTS (from capture diagnostic testing)
═══════════════════════════════════════════════════════════════

Event type:  EV_ABS ABS_X (code=0x00)
             Routes through handleTouchEv(), NOT handleGenericEv()

Each button press sends MULTIPLE ABS_X events sweeping through a range.
Each value is sent THREE TIMES with its own EV_SYN — do NOT act on SYN.

  DOWN button: sweeps DOWNWARD  e.g. 3500 -> 3200 -> ... -> 200
  UP button:   sweeps UPWARD    e.g. 200  -> 500  -> ... -> 3500

Both buttons sweep the SAME full range ~200-3500.
Distinguish by DIRECTION only (first ABS_X seen vs last ABS_X seen).

═══════════════════════════════════════════════════════════════
DETECTION STRATEGY
═══════════════════════════════════════════════════════════════

Hook handleTouchEv. On each ABS_X event:
  - Record first value seen (sweep start)
  - Record last value seen (sweep end)
  - Reset 80ms settle timer

After 80ms quiet period (_classifyAndAct):
  first > last  ->  DOWN  ->  next page
  first < last  ->  UP    ->  prev page
  has ABS_MT_POSITION_X  ->  real touch, ignore

═══════════════════════════════════════════════════════════════
EXIT SAFETY
═══════════════════════════════════════════════════════════════

On MTK Kobo (Libra Colour etc.), exiting KOReader with BT active
causes a kernel panic that removes NickelMenu.

This plugin runs a full BT teardown on every exit/poweroff/reboot.
Duplicates bluetoothsafety.koplugin intentionally -- harmless if both
run, critical if bluetoothsafety is absent.

rfkill is unreliable on MTK -- teardown always runs regardless of
detected BT state.

@module koplugin.TP1PageTurner
--]]

local Device          = require("device")
local Event           = require("ui/event")
local InfoMessage     = require("ui/widget/infomessage")
local UIManager       = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger          = require("logger")
local _               = require("gettext")

local ffi = require("ffi")
local C   = ffi.C
require("ffi/posix_h")
require("ffi/linux_input_h")

-- Event constants
local EV_SYN = tonumber(C.EV_SYN)  -- 0
local EV_ABS = tonumber(C.EV_ABS)  -- 3

local ABS_X             = 0x00  -- ring sends sweep values on ABS_X (code=0)
local ABS_MT_POSITION_X = 0x35  -- present in real finger touches, not ring

-- Ring sends each ABS_X value THREE times with its own EV_SYN each time.
-- Cannot act on EV_SYN -- wait for 80ms quiet period instead.
-- Both buttons sweep full range ~200-3500; distinguish by direction only.
local SETTLE_DELAY     = 0.08   -- seconds of quiet before classifying
local DEFAULT_DEBOUNCE = 0.5    -- seconds between page turns

local MTK_MODELS = {
    Kobo_monza     = "Libra Colour",
    Kobo_condor    = "Elipsa 2E",
    Kobo_spaBW     = "Clara BW",
    Kobo_spaColour = "Clara Colour",
}

local MTK_BT_ON_CMD    = "dbus-send --system --print-reply "
    .. "--dest=com.kobo.mtk.bluedroid / "
    .. "com.kobo.bluetooth.BluedroidManager1.On 2>/dev/null"
local MTK_BT_POWER_CMD = "dbus-send --system --print-reply "
    .. "--dest=com.kobo.mtk.bluedroid /org/bluez/hci0 "
    .. "org.freedesktop.DBus.Properties.Set "
    .. "string:org.bluez.Adapter1 string:Powered variant:boolean:true 2>/dev/null"
local MTK_BT_CHECK_CMD = "dbus-send --system --print-reply "
    .. "--dest=com.kobo.mtk.bluedroid /org/bluez/hci0 "
    .. "org.freedesktop.DBus.Properties.Get "
    .. "string:org.bluez.Adapter1 string:Powered 2>/dev/null"

-- MTK BT off sequence (mirrors koreader.sh / bluetoothsafety.koplugin)
local MTK_BT_OFF_CMDS = {
    "dbus-send --system --print-reply "
        .. "--dest=com.kobo.mtk.bluedroid /org/bluez/hci0 "
        .. "org.freedesktop.DBus.Properties.Set "
        .. "string:org.bluez.Adapter1 string:Powered variant:boolean:false 2>/dev/null",
    "killall -q -TERM bluetoothd bluealsa 2>/dev/null",
    "rfkill block bluetooth 2>/dev/null",
}

local TP1PageTurner = WidgetContainer:extend{
    name        = "tp1_pageturner",
    is_doc_only = false,

    -- state
    tp1_event_path = nil,
    tp1_fd         = nil,
    last_turn_time = 0,

    -- settings
    enabled        = true,
    debounce       = DEFAULT_DEBOUNCE,
    invert_buttons = false,
    _debug_mode    = false,
    _debug_count   = 0,

    -- touch hook
    _orig_touch_handler = nil,
    _hook_active        = false,

    -- sweep accumulation
    _sweep_first  = nil,    -- first ABS_X value seen in this sweep
    _sweep_last   = nil,    -- most recent ABS_X value seen
    _sweep_has_mt = false,  -- real touch contamination flag
    _settle_fn    = nil,    -- scheduled classification callback

    -- capture diagnostic
    _cap_active   = false,
    _cap_events   = {},
    _cap_orig_kb  = nil,
    _cap_orig_gen = nil,

    -- inode watcher
    _watching    = false,
    _watch_inode = nil,
    _poll_fn     = nil,
    _miss_count  = 0,
}

-- ────────────────────────────────────────────────────────────────────────────
-- Helpers
-- ────────────────────────────────────────────────────────────────────────────

function TP1PageTurner:_sysRead(path)
    local f = io.open(path, "re")
    if not f then return nil end
    local s = f:read("*line"); f:close()
    return (s and s ~= "") and s:match("^%s*(.-)%s*$") or nil
end

function TP1PageTurner:_isMTK()
    if Device.isMTK and Device:isMTK() then return true end
    return Device.model ~= nil and MTK_MODELS[Device.model] ~= nil
end

function TP1PageTurner:_now()
    local t = UIManager:getTime()
    if type(t) == "number" then return t end
    if t and t.sec then return tonumber(t.sec) + tonumber(t.usec) / 1e6 end
    return os.time()
end

-- ────────────────────────────────────────────────────────────────────────────
-- Sweep classification
-- ────────────────────────────────────────────────────────────────────────────

function TP1PageTurner:_classifyAndAct()
    local first  = self._sweep_first
    local last   = self._sweep_last
    local has_mt = self._sweep_has_mt

    self._sweep_first  = nil
    self._sweep_last   = nil
    self._sweep_has_mt = false
    self._settle_fn    = nil

    if not first or not last then return end
    if has_mt then return end
    if first == last then return end

    if self._debug_mode then
        logger.info(string.format(
            "TP1PageTurner: sweep first=%d last=%d -> %s",
            first, last, first > last and "DOWN/next" or "UP/prev"))
    end

    local direction = first > last and "next" or "prev"

    local now = self:_now()
    if (now - self.last_turn_time) < self.debounce then return end
    self.last_turn_time = now

    local fwd = (direction == "next")
    if self.invert_buttons then fwd = not fwd end

    logger.info("TP1PageTurner: PAGE TURN ->", fwd and "NEXT" or "PREV")

    UIManager:scheduleIn(0, function()
        if self.ui then
            self.ui:handleEvent(Event:new("GotoViewRel", fwd and 1 or -1))
        end
    end)
end

-- ────────────────────────────────────────────────────────────────────────────
-- Touch hook
-- ────────────────────────────────────────────────────────────────────────────

function TP1PageTurner:_installHook()
    if self._hook_active then return end

    local plugin = self
    self._orig_touch_handler = Device.input.handleTouchEv

    Device.input.handleTouchEv = function(self_input, ev)
        if plugin.enabled and plugin.tp1_fd then
            local t = tonumber(ev.type)  or -1
            local c = tonumber(ev.code)  or -1
            local v = tonumber(ev.value) or  0

            if plugin._debug_mode then
                plugin._debug_count = (plugin._debug_count or 0) + 1
                logger.info(string.format("TP1[hook #%d] type=%d code=%d val=%d",
                    plugin._debug_count, t, c, v))
            end

            if t == EV_ABS then
                if c == ABS_X then
                    if not plugin._sweep_first then plugin._sweep_first = v end
                    plugin._sweep_last = v

                    if plugin._settle_fn then
                        UIManager:unschedule(plugin._settle_fn)
                    end
                    plugin._settle_fn = function()
                        plugin:_classifyAndAct()
                    end
                    UIManager:scheduleIn(SETTLE_DELAY, plugin._settle_fn)

                elseif c == ABS_MT_POSITION_X then
                    plugin._sweep_has_mt = true
                end
            end
        end

        if plugin._orig_touch_handler then
            return plugin._orig_touch_handler(self_input, ev)
        end
    end

    self._hook_active  = true
    self._sweep_first  = nil
    self._sweep_last   = nil
    self._sweep_has_mt = false
    self._settle_fn    = nil
    logger.info("TP1PageTurner: Touch hook installed.")
end

function TP1PageTurner:_removeHook()
    if not self._hook_active then return end
    if self._orig_touch_handler then
        Device.input.handleTouchEv = self._orig_touch_handler
        self._orig_touch_handler   = nil
    end
    self._hook_active  = false
    if self._settle_fn then
        UIManager:unschedule(self._settle_fn)
        self._settle_fn = nil
    end
    self._sweep_first  = nil
    self._sweep_last   = nil
    self._sweep_has_mt = false
    logger.info("TP1PageTurner: Touch hook removed.")
end

-- ────────────────────────────────────────────────────────────────────────────
-- Bluetooth helpers
-- ────────────────────────────────────────────────────────────────────────────

function TP1PageTurner:_btOn()
    -- D-Bus check (most reliable on MTK)
    local h = io.popen(MTK_BT_CHECK_CMD)
    if h then
        local r = h:read("*a"); h:close()
        if r and r:match("boolean%s+true") then return true end
    end
    -- Fallback: check if bluetoothd daemon is running
    local ret = os.execute("pgrep -x bluetoothd >/dev/null 2>&1")
    return ret == 0 or ret == true
end

function TP1PageTurner:_enableBT()
    if not self:_isMTK() then
        return false, "Not MTK -- use Kobo Settings to enable Bluetooth"
    end
    logger.info("TP1PageTurner: Enabling BT via D-Bus...")
    os.execute(MTK_BT_ON_CMD)
    os.execute(MTK_BT_POWER_CMD)
    os.execute("sleep 1")
    if self:_btOn() then
        return true, "Bluetooth enabled\n\nWake the ring (press a button),\nwait ~5 seconds, then tap\n'Connect / reconnect'."
    end
    return false, "BT commands sent but not confirmed.\nTry 'Connect / reconnect' in a few\nseconds, or use Kobo Settings."
end

function TP1PageTurner:_disableBT()
    logger.info("TP1PageTurner: Disabling BT...")
    self:_close()
    for _, cmd in ipairs(MTK_BT_OFF_CMDS) do
        os.execute(cmd)
    end
    -- ntx_io ioctl 126 = power down BT chip on MTK Kobo
    pcall(function()
        local ffi2 = require("ffi")
        local C2   = ffi2.C
        require("ffi/posix_h")
        local fd = C2.open("/dev/ntx_io",
            bit.bor(C2.O_RDONLY, C2.O_NONBLOCK, C2.O_CLOEXEC))
        if fd ~= -1 then
            C2.ioctl(fd, 126, ffi2.cast("int", 0))
            C2.close(fd)
        end
    end)
    os.execute("sleep 0.2")
    local still_on = self:_btOn()
    logger.info("TP1PageTurner: BT disable complete. Still on:", tostring(still_on))
    return not still_on
end

-- Always disable BT on MTK before handing back to Nickel.
-- Duplicates bluetoothsafety.koplugin intentionally -- harmless if both run.
function TP1PageTurner:_exitSafety(event_name)
    if not self:_isMTK() then
        self:_close()
        return
    end
    logger.info("TP1PageTurner:", event_name, "-- running MTK BT exit safety")
    self:_disableBT()
end

-- ────────────────────────────────────────────────────────────────────────────
-- Device detection
-- ────────────────────────────────────────────────────────────────────────────

function TP1PageTurner:_findByName()
    local lfs = require("libs/libkoreader-lfs")
    local dir = "/sys/class/input"
    for e in lfs.dir(dir) do
        if e:match("^event%d+$") then
            local n = self:_sysRead(dir.."/"..e.."/device/name")
                   or self:_sysRead(dir.."/"..e.."/name")
            if n and (n:find("TP%-1", 1, true) or n:find("TP_1", 1, true)
                   or n:lower():find("tp%-?1")) then
                return "/dev/input/"..e, n
            end
        end
    end
    return nil, nil
end

function TP1PageTurner:_findByUhid()
    local devs = {}
    local h = io.popen("ls -1d /sys/class/input/event* 2>/dev/null")
    if not h then return nil, nil end
    for ep in h:lines() do
        local lh = io.popen("readlink " .. ep .. " 2>/dev/null")
        if lh then
            local t = lh:read("*l"); lh:close()
            if t and t:match("uhid") then
                local n = ep:match("event(%d+)$")
                if n then
                    table.insert(devs, {
                        path = "/dev/input/event" .. n,
                        name = self:_sysRead("/sys/class/input/event" .. n .. "/device/name"),
                        num  = tonumber(n),
                    })
                end
            end
        end
    end
    h:close()
    if #devs == 0 then return nil, nil end
    table.sort(devs, function(a, b) return a.num < b.num end)
    for _, d in ipairs(devs) do
        if d.name and (d.name:find("TP%-1", 1, true) or d.name:lower():find("tp%-?1")) then
            return d.path, d.name
        end
    end
    if #devs == 1 then return devs[1].path, devs[1].name end
    for _, d in ipairs(devs) do
        logger.info("TP1PageTurner: uhid candidate:", d.path, d.name or "(unnamed)")
    end
    return devs[1].path, devs[1].name
end

function TP1PageTurner:_findDevice(verbose)
    if verbose then self:_logDevices() end
    local p, n = self:_findByName()
    if p then return p, n end
    if self:_isMTK() then
        p, n = self:_findByUhid()
        if p then return p, n end
    end
    logger.info("TP1PageTurner: Ring not found -- BT on and ring awake?")
    return nil, nil
end

function TP1PageTurner:_logDevices()
    local lfs = require("libs/libkoreader-lfs")
    local dir = "/sys/class/input"
    local entries = {}
    for e in lfs.dir(dir) do
        if e:match("^event%d+$") then table.insert(entries, e) end
    end
    table.sort(entries)
    logger.info("TP1PageTurner: Input device scan:")
    for _, e in ipairs(entries) do
        local n  = self:_sysRead(dir .. "/" .. e .. "/device/name")
                or self:_sysRead(dir .. "/" .. e .. "/name") or "(no name)"
        local lh = io.popen("readlink /sys/class/input/" .. e .. " 2>/dev/null")
        local t  = lh and lh:read("*l") or ""; if lh then lh:close() end
        logger.info(string.format("  /dev/input/%s [%s] = %s",
            e, t:match("uhid") and "BT" or "hw", n))
    end
end

-- ────────────────────────────────────────────────────────────────────────────
-- Open / close
-- ────────────────────────────────────────────────────────────────────────────

function TP1PageTurner:_open(verbose)
    if self.tp1_fd then return true end
    local path, name = self:_findDevice(verbose)
    if not path then return false end

    local ok, err = pcall(function() Device.input:open(path) end)
    if not ok then
        ok, err = pcall(function() Device.input:fdopen(nil, path, name or "TP-1") end)
        if not ok then
            logger.warn("TP1PageTurner: open failed:", err)
            return false
        end
    end

    self.tp1_event_path = path
    self.tp1_fd         = true
    logger.info("TP1PageTurner: Opened", path, name or "")

    local lfs  = require("libs/libkoreader-lfs")
    local attr = lfs.attributes(path)
    self._watch_inode = attr and attr.ino or nil

    self:_installHook()
    return true
end

function TP1PageTurner:_close()
    if not self.tp1_event_path then return end
    self:_removeHook()
    pcall(function() Device.input:close(self.tp1_event_path) end)
    logger.info("TP1PageTurner: Closed", self.tp1_event_path)
    self.tp1_event_path = nil
    self.tp1_fd         = nil
    self._watch_inode   = nil
end

-- ────────────────────────────────────────────────────────────────────────────
-- Inode watcher
-- ────────────────────────────────────────────────────────────────────────────

function TP1PageTurner:_startWatcher()
    if self._watching then return end
    self._watching   = true
    self._miss_count = 0
    local plugin     = self

    self._poll_fn = function()
        if not plugin._watching then return end

        if plugin.tp1_event_path and plugin._watch_inode then
            local lfs  = require("libs/libkoreader-lfs")
            local attr = lfs.attributes(plugin.tp1_event_path)
            if (attr and attr.ino or nil) ~= plugin._watch_inode then
                logger.info("TP1PageTurner: inode changed -- device lost")
                plugin:_close()
                plugin._miss_count = 1
                UIManager:scheduleIn(3, plugin._poll_fn)
                return
            end
        elseif plugin.enabled and not plugin.tp1_fd then
            plugin._miss_count = (plugin._miss_count or 0) + 1
            if plugin:_open(plugin._miss_count == 1) then
                plugin._miss_count = 0
            end
        end

        -- Backoff: 2s -> 4s -> 6s -> ... -> 15s max
        local delay = math.min(2 * (plugin._miss_count or 0) + 2, 15)
        UIManager:scheduleIn(delay, plugin._poll_fn)
    end

    UIManager:scheduleIn(2, self._poll_fn)
    logger.info("TP1PageTurner: Watcher started.")
end

function TP1PageTurner:_stopWatcher()
    if not self._watching then return end
    self._watching = false
    if self._poll_fn then
        UIManager:unschedule(self._poll_fn)
        self._poll_fn = nil
    end
    logger.info("TP1PageTurner: Watcher stopped.")
end

-- ────────────────────────────────────────────────────────────────────────────
-- Lifecycle hooks
-- ────────────────────────────────────────────────────────────────────────────

function TP1PageTurner:onCloseWidget()
    self:_stopWatcher(); self:_close()
end

function TP1PageTurner:onExit()
    self:_stopWatcher()
    self:_exitSafety("onExit")
end

function TP1PageTurner:onPowerOff()
    self:_stopWatcher()
    self:_exitSafety("onPowerOff")
end

function TP1PageTurner:onReboot()
    self:_stopWatcher()
    self:_exitSafety("onReboot")
end

function TP1PageTurner:onResume()
    if self.enabled and self._poll_fn then
        self._miss_count = 0
        UIManager:scheduleIn(3, self._poll_fn)
    end
end

-- ────────────────────────────────────────────────────────────────────────────
-- Settings
-- ────────────────────────────────────────────────────────────────────────────

function TP1PageTurner:_loadSettings()
    self.enabled        = G_reader_settings:nilOrTrue("tp1_enabled")
    self.debounce       = G_reader_settings:readSetting("tp1_debounce") or DEFAULT_DEBOUNCE
    self.invert_buttons = G_reader_settings:isTrue("tp1_invert_buttons")
    self._debug_mode    = G_reader_settings:isTrue("tp1_debug_mode")
end

-- ────────────────────────────────────────────────────────────────────────────
-- Init
-- ────────────────────────────────────────────────────────────────────────────

function TP1PageTurner:init()
    self:_loadSettings()
    self.ui.menu:registerToMainMenu(self)
    if self.enabled then
        UIManager:scheduleIn(3, function()
            if self:_open(true) then
                UIManager:show(InfoMessage:new{
                    text = _("TP-1 ring connected"), timeout = 2,
                })
            else
                logger.info("TP1PageTurner: Ring not found on init -- BT may be off")
            end
            self:_startWatcher()
        end)
    end
end

-- ────────────────────────────────────────────────────────────────────────────
-- Capture diagnostic
-- ────────────────────────────────────────────────────────────────────────────

function TP1PageTurner:_startCapture(duration)
    if self._cap_active then
        UIManager:show(InfoMessage:new{ text = _("Capture already running!"), timeout = 3 })
        return
    end
    duration         = duration or 15
    self._cap_active = true
    self._cap_events = {}
    local plugin     = self

    local function rec(pipe, ev)
        table.insert(plugin._cap_events, {
            p  = pipe,
            t  = tonumber(ev.type)  or 0,
            c  = tonumber(ev.code)  or 0,
            v  = tonumber(ev.value) or 0,
            ts = os.date("%H:%M:%S"),
        })
    end

    self._cap_orig_kb = Device.input.handleKeyBoardEv
    Device.input.handleKeyBoardEv = function(si, ev)
        if plugin._cap_active then rec("KEY", ev) end
        if plugin._cap_orig_kb then return plugin._cap_orig_kb(si, ev) end
    end

    self._cap_orig_gen = Device.input.handleGenericEv
    Device.input.handleGenericEv = function(si, ev)
        if plugin._cap_active then rec("GEN", ev) end
        if plugin._cap_orig_gen then return plugin._cap_orig_gen(si, ev) end
    end

    local saved_touch = self._orig_touch_handler or Device.input.handleTouchEv
    local cap_touch   = function(si, ev)
        if plugin._cap_active then rec("TOUCH", ev) end
        if saved_touch then return saved_touch(si, ev) end
    end
    Device.input.handleTouchEv  = cap_touch
    self._orig_touch_handler    = cap_touch

    UIManager:show(InfoMessage:new{
        text    = string.format(_("Capturing ALL events for %ds.\nPress ring buttons now!"), duration),
        timeout = 4,
    })
    UIManager:scheduleIn(duration, function() plugin:_stopCapture() end)
    logger.info("TP1PageTurner: Capture started for", duration, "seconds.")
end

function TP1PageTurner:_stopCapture()
    if not self._cap_active then return end
    self._cap_active = false

    if self._cap_orig_kb then
        Device.input.handleKeyBoardEv = self._cap_orig_kb
        self._cap_orig_kb = nil
    end
    if self._cap_orig_gen then
        Device.input.handleGenericEv = self._cap_orig_gen
        self._cap_orig_gen = nil
    end

    local events = self._cap_events
    logger.info("TP1PageTurner: Capture complete.", #events, "events.")

    if #events == 0 then
        UIManager:show(InfoMessage:new{
            text    = _("No events captured.\n\nMake sure:\n"
                     .. "- BT is ON\n- Ring is connected\n"
                     .. "- Then press ring buttons"),
            timeout = 10,
        })
        return
    end

    local enames = { [0]="SYN", [1]="KEY", [2]="REL", [3]="ABS", [4]="MSC" }
    local lines  = { "=== CAPTURE RESULTS ===", "" }

    local tc = {}
    for _, e in ipairs(events) do tc[e.t] = (tc[e.t] or 0) + 1 end
    for t, n in pairs(tc) do
        table.insert(lines, string.format("  EV_%s: %d events", enames[t] or ("T"..t), n))
    end

    table.insert(lines, "")
    table.insert(lines, "=== ABS_X values (sorted) ===")
    local abs_vals = {}
    local seen     = {}
    for _, e in ipairs(events) do
        if e.t == 3 and e.c == 0 and not seen[e.v] then
            seen[e.v] = true
            table.insert(abs_vals, e.v)
        end
    end
    if #abs_vals > 0 then
        table.sort(abs_vals)
        table.insert(lines, "  " .. table.concat(abs_vals, ", "))
        table.insert(lines, "  (DOWN = first > last, UP = first < last)")
        local fv = abs_vals[1]
        local lv = abs_vals[#abs_vals]
        table.insert(lines, string.format("  first=%d last=%d -> %s",
            fv, lv, fv > lv and "DOWN/next" or "UP/prev"))
    else
        table.insert(lines, "  (none -- ring may not be connected)")
    end

    table.insert(lines, "")
    table.insert(lines, "=== First 15 events ===")
    for i, e in ipairs(events) do
        if i > 15 then
            table.insert(lines, "  ... (" .. (#events - 15) .. " more in crash.log)")
            break
        end
        local line = string.format("  [%s][%s] EV_%s code=%d val=%d",
            e.ts, e.p, enames[e.t] or ("T"..e.t), e.c, e.v)
        table.insert(lines, line)
        logger.info("TP1 CAP:", line)
    end

    UIManager:show(InfoMessage:new{
        text    = table.concat(lines, "\n"),
        timeout = 25,
    })
end

-- ────────────────────────────────────────────────────────────────────────────
-- Connect helper
-- ────────────────────────────────────────────────────────────────────────────

function TP1PageTurner:_connect()
    if self.tp1_fd then self:_close() end
    if self:_open(true) then
        self:_startWatcher()
        UIManager:show(InfoMessage:new{
            text    = _("TP-1 ring connected\nPath: ") .. (self.tp1_event_path or "?"),
            timeout = 3,
        })
    else
        local bt = self:_btOn()
        UIManager:show(InfoMessage:new{
            text    = _("TP-1 not found.\n\n") .. (
                bt  and _("BT is ON but ring not found.\nWake ring (press button),\nwait 5s, then try again.")
                    or  _("BT appears OFF.\nTap 'Turn on Bluetooth' below,\nor use Kobo Settings > Bluetooth.")),
            timeout = 8,
        })
    end
end

-- ────────────────────────────────────────────────────────────────────────────
-- Menu
-- ────────────────────────────────────────────────────────────────────────────

function TP1PageTurner:addToMainMenu(menu_items)
    menu_items.tp1_pageturner = {
        text         = _("TP-1 Ring Page Turner"),
        sorting_hint = "more_tools",
        sub_item_table = {

            {
                text         = _("Enable TP-1 ring"),
                checked_func = function() return self.enabled end,
                callback     = function()
                    self.enabled = not self.enabled
                    G_reader_settings:saveSetting("tp1_enabled", self.enabled)
                    if self.enabled then
                        self:_connect()
                    else
                        self:_stopWatcher(); self:_close()
                        UIManager:show(InfoMessage:new{ text = _("TP-1 disabled."), timeout = 2 })
                    end
                end,
            },

            {
                text      = _("Turn on Bluetooth"),
                help_text = _("Powers on Bluetooth via MTK D-Bus.\nRing must already be paired via Kobo Settings."),
                callback  = function()
                    UIManager:show(InfoMessage:new{ text = _("Turning on Bluetooth..."), timeout = 2 })
                    UIManager:scheduleIn(0.5, function()
                        local ok, msg = self:_enableBT()
                        UIManager:show(InfoMessage:new{
                            text    = (ok and "OK: " or "FAIL: ") .. msg,
                            timeout = ok and 8 or 10,
                        })
                    end)
                end,
            },

            {
                text         = _("Connect / reconnect"),
                enabled_func = function() return self.enabled end,
                callback     = function() self:_connect() end,
            },

            {
                text      = _("Turn off Bluetooth"),
                help_text = _("Disconnects the ring and powers off Bluetooth.\nDo this when done reading to save battery.\nAlso runs automatically when exiting KOReader."),
                callback  = function()
                    UIManager:show(InfoMessage:new{ text = _("Turning off Bluetooth..."), timeout = 2 })
                    UIManager:scheduleIn(0.5, function()
                        self:_disableBT()
                        UIManager:show(InfoMessage:new{
                            text = _("Bluetooth off.\nRing disconnected."), timeout = 3,
                        })
                    end)
                end,
            },

            {
                text         = _("Swap button directions"),
                help_text    = _("Swap which physical button turns next vs previous page."),
                checked_func = function() return self.invert_buttons end,
                callback     = function()
                    self.invert_buttons = not self.invert_buttons
                    G_reader_settings:saveSetting("tp1_invert_buttons", self.invert_buttons)
                    UIManager:show(InfoMessage:new{
                        text = _("Swap: ") .. (self.invert_buttons and "ON" or "OFF"), timeout = 2,
                    })
                end,
            },

            {
                text           = _("Status"),
                keep_menu_open = true,
                callback       = function()
                    UIManager:show(InfoMessage:new{
                        text = table.concat({
                            "Device: " .. (Device.model or "?") .. (self:_isMTK() and " [MTK]" or ""),
                            "BT radio: " .. (self:_btOn() and "ON" or "OFF"),
                            "",
                            self.tp1_fd
                                and ("Ring: Connected\nPath: " .. (self.tp1_event_path or "?"))
                                or  "Ring: Not connected",
                            "Hook: "    .. (self._hook_active and "active" or "off"),
                            "Watcher: " .. (self._watching and "running" or "stopped"),
                            "",
                            "Settle delay: " .. SETTLE_DELAY .. "s",
                            "Debounce: "     .. self.debounce .. "s",
                            "Invert: "       .. tostring(self.invert_buttons),
                            "Debug: "        .. tostring(self._debug_mode),
                        }, "\n"),
                        timeout = 15,
                    })
                end,
            },

            { text = _("-- Diagnostics --"), enabled = false },

            {
                text         = _("Capture all events (15s)"),
                help_text    = _("Hooks all three event pipelines for 15 seconds.\nPress ring buttons during capture.\nShows ABS_X values and sweep direction."),
                enabled_func = function() return self.enabled end,
                callback     = function() self:_startCapture(15) end,
            },

            {
                text         = _("Debug mode (log to crash.log)"),
                help_text    = _("Logs every touch hook event to crash.log.\nTurn off when not needed -- verbose output."),
                checked_func = function() return self._debug_mode end,
                callback     = function()
                    self._debug_mode  = not self._debug_mode
                    self._debug_count = 0
                    G_reader_settings:saveSetting("tp1_debug_mode", self._debug_mode)
                    UIManager:show(InfoMessage:new{
                        text    = _("Debug: ") .. (self._debug_mode
                            and "ON\n\nPress ring buttons,\nthen check crash.log" or "OFF"),
                        timeout = 3,
                    })
                end,
            },

            {
                text           = _("Scan input devices"),
                keep_menu_open = true,
                callback       = function()
                    local lfs     = require("libs/libkoreader-lfs")
                    local dir     = "/sys/class/input"
                    local lines   = { "BT: " .. (self:_btOn() and "ON" or "OFF"), "" }
                    local entries = {}
                    for e in lfs.dir(dir) do
                        if e:match("^event%d+$") then table.insert(entries, e) end
                    end
                    table.sort(entries)
                    for _, e in ipairs(entries) do
                        local n  = self:_sysRead(dir .. "/" .. e .. "/device/name")
                               or self:_sysRead(dir .. "/" .. e .. "/name") or "(no name)"
                        local lh = io.popen("readlink /sys/class/input/" .. e .. " 2>/dev/null")
                        local t  = lh and lh:read("*l") or ""; if lh then lh:close() end
                        table.insert(lines, string.format("/dev/input/%s [%s] %s",
                            e, t:match("uhid") and "BT" or "hw", n))
                    end
                    UIManager:show(InfoMessage:new{
                        text = table.concat(lines, "\n"), timeout = 15,
                    })
                end,
            },

            {
                text           = _("Test page turn"),
                keep_menu_open = true,
                callback       = function()
                    self.ui:handleEvent(Event:new("GotoViewRel", 1))
                    UIManager:show(InfoMessage:new{ text = _("next page fired"), timeout = 1 })
                end,
            },

            {
                text           = _("Help"),
                keep_menu_open = true,
                callback       = function()
                    UIManager:show(InfoMessage:new{
                        text    = _("TP-1 Ring Page Turner v4.6\n\n"
                            .. "How it works:\n"
                            .. "Ring sweeps EV_ABS ABS_X values per press.\n"
                            .. "DOWN: sweeps downward (3500 -> 200)\n"
                            .. "UP:   sweeps upward   (200 -> 3500)\n"
                            .. "Plugin detects direction from first/last value.\n\n"
                            .. "Setup (once):\n"
                            .. "1. Pair ring via Kobo Settings > Bluetooth\n\n"
                            .. "Each use:\n"
                            .. "1. Turn on Bluetooth (menu above)\n"
                            .. "2. Press ring button to wake it\n"
                            .. "3. Wait ~5 seconds\n"
                            .. "4. Connect / reconnect\n"
                            .. "5. Press buttons to turn pages\n\n"
                            .. "Troubleshoot:\n"
                            .. "- Scan input devices -- ring shows [BT]?\n"
                            .. "- Capture events -- see ABS_X values\n"
                            .. "- Enable Debug -> check crash.log"),
                        timeout = 25,
                    })
                end,
            },

        },
    }
end

return TP1PageTurner
