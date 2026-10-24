// Y700 (2026-10-16, v2): report the active window to y700-refresh-auto, which lowers the KWin mode to the video's rate
// only while the active window is a player showing a fullscreen video. Reports (resourceClass, covers, pid):
// covers = fullscreen, or the window takes >= 80 % of its output (a maximised player is fine, a half-screen one is not);
// pid lets the daemon match the window to the player's state file. Event-driven: activation, the active window's
// fullscreen / geometry changes; a report identical to the previous one is not sent again.
// Must stay ENABLED (metadata EnabledByDefault): the daemon reloads it with Scripting.start(), which unloads disabled
// scripts. If the daemon is not running the call fails silently (callDBus without a callback is asynchronous).
var hooked = {};
var last = null;

function covers(w) {
    if (!w) return false;
    if (w.fullScreen) return true;
    var o = w.output ? w.output.geometry : null;
    if (!o || o.width <= 0 || o.height <= 0) return false;
    return w.width * w.height >= 0.8 * o.width * o.height;
}

function report(w) {
    var cls = w ? String(w.resourceClass || "") : "";
    var c = covers(w);
    var pid = w ? (w.pid | 0) : 0;
    var key = cls + "|" + c + "|" + pid;
    if (key === last) return;
    last = key;
    callDBus("fyi.y700.RefreshAuto", "/RefreshAuto", "fyi.y700.RefreshAuto", "activeWindow", cls, c, pid);
}

function track(w) {
    if (!w || hooked[w.internalId]) return;
    hooked[w.internalId] = true;
    var again = function () { if (workspace.activeWindow === w) report(w); };
    w.fullScreenChanged.connect(again);
    w.frameGeometryChanged.connect(again);
    w.closed.connect(function () { delete hooked[w.internalId]; });
}

workspace.windowActivated.connect(function (w) {
    track(w);
    report(w);
});

track(workspace.activeWindow);
last = null;                      // a (re)load always reports once, even if the window did not change
report(workspace.activeWindow);
