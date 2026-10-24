// Y700 video state (2026-10-18), service worker: collects the frames' reports (content.js) and hands the one that
// matters to the native host fyi.y700.video_state, which writes $XDG_RUNTIME_DIR/y700-video/chrome-<browser pid> for
// y700-refresh-auto (same format as the wiliwili patch and the mpv script).
// The host only runs while some frame plays a video: the port is opened on the first "playing" and closed when none
// plays (the host removes its file on EOF), so an idle Chrome has no extra process and the worker can sleep. While
// the port is open it keeps this worker alive (Chrome >= 105). A frame's port closing (tab closed, navigated,
// crashed) drops its report.
// v1.5: the retry delay only goes back to 2 s after a host that ran for a while (a host that is missing or dies at once
// used to be relaunched every ~4 s while a video played, because postMessage succeeds before the launch fails); and a
// host that died while its file said playing (SIGKILL, OOM: no EOF, no SIGTERM, the file stays) is started once and
// closed again when nothing plays any more, so that it removes the stale file on EOF.
const HOST = "fyi.y700.video_state";
const frames = new Map(); // content-script port -> its last report
let host = null, sent = "", retryAt = 0, retryMs = 2000, openedAt = 0, stale = false;

function openHost() {
  if (host) return host;
  if (Date.now() < retryAt) return null;
  try {
    host = chrome.runtime.connectNative(HOST);
  } catch (e) {
    host = null;
    return null;
  }
  openedAt = Date.now();
  host.onDisconnect.addListener(() => {
    // the host exited or is not installed ("Specified native messaging host not found"): try again later. Not fired
    // for our own disconnect().
    console.warn("y700 video state host:", chrome.runtime.lastError && chrome.runtime.lastError.message);
    stale = stale || sent !== ""; // its file may still say playing
    retryMs = Date.now() - openedAt > 30000 ? 2000 : Math.min(retryMs * 2, 60000);
    host = null; sent = "";
    retryAt = Date.now() + retryMs;
    setTimeout(push, retryMs + 50);
  });
  return host;
}

function push() {
  let best = null; // a fullscreen one first, then the biggest
  for (const s of frames.values()) {
    if (s.playing && (!best || s.fullscreen > best.fullscreen || (s.fullscreen === best.fullscreen && s.area > best.area))) best = s;
  }
  if (!best) {
    if (!host && stale && openHost()) stale = false; // a fresh host just to remove the dead one's file (same name)
    if (host) { host.disconnect(); host = null; } // the host sees EOF and removes its file
    sent = "";
    return;
  }
  const msg = {playing: 1, fullscreen: best.fullscreen, osd: 0, danmaku: best.danmaku, fps: best.fps, why: best.why};
  const s = JSON.stringify(msg);
  if (s === sent && host) return;
  const h = openHost();
  if (!h) return;
  try { h.postMessage(msg); sent = s; stale = false; } catch (e) { host = null; sent = ""; }
}

chrome.runtime.onConnect.addListener((port) => {
  if (port.name !== "y700-video") return;
  port.onMessage.addListener((m) => {
    frames.set(port, {playing: m.playing ? 1 : 0, fullscreen: m.fullscreen ? 1 : 0, danmaku: m.danmaku ? 1 : 0,
                      fps: Number(m.fps) || 0, area: Number(m.area) || 0,
                      why: m.danmaku ? String(m.why || "").slice(0, 100) : ""});
    push();
  });
  port.onDisconnect.addListener(() => { frames.delete(port); push(); });
});
