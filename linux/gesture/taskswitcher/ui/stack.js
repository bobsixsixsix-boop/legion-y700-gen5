// y700 task switcher: stack geometry and springs (pure functions, no QML).
// The numbers are the approved design (linux/gesture/taskswitcher/design/y700-taskswitcher-mockup.html),
// whose ratios, exposure and springs follow the parameters of vivo OriginOS 6's phone stack (no vendor code or assets).
.pragma library

// card = work area x RATIO (same aspect as the screen, so a card zooms seamlessly into the app);
// LIFT moves the stack up from the vertical centre
const SCREENS = { land: { ratio: 0.6, lift: 26 }, port: { ratio: 0.683, lift: 40 } };
const EXPOSED = 0.7845, EDGE0 = -10, RADIUS = 18, HEAD = 44;

// W x H = the work area (the screen minus the panel), in logical px
function geometry(W, H) {
    const s = W >= H ? SCREENS.land : SCREENS.port;
    const cw = W * s.ratio, ch = H * s.ratio, E = EXPOSED * cw;
    const X = d => EDGE0 + (E / 27) * (Math.pow(3, 3 - d) - 1) / 2;
    const xs = [[-2, X(-1) + 1.5 * E], [-1, X(-1)], [0, X(0)], [1, X(1)], [2, X(2)], [3, X(3)], [4, EDGE0]];
    const top = Math.round((H - ch) / 2 - s.lift);
    // vivo rests the two END cards centred: 3 * int(x0 - centred x) px of scroll
    const delta = 3 * Math.trunc(X(0) - (W - cw) / 2) / E;
    return { W, H, ratio: s.ratio, cw, ch, E, xs, top, delta, k: 1 / s.ratio };
}

// per depth slot d (0 = front, 1.. older ones behind on the left, -1 the newer card on top at the right)
const T = {
    scale:  [[-2, 1.032], [-1, 1.016], [0, 1], [1, .984], [2, .968], [3, .953], [4, .953]],
    dim:    [[-1, 0], [0, 0], [1, .1], [2, .2], [3, .1], [4, 0]],
    alpha:  [[2, 1], [3, .4], [4, 0]],
    head:   [[1, 1], [2, .6], [3, 0]],
    shadow: [[-1, 1], [0, .6], [1, .45], [2, .3], [3, 0]],
};

function lin(t, d) {
    if (d <= t[0][0]) return t[0][1];
    for (let i = 1; i < t.length; i++) {
        if (d <= t[i][0]) {
            const a = t[i - 1][0], va = t[i - 1][1], b = t[i][0], vb = t[i][1];
            return va + (vb - va) * (d - a) / (b - a);
        }
    }
    return t[t.length - 1][1];
}

// piecewise linear like vivo; beyond the last newer slot it keeps its slope (off screen)
function xAt(G, d) {
    const t = G.xs;
    if (d < t[0][0]) return t[0][1] + (t[0][0] - d) * (t[0][1] - t[1][1]);
    return lin(t, d);
}

function clamp(v, a, b) {
    if (a === undefined) a = 0;
    if (b === undefined) b = 1;
    return Math.min(b, Math.max(a, v));
}

// vivo names the front card only: it keeps the name until 70 % of the way out; the next one fades in
function labelAlpha(dp) {
    if (dp > -1 && dp <= 0) return -dp < .7 ? 1 : 1 - (-dp - .7) / .3;
    if (dp > 0 && dp < 1) return 1 - dp;
    return 0;
}

// springs: mass 1, k stiffness, zeta damping ratio
const K = {
    scroll: [200, 34 / (2 * Math.sqrt(200))],   // the reference's snap spring (tension 200, friction 34): zeta 1.2
    zoom:   [214, 1],
    enter:  [214, 1],
    leave:  [500, 1],
    blur:   [1200, 1],
    back:   [500, .89],
    fly:    [200, .9],
    slot:   [260, .83],
    press:  [1600, 1],
    home:   [420, 1],
    lift:   [500, 1],
};

class Spring {
    constructor(v, k, z, eps) {
        this.v = v; this.t = v; this.vel = 0; this.eps = eps === undefined ? 5e-4 : eps; this.held = false;
        this.set(k === undefined ? 200 : k, z === undefined ? 1 : z);
    }
    set(k, z) { this.k = k; this.c = 2 * z * Math.sqrt(k); return this; }
    // to(target) keeps the parameters; to(target, k, z[, vel]) sets them (and the velocity)
    to(t, k, z, vel) {
        this.t = t;
        if (k) this.set(k, z);
        if (vel !== undefined) this.vel = vel;
        return this;
    }
    jump(v) { this.v = this.t = v; this.vel = 0; }
    step(dt, reduced) {
        if (this.held) return;
        if (reduced) { this.v = this.t; this.vel = 0; return; }
        const n = Math.max(1, Math.ceil(dt / 0.002)), h = dt / n;   // 2 ms substeps: stiff springs stay stable
        for (let i = 0; i < n; i++) {
            const a = -this.k * (this.v - this.t) - this.c * this.vel;
            this.vel += a * h;
            this.v += this.vel * h;
        }
        if (this.rest) { this.v = this.t; this.vel = 0; }
    }
    get rest() { return Math.abs(this.v - this.t) < this.eps && Math.abs(this.vel) < this.eps * 20; }
}

function spring(v, p, eps) { return new Spring(v, p[0], p[1], eps); }

// px/ms over the last 70 ms of samples {x, y, t}; 0 when the finger has rested 60 ms (no stale flick)
function velocity(samples, now) {
    const p = samples, n = p.length - 1;
    if (n < 1 || now - p[n].t > 60) return { x: 0, y: 0 };
    let i = n;
    while (i > 0 && p[n].t - p[i - 1].t < 70) i--;
    if (i === n) i = n - 1;
    const dt = Math.max(1, p[n].t - p[i].t);
    return { x: (p[n].x - p[i].x) / dt, y: (p[n].y - p[i].y) / dt };
}

// header text: the application, not the document ("TaskList.qml — Kate" -> "Kate")
function appName(caption) {
    const c = String(caption || "");
    const parts = c.split(/\s[—–-]\s/);
    const last = parts[parts.length - 1].trim();
    return parts.length > 1 && last.length > 0 && last.length <= 32 ? last : c;
}

// games and streams close on the second swipe only (owner 2026-10-21: "游戏要划两次"): for a Proton game
// closeWindow is WM_CLOSE, which most games take as "quit now, no save". Matched on the window class and
// the desktop file name.
function guarded(resourceClass, desktopFileName) {
    const ids = String(resourceClass) + " " + String(desktopFileName);
    return /(^|\s)(steam_app_|steam_proton|gamescope|livi\b|dev\.f-io\.livi)|moonlight/i.test(ids);
}
