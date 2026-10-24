-- y700-video-state.lua (2026-10-16, v2): standalone mpv's playback state for y700-refresh-auto, same format as the
-- wiliwili patch: $XDG_RUNTIME_DIR/y700-video/mpv-<pid>, rewritten (tmp + rename) only when a field changes.
--   pid  playing (file loaded, video output up, not paused, not at EOF, not idle)  fullscreen  osd (always 0: mpv's
--   OSC visibility is not observable; a touch sends the panel back to the base anyway)  danmaku=0
--   fps = effective fps = (container-fps, else ONE rounded sample of estimated-vf-fps taken 1.5 s into the file) x speed
--   (estimated-vf-fps changes on nearly every frame and is not observed: that rewrote the file ~30 times a second)
-- Installed to ~/.config/mpv/scripts/. wiliwili's embedded libmpv does not load it (its config dir is ~/.config/wiliwili,
-- scripts are off there); the wiliwili patch reports for wiliwili.
local utils = require "mp.utils"
local rt = os.getenv("XDG_RUNTIME_DIR")
if not rt or rt == "" then return end
local dir = rt .. "/y700-video"
mp.command_native({name = "subprocess", args = {"mkdir", "-p", "-m", "700", dir}, playback_only = false})
local pid = utils.getpid()
local path, tmp = dir .. "/mpv-" .. pid, dir .. "/mpv-" .. pid .. ".tmp"
local last, est = "", nil

local function fps()
    local f = mp.get_property_native("container-fps")
    if not f or f <= 0 then f = est or 0 end
    return f * (mp.get_property_native("speed") or 1)
end

local function publish()
    local playing = not mp.get_property_native("idle-active") and not mp.get_property_native("pause")
        and not mp.get_property_native("eof-reached") and mp.get_property_native("vo-configured")
        and mp.get_property_native("current-tracks/video") ~= nil
    local s = string.format("pid=%d\nplaying=%d\nfullscreen=%d\nosd=0\ndanmaku=0\nfps=%.3f\n", pid,
        playing and 1 or 0, mp.get_property_native("fullscreen") and 1 or 0, fps())
    if s == last then return end
    last = s
    local f = io.open(tmp, "w")
    if not f then return end
    f:write(s); f:close()
    os.rename(tmp, path)
end

for _, p in ipairs({"pause", "fullscreen", "idle-active", "eof-reached", "container-fps", "speed", "vo-configured"}) do
    mp.observe_property(p, "native", publish)
end
mp.register_event("file-loaded", function()
    est = nil
    if not mp.get_property_native("container-fps") then
        mp.add_timeout(1.5, function()
            local e = mp.get_property_native("estimated-vf-fps")
            if e and e > 0 then est = math.floor(e + 0.5); publish() end
        end)
    end
end)
mp.register_event("shutdown", function() os.remove(path) end)
