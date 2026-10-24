#!/usr/bin/env python3
# make-wiliwili-patch.py TREE OUTDIR (v2, 2026-10-16): apply the y700 video-state hooks to a COPY of the wiliwili sources
# under OUTDIR (a/ = untouched copy, b/ = edited) so that `diff -ruN a b` is the patch. Every anchor must match exactly
# once. TREE must not carry an earlier version of this patch (reverse-apply it first). UTF-8, line endings kept.
import os, shutil, sys
tree, out = sys.argv[1], sys.argv[2]
files = ["wiliwili/source/view/mpv_core.cpp", "wiliwili/source/view/video_view.cpp"]
for side in ("a", "b"):
    for f in files:
        os.makedirs(os.path.dirname(f"{out}/{side}/{f}"), exist_ok=True)
        shutil.copy(f"{tree}/{f}", f"{out}/{side}/{f}")


def edit(f, pairs):
    p = f"{out}/b/{f}"
    s = open(p, encoding="utf-8", newline="").read()
    assert "y700_video_state" not in s, f"{f}: already carries the video-state hooks"
    for old, new in pairs:
        n = s.count(old)
        assert n == 1, f"{f}: anchor found {n} times: {old[:70]!r}"
        s = s.replace(old, new)
    open(p, "w", encoding="utf-8", newline="").write(s)


INC = '#include "utils/y700_video_state.hpp"  // y700: playback state for y700-refresh-auto\n'
PLAY = "y700::setVideoPlaying(!video_paused && !video_stopped && !video_eof);"
edit("wiliwili/source/view/mpv_core.cpp", [
    ("#include <cmath>\n", "#include <cmath>\n" + INC),
    # a new file: its fps (unknown allowed: the previous file's fps must not carry over), autoplay decides playing
    ('                command_async("playlist-clear");\n',
     '                command_async("playlist-clear");\n'
     '                y700::setVideoFps(getDouble("container-fps"), true);\n'
     '                y700::setVideoPlaying(AUTO_PLAY);\n'),
    # playback (re)started (also after every seek): never clear a known fps; if still unknown, one estimated sample
    ("                video_stopped = false;\n                mpvCoreEvent.fire(MpvEventEnum::LOADING_END);\n",
     "                video_stopped = false;\n"
     "                {\n"
     '                    double f = getDouble("container-fps");\n'
     "                    if (f > 0) {\n"
     "                        y700::setVideoFps(f, false);\n"
     "                    } else if (!(y700::knownFps() > 0)) {\n"
     "                        brls::delay(1500, [this]() {\n"
     '                            double e = getDouble("estimated-vf-fps");\n'
     "                            if (e > 0 && !(y700::knownFps() > 0)) y700::setVideoFps(std::round(e), false);\n"
     "                        });\n"
     "                    }\n"
     "                }\n"
     f"                {PLAY}\n"
     "                mpvCoreEvent.fire(MpvEventEnum::LOADING_END);\n"),
    ("                video_stopped = true;\n                auto node     = (mpv_event_end_file *)event->data;\n",
     "                video_stopped = true;\n"
     f"                {PLAY}\n"
     "                auto node     = (mpv_event_end_file *)event->data;\n"),
    ("                        if (data) video_eof = *(int *)data;\n",
     "                        if (data) video_eof = *(int *)data;\n"
     f"                        {PLAY}\n"),
    ("                            video_speed = *(double *)data;\n",
     "                            video_speed = *(double *)data;\n"
     "                            y700::setVideoSpeed(video_speed);\n"),
    ("                        if (data) video_paused = *(int *)data;\n",
     "                        if (data) video_paused = *(int *)data;\n"
     f"                        {PLAY}\n"),
    ("                        if (data) video_stopped = *(int *)data;\n",
     "                        if (data) video_stopped = *(int *)data;\n"
     f"                        {PLAY}\n"),
])
edit("wiliwili/source/view/video_view.cpp", [
    ("#include <cmath>\n", "#include <cmath>\n" + INC),
    ("    bool drawOSD       = this->osd_state == OSDState::ALWAYS_ON || current < this->osdLastShowTime;\n",
     "    bool drawOSD       = this->osd_state == OSDState::ALWAYS_ON || current < this->osdLastShowTime;\n"
     "    {   // y700: view state for y700-refresh-auto (written only when it changes). Another activity on top (a\n"
     "        // translucent settings / speed panel over the fullscreen video) counts as OSD: the UI is in use.\n"
     "        auto stack   = brls::Application::getActivitiesStack();\n"
     "        bool covered = !stack.empty() && stack.back() != this->getParentActivity();\n"
     "        y700::setVideoView(this->isFullscreen(), drawOSD || covered, this->enableDanmaku && DanmakuCore::DANMAKU_ON);\n"
     "    }\n"),
])
os.makedirs(f"{out}/b/wiliwili/include/utils", exist_ok=True)
shutil.copy(os.path.join(os.path.dirname(os.path.abspath(__file__)), "y700_video_state.hpp"),
            f"{out}/b/wiliwili/include/utils/y700_video_state.hpp")
print("ok")
