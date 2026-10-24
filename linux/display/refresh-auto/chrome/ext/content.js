// Y700 video state (2026-10-18), in every frame: does this frame have a playing video that fills the screen, at what
// effective frame rate, and does something move over it (danmaku)? Sent to sw.js over a port, only when it changes.
//   playing    not paused / ended / seeking, enough data to play (readyState >= 3), has a picture
//   fullscreen the video is (inside) the fullscreen element, or covers >= 80 % of the screen (in a fullscreen iframe,
//              or a page's own "web fullscreen")
//   fps        decoded frames per media second (getVideoPlaybackQuality().totalVideoFrames counts decoded frames,
//              dropped ones included, so it stays right after the panel went down to 30 Hz) times playbackRate: the
//              least-squares slope over the last 2-10 s of samples; 0 = not known yet. The decoder runs ahead of
//              currentTime by its queue, which it fills after every (re)start and, on a looping video, with the start
//              of the next loop before currentTime wraps: samples from the first 1.5 media seconds after a restart and
//              from the last 1.5 s before a loop point are left out (with them a 6 s loop read 59.35-61.04, and
//              y700-refresh-auto maps only 58-61 to 60 Hz). Kept across seeks, loops and pauses of the same video (only
//              a new video element or a new source clears it): a cleared rate sent the panel to 120 Hz for ~4 s each time
//   danmaku    >= 3 small visible elements painted over the video (each < 25 % of it, mostly inside it) with running
//              CSS animations/transitions, or a visible canvas over most of the video; held 8 s after the last sight
//              (quiet moments between comments must not flip 30/60 Hz). y700-refresh-auto then keeps at least 60 Hz
//              (things moving over the video show 30 Hz steps). Big animated layers (UI gradients, spinners'
//              containers, overlays) do not count: one of those made YouTube report danmaku in the first version.
//              `why` names what was seen (written to the state file for diagnosis, ignored by the daemon)
// A seek of the tracked video that nobody asked for (a loop) or a short stall keeps the last report for up to 2 s:
// reporting "not playing" for those few ms removed the state file, and y700-refresh-auto went 60 -> 120 Hz at once and
// back after its enter delay, at every loop of a clip.
// Quiet page (v1.4): while a video's fullscreen element is up, everything outside it is hidden (visibility). A fullscreen
// element covers the page completely, but Chrome keeps compositing and drawing the page behind it: YouTube's watch
// page (144 layers, 119 of them drawing, about 50 screens of layer area) held the GPU at ~600 MHz and cost 1.3 W at
// 60 fps (A 3.90 / 3.83 W against 2.56 / 2.59 W with the rest hidden, mirrored order, linux/video/chrome-video-power-ab.sh).
// Nothing visible changes: a fullscreen element has a black ::backdrop and the page is under it anyway.
// Work: event-driven (media events are caught on the document in the capture phase), plus one sample a second only
// while a video plays.
// v1.5 (audit, 2026-10-18): a frame talks to the service worker only once it has had a playing video (before, every frame
// of every page load, ads included, opened a port and woke the worker to say "not playing"); a hidden document (a
// background tab, a minimized window) never reports fullscreen (a big muted background video or a theater-mode video in
// another tab lowered the panel while the user read something else); the prefixed webkitfullscreenchange is listened to
// as well (Chrome fires only that one for webkitRequestFullscreen(), and after leaving such a fullscreen while paused the
// page stayed hidden until the next media event).
(() => {
  if (window.__y700VideoState) return;
  window.__y700VideoState = true;
  let port = null, last = "", timer = 0, tracked = null, lastFps = 0, dmUntil = 0, dmWhy = "", stallSince = 0;
  let prev = null, warmT = -1; // the last sample, usable or not; media time of the last (re)start (-1: not seen yet)
  const win = []; // [{t: currentTime, n: totalVideoFrames}] of the tracked video since its last discontinuity
  function restart() { win.length = 0; prev = null; warmT = -1; }

  function connect() {
    try {
      port = chrome.runtime.connect({name: "y700-video"});
      port.onDisconnect.addListener(() => { void chrome.runtime.lastError; port = null; last = ""; });
    } catch (e) {
      port = null; // the extension was reloaded: this copy of the script is orphaned
    }
  }

  function send(st) {
    const s = JSON.stringify(st);
    if (s === last && port) return;
    if (!port) connect();
    if (!port) return;
    try { port.postMessage(st); last = s; } catch (e) { port = null; last = ""; }
  }

  function rect(el) { const r = el.getBoundingClientRect(); return Math.max(0, r.width) * Math.max(0, r.height); }
  function playing(v) { return !v.paused && !v.ended && !v.seeking && v.readyState >= 3 && v.videoWidth > 0; }
  function stalled(v) { return !v.paused && !v.ended && v.videoWidth > 0 && (v.seeking || v.readyState < 3); }
  function inFullscreen(v) { const f = document.fullscreenElement; return !!f && (f === v || f.contains(v)); }
  function full(v) {
    return document.visibilityState !== "hidden" && (inFullscreen(v) || rect(v) >= 0.8 * screen.width * screen.height);
  }
  function reported() { return last.startsWith('{"playing":1'); } // the worker has a "playing" report of this frame

  // Hide what the fullscreen element covers. Only `body` is hidden and only the fullscreen element made visible again
  // (not its descendants: they inherit, and things inside the player that hide themselves stay hidden). Applies only
  // when the element is in this document's light DOM (:fullscreen of a document style sheet cannot match inside a
  // shadow tree, which would hide the video itself) and holds a video (or is a video or an iframe, whose own frame has
  // its own copy of this script); never for the whole page (html/body fullscreen).
  const QUIET = "y700-fullscreen-quiet";
  function quiet() {
    const f = document.fullscreenElement;
    const on = !!f && f !== document.documentElement && f !== document.body && f.matches(":fullscreen") &&
      (f.localName === "video" || f.localName === "iframe" || !!f.querySelector("video"));
    const st = document.getElementById(QUIET);
    if (on && !st) {
      const s = document.createElement("style");
      s.id = QUIET;
      s.textContent = "body{visibility:hidden!important}:fullscreen{visibility:visible!important}";
      (document.head || document.documentElement).appendChild(s);
    } else if (!on && st) {
      st.remove();
    }
  }

  function overlap(a, b) {
    const r = a.getBoundingClientRect(), s = b.getBoundingClientRect();
    const w = Math.min(r.right, s.right) - Math.max(r.left, s.left), h = Math.min(r.bottom, s.bottom) - Math.max(r.top, s.top);
    return w > 0 && h > 0 ? w * h : 0;
  }
  function visible(e) {
    return e.checkVisibility ? e.checkVisibility({checkOpacity: true, checkVisibilityCSS: true}) : true;
  }
  function above(v, e) { return !!(v.compareDocumentPosition(e) & Node.DOCUMENT_POSITION_FOLLOWING); } // paint order
  function desc(e) {
    if (!e) return "";
    const c = typeof e.className === "string" ? e.className.trim().split(/\s+/)[0] : "";
    return (e.tagName.toLowerCase() + (e.id ? "#" + e.id : "") + (c ? "." + c : "")).replace(/[^A-Za-z0-9#._-]/g, "").slice(0, 40);
  }

  function playerBox(v) {
    if (inFullscreen(v)) return document.fullscreenElement;
    let box = v; // web fullscreen: walk up while the ancestor is not much bigger than the video
    while (box.parentElement && box.parentElement !== document.body && rect(box.parentElement) <= 1.3 * rect(v)) {
      box = box.parentElement;
    }
    return box === v ? (v.parentElement || document.body) : box;
  }

  // what moves over the video ("" = nothing): see the header
  function moving(v) {
    const box = playerBox(v), va = rect(v), seen = new Set();
    let first = null;
    for (const a of document.getAnimations()) {
      const t = a.playState === "running" && a.effect && a.effect.target;
      if (!t || seen.has(t) || t === v || t.contains(v) || !box.contains(t)) continue;
      const ta = rect(t);
      if (ta <= 0 || ta >= 0.25 * va || overlap(t, v) < 0.5 * ta || !above(v, t) || !visible(t)) continue;
      seen.add(t); first = first || t;
      if (seen.size >= 3) return "anim " + desc(first.parentElement) + ">" + desc(first);
    }
    for (const c of box.querySelectorAll("canvas")) {
      if (c.width > 0 && c.height > 0 && overlap(c, v) >= 0.5 * va && above(v, c) && visible(c)) return "canvas " + desc(c);
    }
    return "";
  }

  function danmaku(v) {
    const why = moving(v), now = Date.now();
    if (why) { dmUntil = now + 8000; dmWhy = why; }
    return now < dmUntil;
  }

  function fps(v) {
    const q = v.getVideoPlaybackQuality ? v.getVideoPlaybackQuality() : null;
    if (!q) return 0;
    if (tracked !== v) { tracked = v; restart(); lastFps = 0; }
    const sp = Math.max(1, v.playbackRate), now = {t: v.currentTime, n: q.totalVideoFrames}, p = prev;
    prev = now;
    if (p && (now.t < p.t || now.n < p.n || now.t - p.t > 4 * sp)) { restart(); prev = now; } // seek, loop, stall
    if (v.loop && v.duration - now.t < 1.5 * sp) return lastFps; // the decoder is at the next loop already
    if (warmT < 0) warmT = now.t;
    if (now.t - warmT < 1.5 * sp) return lastFps; // the decoder fills its queue
    win.push(now);
    while (win.length > 11) win.shift();
    if (now.t - win[0].t < 1.9 * sp) return lastFps;
    let mt = 0, mn = 0, num = 0, den = 0;
    for (const s of win) { mt += s.t; mn += s.n; }
    mt /= win.length; mn /= win.length;
    for (const s of win) { num += (s.t - mt) * (s.n - mn); den += (s.t - mt) * (s.t - mt); }
    const f = num / den * v.playbackRate;
    if (Math.abs(f - lastFps) > 0.6) lastFps = Math.round(f * 100) / 100; // no rewrite for every small wobble
    return lastFps;
  }

  function tick() {
    quiet(); // a video that starts after the fullscreen element went up
    let best = null, area = 0;
    for (const v of document.querySelectorAll("video")) {
      if (!playing(v)) continue;
      const a = rect(v);
      if (a > area) { best = v; area = a; }
    }
    if (!best) {
      if (tracked && tracked.isConnected && stalled(tracked) && reported()) {
        const now = Date.now();
        if (!stallSince) stallSince = now;
        if (now - stallSince < 2000) { if (!timer) timer = setInterval(tick, 1000); return; } // see the header
      }
      stallSince = 0;
      if (timer) { clearInterval(timer); timer = 0; }
      restart(); dmUntil = 0; // tracked and lastFps stay: a resumed video has its rate at once
      if (reported()) send({playing: 0, fullscreen: 0, danmaku: 0, fps: 0, area: 0, why: ""}); // else: nothing to take back
      return;
    }
    stallSince = 0;
    if (!timer) timer = setInterval(tick, 1000);
    const f = full(best), dm = f && danmaku(best);
    send({playing: 1, fullscreen: f ? 1 : 0, danmaku: dm ? 1 : 0, fps: fps(best), area: Math.round(area), why: dm ? dmWhy : ""});
  }

  const newSource = new Set(["emptied", "loadstart", "loadedmetadata"]); // a new video in the same element (YouTube)
  for (const ev of ["play", "playing", "pause", "ended", "seeking", "seeked", "waiting", "canplay", "ratechange",
                    "emptied", "loadstart", "loadedmetadata", "resize"]) {
    document.addEventListener(ev, (e) => {
      if (e.target === tracked) {
        if (newSource.has(ev)) { restart(); lastFps = 0; } else if (ev === "seeking") restart();
      }
      tick();
    }, true);
  }
  for (const ev of ["fullscreenchange", "webkitfullscreenchange", "visibilitychange"]) document.addEventListener(ev, tick, true);
  window.addEventListener("pagehide", () => {
    const st = document.getElementById(QUIET); // a page coming back from the back/forward cache must not stay hidden
    if (st) st.remove();
    if (timer) { clearInterval(timer); timer = 0; }
    if (reported()) send({playing: 0, fullscreen: 0, danmaku: 0, fps: 0, area: 0, why: ""});
    if (port) { try { port.disconnect(); } catch (e) {} port = null; }
    last = "";
  });
  window.addEventListener("pageshow", tick);
  tick();
})();
