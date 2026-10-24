//
// y700 (2026-10-16, v2): publish wiliwili's playback state for y700-refresh-auto, which matches the panel's refresh
// rate to the video (KWin 30 / 60 Hz mode while a 30 / 60 fps video plays fullscreen with no OSD, base 120 Hz otherwise).
// One small file, $XDG_RUNTIME_DIR/y700-video/wiliwili, rewritten atomically (tmp + rename) only when a field changes -
// never per frame:
//   pid=1234
//   playing=0|1     not paused, not stopped, not at EOF (one formula, recomputed on every input to it)
//   fullscreen=0|1  the drawn video view fills the app (VideoView::isFullscreen)
//   osd=0|1         the player OSD is drawn, or another activity (a translucent settings / speed panel) is on top
//   danmaku=0|1     danmaku are being drawn (the daemon then keeps >= 60 Hz: they move every refresh)
//   fps=29.970      EFFECTIVE fps = container-fps (else one rounded estimated-vf-fps sample) x playback speed; 0 = unknown
//   speed=1.000     raw_fps=29.970
// All calls come from the UI thread (mpv events are dispatched there with brls::sync, VideoView::draw runs there).
// No-op where XDG_RUNTIME_DIR is unset or not Linux.
//
#pragma once

#if defined(__linux__)
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <sys/stat.h>
#include <unistd.h>

namespace y700 {

struct VideoState {
    int playing = -1, fullscreen = -1, osd = -1, danmaku = -1;
    double fps = -1, speed = 1;
};

inline VideoState &videoState() {
    static VideoState s;
    return s;
}

inline void publishVideoState() {
    static std::string path, tmp;
    if (path.empty()) {
        const char *rt = getenv("XDG_RUNTIME_DIR");
        if (!rt || !*rt) return;
        std::string dir = std::string(rt) + "/y700-video";
        mkdir(dir.c_str(), 0700);
        path = dir + "/wiliwili";
        tmp  = path + ".tmp";
    }
    const VideoState &s = videoState();
    double raw          = s.fps > 0 ? s.fps : 0.0;
    FILE *f             = fopen(tmp.c_str(), "w");
    if (!f) return;
    fprintf(f, "pid=%d\nplaying=%d\nfullscreen=%d\nosd=%d\ndanmaku=%d\nfps=%.3f\nspeed=%.3f\nraw_fps=%.3f\n", (int)getpid(),
            s.playing > 0, s.fullscreen > 0, s.osd > 0, s.danmaku > 0, raw * s.speed, s.speed, raw);
    fclose(f);
    rename(tmp.c_str(), path.c_str());
}

inline void setVideoPlaying(bool v) {
    VideoState &s = videoState();
    if (s.playing != (int)v) {
        s.playing = v;
        publishVideoState();
    }
}

inline double knownFps() { return videoState().fps; }

// allowUnknown: a new file may have no fps (resets to unknown); a seek / restart never clears a known fps
inline void setVideoFps(double v, bool allowUnknown) {
    VideoState &s = videoState();
    if (!(v > 0) || v > 1000) {
        if (!allowUnknown) return;
        v = 0;
    }
    if (std::fabs(s.fps - v) > 0.01) {
        s.fps = v;
        publishVideoState();
    }
}

inline void setVideoSpeed(double v) {
    VideoState &s = videoState();
    if (!(v > 0) || v > 100) v = 1;
    if (std::fabs(s.speed - v) > 0.001) {
        s.speed = v;
        if (s.fps > 0) publishVideoState();
    }
}

inline void setVideoView(bool fullscreen, bool osd, bool danmaku) {
    VideoState &s = videoState();
    if (s.fullscreen != (int)fullscreen || s.osd != (int)osd || s.danmaku != (int)danmaku) {
        s.fullscreen = fullscreen;
        s.osd        = osd;
        s.danmaku    = danmaku;
        publishVideoState();
    }
}

}  // namespace y700
#else
namespace y700 {
inline void setVideoPlaying(bool) {}
inline double knownFps() { return 0; }
inline void setVideoFps(double, bool) {}
inline void setVideoSpeed(double) {}
inline void setVideoView(bool, bool, bool) {}
}  // namespace y700
#endif
