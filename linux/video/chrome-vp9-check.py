"""chrome-vp9-check.py: the DevTools side of chrome-vp9-check.sh (see there for why and what PASS means).
usage: python3 -I chrome-vp9-check.py --port P --http HP --log chrome.log --out summary.json [--youtube URL] [--errts 0|1]
       [--only webcodecs,video,youtube]
Drives the first page of a Chrome started with --remote-debugging-port=P whose stderr goes to chrome.log (with
IRIS_VAAPI_DEBUG=1), serving the clips on http://127.0.0.1:HP/. Each part's libva-v4l2 trace lines are the chrome.log
bytes written while it ran. --errts 0: the kernel has no iris 1051 (y13 and older), no no-show buffer is expected.
Prints one line per check, exit 0 when nothing FAILed."""
import argparse, json, os, sys, time, urllib.request
import websocket

TRACE = {   # libva-v4l2 trace lines (src/decoder.cpp, src/vp9.cpp; 0001 adds the no-show ones)
    "decoded": "decoded token=", "noshow": "no-show CAPTURE token=", "invisible": "VP9 invisible reference",
    "replaced": "replaced damaged picture", "nopic": "no picture after no-show",
    "discarding": "discarding completed token", "damaged": "completed damaged token", "timeout": "sync timeout",
}

JS_LIB = r"""
window.__y7lib = true;
window.lumaOf = (cx, w, h) => { const d = cx.getImageData(0, 0, w, h).data, y = new Uint8Array(w * h);
  for (let i = 0, j = 0; i < d.length; i += 4, j++) y[j] = (54 * d[i] + 183 * d[i + 1] + 19 * d[i + 2]) >> 8; return y; };
window.statOf = y => { let s = 0, s2 = 0; for (const v of y) { s += v; s2 += v * v; } const m = s / y.length;
  return {mean: m, std: Math.sqrt(Math.max(0, s2 / y.length - m * m))}; };
// libva-v4l2 fills a damaged picture with neutral gray: flat, mid-level
window.isGray = st => st.std <= 2 && st.mean >= 100 && st.mean <= 160;
// FFmpeg's reference thumbnails (rgb24 192x108 per frame, BT.709 limited range -> full) as luma, same weights
window.loadRef = async url => { const b = new Uint8Array(await (await fetch(url)).arrayBuffer()), n = 192 * 108, fr = [];
  for (let o = 0; o + n * 3 <= b.length; o += n * 3) { const y = new Uint8Array(n);
    for (let i = 0, j = o; i < n; i++, j += 3) y[i] = (54 * b[j] + 183 * b[j + 1] + 19 * b[j + 2]) >> 8; fr.push(y); }
  return fr; };
// FNV-1a over the visible Y plane of a copyTo() buffer (8-bit formats)
window.yHash = (buf, pl, w, h) => { let x = 0x811c9dc5;
  for (let r = 0; r < h; r++) { const o = pl.offset + r * pl.stride; for (let c = 0; c < w; c++) { x ^= buf[o + c]; x = Math.imul(x, 0x01000193); } }
  return x >>> 0; };
// every 8th row of the visible Y plane of a copyTo() buffer (8-bit formats), tightly packed
window.ROWSTEP = 8;
window.yRows = (buf, pl, w, h) => { const n = Math.ceil(h / ROWSTEP), y = new Uint8Array(w * n);
  for (let k = 0; k < n; k++) { const o = pl.offset + k * ROWSTEP * pl.stride; y.set(buf.subarray(o, o + w), k * w); } return y; };
// Chrome 155 reads a hardware frame back (copyTo; drawImage too) through RGB, and on this stack the YUV -> RGB step
// uses BT.601 although the frame is tagged BT.709, while RGB -> YUV uses BT.709 (10-23: fitted on the 8-bit clips, the
// model below leaves 0.3 mean / 1 max on every pixel; every other combination of 601/709 and limited/full range
// leaves >= 3, see the README). The BT.601 is Chrome's EGL colour-space hint (ui/ozone/common/native_pixmap_egl_binding.cc
// passes REC601 for everything but BT.2020); with yuv709-shim.c preloaded, or once Chrome passes the frame's BT.709, the
// YUV -> RGB step is BT.709 instead, so both models are tried. This replays one on a software (I420) frame: YUV with
// matrix dm (601|709), full range df -> 8-bit RGB -> Y with matrix em, full range ef; same rows as yRows. Chroma: nearest.
window.rgbRT = (buf, l, w, h, dm, df, em, ef) => { const n = Math.ceil(h / ROWSTEP), y = new Uint8Array(w * n);
  const K = m => m === 601 ? [0.299, 0.114] : [0.2126, 0.0722], [dr, db] = K(dm), [er, eb] = K(em);
  const cl = v => v < 0 ? 0 : v > 255 ? 255 : Math.round(v);
  for (let k = 0; k < n; k++) { const r = k * ROWSTEP; for (let x = 0; x < w; x++) {
    const Y0 = buf[l[0].offset + r * l[0].stride + x], U0 = buf[l[1].offset + (r >> 1) * l[1].stride + (x >> 1)] - 128,
      V0 = buf[l[2].offset + (r >> 1) * l[2].stride + (x >> 1)] - 128;
    const Yf = df ? Y0 : (Y0 - 16) * 255 / 219, U = df ? U0 : U0 * 255 / 224, V = df ? V0 : V0 * 255 / 224;
    const Rf = Yf + 2 * (1 - dr) * V, Bf = Yf + 2 * (1 - db) * U, R = cl(Rf), B = cl(Bf), G = cl((Yf - dr * Rf - db * Bf) / (1 - dr - db));
    const L = er * R + (1 - er - eb) * G + eb * B; y[k * w + x] = cl(ef ? L : 16 + L * 219 / 255); } }
  return y; };
// how two sampled planes differ: share of pixels, signed / abs mean, max
window.yDiff = (a, b) => { let ne = 0, sg = 0, ab = 0, mx = 0;
  for (let i = 0; i < a.length; i++) { const d = a[i] - b[i]; if (d) { ne++; ab += Math.abs(d); sg += d; mx = Math.max(mx, Math.abs(d)); } }
  return {differ: +(ne / a.length).toFixed(4), signed: +(sg / a.length).toFixed(3), abs: +(ab / a.length).toFixed(3), max: mx}; };
// [mean signed difference a - b, mean absolute difference]
window.cmp = (a, b) => { let s = 0, d = 0; for (let k = 0; k < a.length; k++) { const x = a[k] - b[k]; s += x; d += Math.abs(x); }
  return [s / a.length, d / a.length]; };
window.vsRef = (pairs) => { if (!pairs.length) return null; let s = 0, m = 0, mx = 0;
  for (const [y, r] of pairs) { const [a, b] = cmp(y, r); s += a; m += b; mx = Math.max(mx, b); }
  return {frames: pairs.length, signed: +(s / pairs.length).toFixed(2), mad: +(m / pairs.length).toFixed(2), max: +mx.toFixed(2)}; };
// which software thumbnail (its own and the 2 on each side) each hardware thumbnail is closest to. A wrong picture in
// place of the right one (a hidden frame, a neighbour, a stale surface) lands nearer another frame than its own; the
// hardware drawImage path's own difference (~3.8: its BT.601 matrix, see rgbRT) is the same for all of them, ties
// (frames alike) pass. H, S: luma arrays, output order
window.nearest = (H, S) => { let cnt = 0, nw = 0; const at = [];
  for (let i = 0; i < H.length && i < S.length; i++) { const own = cmp(H[i], S[i])[1]; let best = Infinity;
    for (let j = Math.max(0, i - 2); j <= Math.min(S.length - 1, i + 2); j++) if (j !== i) best = Math.min(best, cmp(H[i], S[j])[1]);
    cnt++; if (best + 0.5 < own) { nw++; if (at.length < 12) at.push(i + 1); } }
  return {compared: cnt, wrong: nw, at}; };
// hidden frames (show_frame = 0) in VP9 packets: superframe index, then each frame's uncompressed header
window.vp9Hidden = pkts => { let n = 0;
  for (const p of pkts) { const fr = [], m = p[p.length - 1];
    if ((m & 0xe0) === 0xc0) { const nf = (m & 7) + 1, mag = ((m >> 3) & 3) + 1, isz = 2 + mag * nf;
      if (p.length >= isz && p[p.length - isz] === m) { let o = p.length - isz + 1, off = 0;
        for (let k = 0; k < nf; k++) { let sz = 0; for (let b = 0; b < mag; b++) sz |= p[o++] << (8 * b); fr.push(p.subarray(off, off + sz)); off += sz; } } }
    if (!fr.length) fr.push(p);
    for (const f of fr) { if (!f.length) continue; let bit = 0; const rd = () => (f[bit >> 3] >> (7 - (bit++ & 7))) & 1;
      rd(); rd(); const prof = rd() | (rd() << 1); if (prof === 3) rd();
      if (rd()) continue;   // show_existing_frame
      rd(); if (!rd()) n++; } }   // frame_type, show_frame
  return n; };
"""

JS_WC = r"""
window.runWC = async (url, codec, refUrl) => {
  const buf = new Uint8Array(await (await fetch(url)).arrayBuffer()), dv = new DataView(buf.buffer);
  if (String.fromCharCode(...buf.subarray(0, 4)) !== 'DKIF') return {error: 'not IVF'};
  const hl = dv.getUint16(6, true), w = dv.getUint16(12, true), h = dv.getUint16(14, true), pkts = [];
  for (let p = hl; p + 12 <= buf.length;) { const sz = dv.getUint32(p, true); p += 12; pkts.push(buf.slice(p, p + sz)); p += sz; }
  const TW = 192, TH = 108;
  const pass = async hw => {
    const cfg = {codec, codedWidth: w, codedHeight: h, hardwareAcceleration: hw};
    let sup; try { sup = await VideoDecoder.isConfigSupported(cfg); } catch (e) { return {supported: false, err: String(e)}; }
    if (!sup.supported) return {supported: false};
    const cv = new OffscreenCanvas(TW, TH), cx = cv.getContext('2d', {willReadFrequently: true});
    const out = [], pend = []; let err = null, fmt, cs, geo;
    const dec = new VideoDecoder({output: f => { if (fmt === undefined) { fmt = f.format; try { cs = f.colorSpace.toJSON(); } catch (e) {} }
      cx.drawImage(f, 0, 0, TW, TH);
      const rec = {ts: f.timestamp, y: lumaOf(cx, TW, TH), yh: null}; out.push(rec);
      // 8-bit: the decoded Y plane itself (copyTo; a hardware frame is read back through Chrome's RGB path, see
      // rgbRT): its hash and every 8th row; a software (I420) frame also through the readback model. A 10-bit
      // hardware frame is opaque to copyTo.
      if (f.format === 'NV12' || f.format === 'I420') {
        const vr = f.visibleRect, buf = new Uint8Array(f.allocationSize());
        pend.push(f.copyTo(buf).then(l => { rec.yh = yHash(buf, l[0], vr.width, vr.height); rec.rows = yRows(buf, l[0], vr.width, vr.height);
            if (f.format === 'I420') rec.mrows = {601: rgbRT(buf, l, vr.width, vr.height, 601, 0, 709, 0),
                                                  709: rgbRT(buf, l, vr.width, vr.height, 709, 0, 709, 0)};
            if (!geo) geo = {coded: [f.codedWidth, f.codedHeight], visible: [vr.x, vr.y, vr.width, vr.height], layout: l}; })
          .catch(e => { rec.yh = 'copyTo ' + e.name; }).finally(() => f.close()));
      } else f.close(); }, error: e => { err = err || String(e); }});
    dec.configure(cfg);
    const t0 = performance.now();
    for (let i = 0; i < pkts.length && !err; i++) {
      dec.decode(new EncodedVideoChunk({type: i ? 'delta' : 'key', timestamp: i * 33333, data: pkts[i]}));
      while (dec.decodeQueueSize > 4 && !err) await new Promise(r => setTimeout(r, 2));
    }
    if (!err) { try { await dec.flush(); } catch (e) { err = err || String(e); } }
    await Promise.all(pend);
    const ms = Math.round(performance.now() - t0);
    try { dec.close(); } catch (e) {}
    return {supported: true, out, err, fmt: fmt === null ? 'opaque' : fmt, cs, ms, geo};
  };
  const sw = await pass('prefer-software');
  const hw = await pass('prefer-hardware');
  // every packet outputs one frame (a superframe's hidden frames output nothing), so output ordinal = packet number;
  // these are the 1-byte show_existing_frame packets the -sef clips insert
  const sefAt = pkts.map((p, i) => p.length === 1 ? i + 1 : 0).filter(Boolean);
  const r = {w, h, packets: pkts.length, sefAt, hidden: vp9Hidden(pkts), sw: {supported: sw.supported, n: sw.out ? sw.out.length : 0, err: sw.err || null,
    fmt: sw.fmt || null, cs: sw.cs || null, ms: sw.ms || 0}, hw: {supported: hw.supported, n: hw.out ? hw.out.length : 0,
    err: hw.err || null, fmt: hw.fmt || null, cs: hw.cs || null, ms: hw.ms || 0}};
  if (refUrl) {   // output frame i against FFmpeg's frame i (FFmpeg outputs the show_existing frames too: 97 for -sef)
    const ref = await loadRef(refUrl), pairs = o => (o || []).slice(0, ref.length).map((f, i) => [f.y, ref[i]]);
    r.ref = {frames: ref.length, hw: vsRef(pairs(hw.out)), sw: vsRef(pairs(sw.out))};
    // the same thumbnails from FFmpeg with the YUV -> RGB step done in BT.601: which matrix each path drew with
    const r6 = await loadRef(refUrl.replace('.ref.rgb', '.ref601.rgb')), p6 = o => (o || []).slice(0, r6.length).map((f, i) => [f.y, r6[i]]);
    r.ref601 = {hw: vsRef(p6(hw.out)), sw: vsRef(p6(sw.out))};
  }
  const grays = o => (o || []).map((f, i) => isGray(statOf(f.y)) ? i + 1 : 0).filter(Boolean);
  r.sw.gray = grays(sw.out); r.hw.gray = grays(hw.out);
  if (sw.out && hw.out) {
    const byTs = new Map(sw.out.map(f => [f.ts, f.y]));
    let max = 0, at = 0, over = [], unmatched = 0, sum = 0, ssum = 0, cnt = 0;
    hw.out.forEach((f, i) => { const s = byTs.get(f.ts); if (!s) { unmatched++; return; }
      const [sd, d] = cmp(f.y, s); sum += d; ssum += sd; cnt++;
      if (d > max) { max = d; at = i + 1; } if (d > 6 && over.length < 12) over.push([i + 1, +d.toFixed(1)]); });
    r.diff = {max: +max.toFixed(2), at, mean: cnt ? +(sum / cnt).toFixed(2) : null, signed: cnt ? +(ssum / cnt).toFixed(2) : null,
      over, unmatched};
    // the nearest-frame test, and how many frames it would flag if every hardware frame were one frame late (what it
    // can see in this clip)
    const H = hw.out.map(f => f.y), S = sw.out.map(f => f.y);
    r.near = nearest(H, S); r.near.shift1 = nearest(H.slice(1), S).wrong;
    // decoded Y planes, hardware vs software, frame by frame (8-bit only; null = not comparable): bit for bit, or else
    // every sampled pixel of the hardware readback within 1 of libvpx's frame put through a readback model (by: how
    // many frames each YUV -> RGB matrix explained)
    const swF = new Map(sw.out.map(f => [f.ts, f])), ex = {compared: 0, equal: 0, model: 0, modelMax: 0, by: {}, differ: [], errors: []};
    let first = null;
    hw.out.forEach((f, i) => { const s = swF.get(f.ts);
      if (!s) return;
      if (typeof f.yh === 'string' || typeof s.yh === 'string') { if (ex.errors.length < 4) ex.errors.push(String(typeof f.yh === 'string' ? f.yh : s.yh)); return; }
      if (f.yh === null || s.yh === null) return;
      ex.compared++;
      if (f.yh === s.yh) { ex.equal++; return; }
      const ms = s.mrows ? [601, 709].map(k => [k, yDiff(f.rows, s.mrows[k])]) : [], hit = ms.find(([, m]) => m.max <= 1);
      if (hit) { ex.model++; ex.by[hit[0]] = (ex.by[hit[0]] || 0) + 1; ex.modelMax = Math.max(ex.modelMax, hit[1].max); return; }
      if (ex.differ.length < 12) ex.differ.push(i + 1);
      if (!first) first = {frame: i + 1, direct: yDiff(f.rows, s.rows), model601: ms[0] ? ms[0][1] : null, model709: ms[1] ? ms[1][1] : null}; });
    if (first) { ex.first = first; ex.geo = {hw: hw.geo, sw: sw.geo}; }
    r.exact = ex;
  }
  return r;
};
"""

JS_VIDEO = r"""
window.playCapture = async (url, rate, want, refUrl) => {
  const ref = refUrl ? await loadRef(refUrl) : null, pairs = [], r6 = refUrl ? await loadRef(refUrl.replace('.ref.rgb', '.ref601.rgb')) : null, p6 = [];
  const v = document.createElement('video'); v.muted = true; v.playsInline = true; v.style.width = '960px';
  document.body.replaceChildren(v);
  const ready = new Promise((res, rej) => { v.oncanplay = res; v.onerror = () => rej(new Error('video error ' + (v.error && v.error.message))); });
  // a blob: URL, not the http one: python's http.server answers no Range requests, so Chrome would make the http
  // resource unseekable (currentTime = x leaves it at 0) and the paused seeks below would test nothing
  v.src = URL.createObjectURL(await (await fetch(url)).blob()); await ready; v.playbackRate = rate;
  const TW = 192, TH = 108, cv = new OffscreenCanvas(TW, TH), cx = cv.getContext('2d', {willReadFrequently: true});
  const fr = []; let last = null, missed = 0;
  const done = new Promise(res => { v.onended = res; setTimeout(res, 90000); });
  const cb = (now, md) => { cx.drawImage(v, 0, 0, TW, TH); const y = lumaOf(cx, TW, TH), st = statOf(y), i = Math.round(md.mediaTime * 30) + 1;
    if (last !== null && md.presentedFrames > last + 1) missed += md.presentedFrames - last - 1; last = md.presentedFrames;
    if (ref && ref[i - 1]) { pairs.push([y, ref[i - 1]]); p6.push([y, r6[i - 1]]); }
    fr.push({i, g: isGray(st)}); if (!v.ended) v.requestVideoFrameCallback(cb); };
  v.requestVideoFrameCallback(cb);
  await v.play(); await done;
  const q = v.getVideoPlaybackQuality(), seen = new Set(fr.map(f => f.i)), missing = [];
  for (let i = 1; i <= want; i++) if (!seen.has(i)) missing.push(i);
  return {callbacks: fr.length, distinct: seen.size, missing, missed, total: q.totalVideoFrames,
    dropped: q.droppedVideoFrames, ended: v.ended, gray: [...new Set(fr.filter(f => f.g).map(f => f.i))], ref: ref ? vsRef(pairs) : null,
    ref601: ref ? vsRef(p6) : null};
};
// show_existing_frame packets (1 byte) of an IVF clip, 1-based
window.sefOf = async url => { const buf = new Uint8Array(await (await fetch(url)).arrayBuffer()), dv = new DataView(buf.buffer), at = [];
  for (let p = dv.getUint16(6, true), i = 1; p + 12 <= buf.length; i++) { const sz = dv.getUint32(p, true); if (sz === 1) at.push(i); p += 12 + sz; }
  return at; };
// the closest frame of a reference (testsrc2 changes every frame): [mean abs difference, 1-based frame]
window.bestOf = (y, fr) => fr.reduce((b, f, i) => { const d = cmp(y, f)[1]; return d < b[0] ? [d, i + 1] : b; }, [Infinity, 0]);
window.REFS = {};
window.refsOf = async refUrl => REFS[refUrl] || (REFS[refUrl] = [await loadRef(refUrl), await loadRef(refUrl.replace('.ref.rgb', '.ref601.rgb'))]);
// which frame a 192x108 luma thumbnail shows, by content, with whichever FFmpeg reference (BT.709 or BT.601) fits it
// better; ok = frame k is within 0.5 of the closest frame (a show_existing frame repeats a hidden frame's picture, which
// a later frame resembles); bt709 / bt601 = its distance to frame k of each reference; gray = libva-v4l2's gray
window.whichFrame = async (y, refUrl, k) => { const [R7, R6] = await refsOf(refUrl), b7 = bestOf(y, R7), b6 = bestOf(y, R6);
  const [R, [d, f]] = b6[0] < b7[0] ? [R6, b6] : [R7, b7], own = R[k - 1] ? cmp(y, R[k - 1])[1] : Infinity;
  return {frame: f, own: +own.toFixed(2), best: +d.toFixed(2), ok: own <= d + 0.5, gray: isGray(statOf(y)),
    bt709: R7[k - 1] ? +cmp(y, R7[k - 1])[1].toFixed(2) : null, bt601: R6[k - 1] ? +cmp(y, R6[k - 1])[1].toFixed(2) : null}; };
// pause the <video>, seek to frame k (1-based, 30 fps; what a scrub does), say where the element is (for a compositor
// screenshot of it) and what a drawImage of it shows
window.showFrame = async (k, refUrl) => { const v = document.querySelector('video'); v.pause();
  const sk = new Promise(r => v.addEventListener('seeked', r, {once: true})); v.currentTime = (k - 1) / 30 + 0.005; await sk;
  await new Promise(r => setTimeout(r, 500));
  const cv = new OffscreenCanvas(192, 108), cx = cv.getContext('2d', {willReadFrequently: true}); cx.drawImage(v, 0, 0, 192, 108);
  const b = v.getBoundingClientRect();
  return {x: b.x, y: b.y, w: b.width, h: b.height, t: +v.currentTime.toFixed(3), drawn: await whichFrame(lumaOf(cx, 192, 108), refUrl, k)}; };
// the same for a PNG screenshot (base64) of the element
window.shotVs = async (png, refUrl, k) => { const bm = await createImageBitmap(await (await fetch('data:image/png;base64,' + png)).blob());
  const cv = new OffscreenCanvas(192, 108), cx = cv.getContext('2d', {willReadFrequently: true}); cx.drawImage(bm, 0, 0, 192, 108);
  return {...await whichFrame(lumaOf(cx, 192, 108), refUrl, k), size: [bm.width, bm.height]}; };
"""

JS_YT_HOOK = r"""
(() => { const v = document.querySelector('video'); if (!v) return 'no video';
  if (window.__y7) return 'hooked already';
  window.__y7 = {frames: 0, gray: 0, grayAt: [], err: null};
  const TW = 96, TH = 54, cv = new OffscreenCanvas(TW, TH), cx = cv.getContext('2d', {willReadFrequently: true});
  const cb = (now, md) => { try { cx.drawImage(v, 0, 0, TW, TH); const st = statOf(lumaOf(cx, TW, TH)); __y7.frames++;
      if (isGray(st)) { __y7.gray++; if (__y7.grayAt.length < 20) __y7.grayAt.push(+md.mediaTime.toFixed(3)); } }
    catch (e) { __y7.err = String(e); } v.requestVideoFrameCallback(cb); };
  v.requestVideoFrameCallback(cb); return 'hooked'; })()
"""

JS_YT_STATE = r"""
(() => { const v = document.querySelector('video'), p = document.querySelector('#movie_player'); if (!v) return {video: false};
  const q = v.getVideoPlaybackQuality(); let codec = '', res = '';
  try { const s = p.getStatsForNerds(); codec = s.codecs || ''; res = s.resolution || ''; } catch (e) {}
  return {video: true, t: +v.currentTime.toFixed(2), paused: v.paused, total: q.totalVideoFrames, dropped: q.droppedVideoFrames,
    size: v.videoWidth + 'x' + v.videoHeight, codec, res, ad: !!document.querySelector('.ad-showing'),
    hook: window.__y7 || null, title: document.title}; })()
"""


class CDP:
    def __init__(self, port):
        end = time.time() + 60
        while True:
            try:
                tabs = json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/json/list", timeout=3))
                page = next(t for t in tabs if t.get("type") == "page")
                break
            except Exception:
                if time.time() > end:
                    raise
                time.sleep(0.5)
        self.ws = websocket.create_connection(page["webSocketDebuggerUrl"], timeout=2, suppress_origin=True)
        self.n, self.events = 0, []

    def _recv(self):
        try:
            return json.loads(self.ws.recv())
        except websocket.WebSocketTimeoutException:
            return None

    def call(self, method, params=None, timeout=30):
        self.n += 1
        mid = self.n
        self.ws.send(json.dumps({"id": mid, "method": method, "params": params or {}}))
        end = time.time() + timeout
        while time.time() < end:
            m = self._recv()
            if m is None:
                continue
            if m.get("id") == mid:
                if "error" in m:
                    raise RuntimeError(f"{method}: {m['error']}")
                return m["result"]
            if "method" in m:
                self.events.append(m)
        raise TimeoutError(method)

    def eval(self, expr, timeout=60, gesture=False):
        r = self.call("Runtime.evaluate", {"expression": expr, "returnByValue": True, "awaitPromise": True,
                                           "userGesture": gesture}, timeout)
        if "exceptionDetails" in r:
            d = r["exceptionDetails"]
            raise RuntimeError("JS: " + str(d.get("exception", {}).get("description", d.get("text")))[:300])
        return r["result"].get("value")

    def pump(self, secs):
        end = time.time() + secs
        while time.time() < end:
            m = self._recv()
            if m and "method" in m:
                self.events.append(m)

    def navigate(self, url, timeout=40):
        k = len(self.events)
        self.call("Page.navigate", {"url": url})
        end = time.time() + timeout
        while time.time() < end:
            if any(e["method"] == "Page.loadEventFired" for e in self.events[k:]):
                return True
            self.pump(0.5)
        return False

    def players(self, since):
        """kVideoDecoderName / kIsPlatformVideoDecoder / kVideoCodecName per player, from events[since:]"""
        props = {}
        for e in self.events[since:]:
            if e["method"] == "Media.playerPropertiesChanged":
                d = props.setdefault(e["params"]["playerId"], {})
                for p in e["params"]["properties"]:
                    if p["name"] in ("kVideoDecoderName", "kIsPlatformVideoDecoder", "kVideoCodecName", "kResolution"):
                        d[p["name"]] = p["value"]
            elif e["method"] == "Media.playerErrorsRaised":
                props.setdefault(e["params"]["playerId"], {}).setdefault("errors", []).extend(
                    x.get("errorType", "?") + ":" + str(x.get("code", "")) for x in e["params"]["errors"])
        return {k: v for k, v in props.items() if v}


class Log:
    def __init__(self, path):
        self.path = path

    def mark(self):
        time.sleep(0.6)   # let the GPU process's last trace lines land
        return os.path.getsize(self.path)

    def counts(self, a, b):
        with open(self.path, "rb") as f:
            f.seek(a)
            text = f.read(b - a).decode("utf-8", "replace")
        c = {k: text.count(v) for k, v in TRACE.items()}
        # Chrome's own errors from its video stack (media/audio: ALSA "Host is down", the test KWin has no sound)
        errs = [l for l in text.splitlines() if "ERROR:" in l and "media/audio" not in l
                and ("vaapi" in l.lower() or "video" in l.lower() or "media/" in l)]
        c["chrome_errors"] = len(errs)
        return c, errs[:4]


results, fails = {}, 0


def check(name, ok, detail):
    global fails
    print(f"{'PASS' if ok else 'FAIL'}  {name}: {detail}", flush=True)
    if not ok:
        fails += 1


ERRTS = 1   # --errts: 1 = the kernel gives the NOSHOW error buffer the hidden frame's timestamp (iris 1051, y14 on)


def trace_ok(name, c, hidden=None):
    """hidden: the hidden frames the part decoded (the clip's count), None = unknown (YouTube). With 1051 every one
    of them comes back as a no-show CAPTURE buffer that 0001 matches; without it (y13) none does."""
    bad = [k for k in ("replaced", "nopic", "discarding", "timeout") if c[k]]
    noshow_want = c["invisible"] if ERRTS else 0
    ok = c["decoded"] > 0 and not bad and c["noshow"] == noshow_want and (hidden is None or c["invisible"] == hidden)
    check(name + " trace", ok, f"decoded {c['decoded']}, no-show {c['noshow']} (expected {noshow_want}) / invisible "
          f"{c['invisible']}" + (f" (the clip has {hidden} hidden frames)" if hidden is not None else "") +
          f", replaced {c['replaced']}, no-picture {c['nopic']}, discarding {c['discarding']}, sync timeout {c['timeout']}, "
          f"damaged {c['damaged']}, Chrome media errors {c['chrome_errors']}")
    if not c["invisible"]:
        print(f"SKIP  {name} hidden frames: no VP9 invisible reference decoded, the no-show path was not exercised", flush=True)


def platform_ok(name, pl):
    names = sorted({str(v.get("kVideoDecoderName")) for v in pl.values() if "kVideoDecoderName" in v})
    hw = any(str(v.get("kIsPlatformVideoDecoder")).lower() == "true" for v in pl.values())
    errs = sorted({e for v in pl.values() for e in v.get("errors", [])})
    check(name + " decoder", hw and not errs, f"{', '.join(names) or 'no decoder reported'}, platform {hw}"
          + (f", errors {errs}" if errs else ""))
    return names


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--http", type=int, required=True)
    ap.add_argument("--log", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--youtube")
    ap.add_argument("--errts", type=int, choices=(0, 1), default=1)
    ap.add_argument("--only", default="webcodecs,video,youtube", help="comma list of parts to run")
    a = ap.parse_args()
    parts = set(a.only.split(","))
    global ERRTS
    ERRTS = a.errts
    base = f"http://127.0.0.1:{a.http}"
    log = Log(a.log)
    cdp = CDP(a.port)
    for m in ("Page.enable", "Runtime.enable", "Media.enable"):
        cdp.call(m)
    if not cdp.navigate(base + "/index.html"):
        check("test page", False, "did not load")
        return
    gpu = cdp.eval("(()=>{const c=document.createElement('canvas').getContext('webgl');const e=c&&c.getExtension('WEBGL_debug_renderer_info');"
                   "return e?c.getParameter(e.UNMASKED_RENDERER_WEBGL):'no webgl'})()")
    print(f"      Chrome GL renderer: {gpu}", flush=True)
    results["renderer"] = gpu
    # informational: what this Chrome says it decodes (README "视频硬解": does it take HEVC Main10 since libva-v4l2
    # fbfcfab?); mediaCapabilities' powerEfficient = it has a hardware decoder for that config
    try:
        caps = cdp.eval(r"""(async () => { const out = {};
          for (const [n, c] of [['hevc main', 'hvc1.1.6.L120.90'], ['hevc main10', 'hvc1.2.4.L120.90'], ['vp9 p0', 'vp09.00.40.08'],
                                ['vp9 p2', 'vp09.02.40.10'], ['av1', 'av01.0.08M.08']]) {
            const t = `video/mp4; codecs="${c}"`; let d;
            try { d = await navigator.mediaCapabilities.decodingInfo({type: 'media-source',
                    video: {contentType: t, width: 1920, height: 1080, bitrate: 8e6, framerate: 30}}); } catch (e) { d = {error: String(e)}; }
            out[n] = `canPlayType '${document.createElement('video').canPlayType(t)}', MSE ${MediaSource.isTypeSupported(t)}, ` +
                     `supported ${d.supported}, powerEfficient ${d.powerEfficient}` + (d.error ? `, ${d.error}` : ''); }
          return out; })()""")
        results["decode_caps"] = caps
        print("INFO  decoding as this Chrome reports it (1080p30, mediaCapabilities; powerEfficient = a hardware decoder): "
              + "; ".join(f"{k}: {v}" for k, v in caps.items()), flush=True)
    except Exception as e:
        print(f"INFO  decoding capabilities not read: {type(e).__name__}: {e}"[:300], flush=True)

    # webcodecs
    for clip, codec, want in (("vp9-p0.ivf", "vp09.00.10.08", 90), ("vp9-p0-sef.ivf", "vp09.00.10.08", 97),
                              ("vp9-p2-10bit.ivf", "vp09.02.10.10", 90), ("vp9-p2-10bit-sef.ivf", "vp09.02.10.10", 97)
                              ) if "webcodecs" in parts else ():
        name = "webcodecs " + clip
        cdp.eval(JS_LIB + JS_WC + ";1")
        k, x = len(cdp.events), log.mark()
        ref = base + "/" + clip.replace(".ivf", ".ref.rgb")
        try:
            r = cdp.eval(f"runWC({json.dumps(base + '/' + clip)}, {json.dumps(codec)}, {json.dumps(ref)})", timeout=120)
        except Exception as e:
            check(name, False, f"{type(e).__name__}: {e}")
            continue
        c, errs = log.counts(x, log.mark())
        r["trace"], r["players"], r["chrome_errors"] = c, cdp.players(k), errs
        results[name] = r
        sw, hw, d = r["sw"], r["hw"], r.get("diff") or {}
        print(f"      {clip} {r['w']}x{r['h']}, {r['packets']} packets, show_existing at {r['sefAt'] or '-'}; "
              f"software {sw['n']} frames {sw['ms']} ms ({sw['fmt']}), hardware {hw['n']} frames {hw['ms']} ms ({hw['fmt']})", flush=True)
        print(f"      colour space software {json.dumps(sw['cs'])}, hardware {json.dumps(hw['cs'])}; hardware - software luma "
              f"{d.get('signed')}" + (f"; vs FFmpeg (frame - reference, signed / abs / max abs): software {r['ref']['sw']}, "
              f"hardware {r['ref']['hw']}" if r.get("ref") else ""), flush=True)
        if r.get("ref601"):   # informational: which YUV -> RGB matrix each drawImage path used (lower abs = that one)
            print(f"      drawImage matrix, abs vs FFmpeg BT.709 / BT.601: software {r['ref']['sw']['mad']} / {r['ref601']['sw']['mad']}, "
                  f"hardware {r['ref']['hw']['mad']} / {r['ref601']['hw']['mad']}", flush=True)
        check(name + " hardware", hw["supported"] and not hw["err"],
              "prefer-hardware " + ("supported" if hw["supported"] else "NOT supported") + (f", error {hw['err']}" if hw["err"] else ""))
        check(name + " frames", hw["n"] == sw["n"] == want and not d.get("unmatched"),
              f"hardware {hw['n']}, software {sw['n']}, expected {want}, unmatched timestamps {d.get('unmatched')}")
        check(name + " gray", not hw["gray"] and not sw["gray"], f"gray output frames hardware {hw['gray'] or 0}, software {sw['gray'] or 0}")
        nr = r.get("near") or {}
        check(name + " content", d.get("max", 99) <= 6 and nr.get("compared") == hw["n"] and not nr.get("wrong"),
              f"luma difference hardware vs software per frame: mean {d.get('mean')}, max {d.get('max')} (frame {d.get('at')}), "
              f"frames over 6: {d.get('over') or 0}; nearer to another software frame (+-2) than to its own: {nr.get('wrong')} of "
              f"{nr.get('compared')}" + (f" at {nr['at']}" if nr.get("at") else "") +
              f" (one frame late would be caught at {nr.get('shift1')} of {(nr.get('compared') or 1) - 1})")
        ex = r.get("exact") or {}
        if ex.get("compared") or ex.get("errors"):
            ok = ex.get("compared") == hw["n"] and ex.get("equal", 0) + ex.get("model", 0) == ex.get("compared") and not ex.get("errors")
            check(name + " exact", ok, f"decoded Y plane hardware vs software (libvpx), {ex.get('compared')} of {hw['n']} frames: "
                  f"{ex.get('equal')} bit for bit, {ex.get('model')} equal through Chrome's readback (YUV -> RGB -> BT.709, "
                  f"every 8th row, max {ex.get('modelMax')}; decoded with BT.601: {ex.get('by', {}).get('601', 0)}, "
                  f"BT.709: {ex.get('by', {}).get('709', 0)})" + (f", differ at {ex['differ']}" if ex.get("differ") else "")
                  + (f", errors {ex['errors']}" if ex.get("errors") else ""))
            if ex.get("first"):
                print(f"      first differing frame {json.dumps(ex['first'])}; geometry {json.dumps(ex.get('geo'))}", flush=True)
        else:
            print(f"      {clip}: decoded planes not compared (hardware frames are {hw['fmt']}: no copyTo)", flush=True)
        trace_ok(name, c, r["hidden"])

    # video
    for clip, want in (("vp9-p0.webm", 90), ("vp9-p0-sef.webm", 97), ("vp9-p2-10bit-sef.webm", 97)) if "video" in parts else ():
        name = "video " + clip
        wc = results.get("webcodecs " + clip.replace(".webm", ".ivf")) or {}   # the same bitstream as IVF
        sef = wc.get("sefAt")
        ref = base + "/" + clip.replace(".webm", ".ref.rgb")
        cdp.navigate(base + "/index.html")
        cdp.eval(JS_LIB + JS_VIDEO + ";1")
        if sef is None:   # no webcodecs part this run: read the show_existing packets from the IVF
            sef = cdp.eval(f"sefOf({json.dumps(base + '/' + clip.replace('.webm', '.ivf'))})") if "-sef" in clip else []
        k, x = len(cdp.events), log.mark()
        try:
            r = cdp.eval(f"playCapture({json.dumps(base + '/' + clip)}, 0.5, {want}, {json.dumps(ref)})", timeout=120, gesture=True)
        except Exception as e:
            check(name, False, f"{type(e).__name__}: {e}")
            continue
        cdp.pump(1)
        x2 = log.mark()
        c, errs = log.counts(x, x2)
        # paused seeks, what a scrub does: Chrome flushes the decoder and decodes from the keyframe to the frame sought;
        # in the -sef clips to each show_existing frame (the gray one when a hidden frame was grayed). The <video> as
        # drawImage gives it and as the compositor shows it (Page.captureScreenshot of the element), each by content
        seeks, shots = sef or [20, 45, 70], []
        for kf in seeks:
            try:
                at = cdp.eval(f"showFrame({kf}, {json.dumps(ref)})", timeout=20)
                png = cdp.call("Page.captureScreenshot", {"format": "png", "clip": {"x": at["x"], "y": at["y"],
                               "width": at["w"], "height": at["h"], "scale": 1}}, timeout=20)["data"]
                shots.append({"seek": kf, "t": at["t"], "drawn": at["drawn"],
                              "screen": cdp.eval(f"shotVs({json.dumps(png)}, {json.dumps(ref)}, {kf})")})
            except Exception as e:
                shots.append({"seek": kf, "error": f"{type(e).__name__}: {e}"[:200]})
        cdp.pump(1)
        c2, errs2 = log.counts(x2, log.mark())
        r["trace"], r["players"], r["chrome_errors"], r["seeks"], r["seek_trace"] = c, cdp.players(k), errs + errs2, shots, c2
        results[name] = r
        platform_ok(name, r["players"])
        # the last frame can end the clip before its callback: up to 2 frames may go unseen, never a show_existing one
        lost_sef = sorted(set(sef) & set(r["missing"]))
        check(name + " frames", r["ended"] and len(r["missing"]) <= 2 and not lost_sef,
              f"ended {r['ended']}, frames seen {r['distinct']} of {want} (not seen {r['missing'] or '-'}"
              f"{', show_existing ones among them ' + str(lost_sef) if lost_sef else ''}; callbacks {r['callbacks']}, "
              f"missed {r['missed']}), decoded {r['total']}, dropped {r['dropped']}"
              + (f"; vs FFmpeg (signed / abs / max abs) {r['ref']}" if r.get("ref") else ""))
        check(name + " gray", not r["gray"], f"gray frames {r['gray'] or 0}")
        trace_ok(name, c, wc.get("hidden"))

        def desc(w):
            return (f"frame {w['frame']}" + ("" if w["ok"] else f" (the one sought: {w['own']} away, the closest: {w['best']})")
                    + (", GRAY" if w["gray"] else ""))
        bad = [s for s in shots if "error" in s or abs(s["t"] - ((s["seek"] - 1) / 30 + 0.005)) > 0.002
               or not s["drawn"]["ok"] or s["drawn"]["gray"] or not s["screen"]["ok"] or s["screen"]["gray"]]
        check(name + " seek", shots and not bad,
              f"paused seeks to {'the show_existing frames ' if sef else 'frames '}{seeks}: drawImage and screen show the frame "
              f"sought, not gray, at {len(shots) - len(bad)} of {len(shots)}"
              + "".join(f"; seek {s['seek']}: " + (s["error"] if "error" in s else
                        f"currentTime {s['t']}, drawImage {desc(s['drawn'])}, screen {desc(s['screen'])}") for s in bad))
        trace_ok(name + " seek", c2)
        # informational: the matrix of the <video> drawImage path (the playback) and of the compositor (the seeks)
        scr = [s["screen"] for s in shots if "screen" in s and s["screen"].get("bt709") is not None]
        print(f"INFO  {name} matrix, abs vs FFmpeg BT.709 / BT.601: <video> drawImage {(r.get('ref') or {}).get('mad')} / "
              f"{(r.get('ref601') or {}).get('mad')}; on screen (the paused seeks) "
              + (f"{sum(w['bt709'] for w in scr) / len(scr):.2f} / {sum(w['bt601'] for w in scr) / len(scr):.2f}" if scr else "-"),
              flush=True)

    # youtube
    if a.youtube and "youtube" in parts:
        name = "youtube"
        cdp.navigate(base + "/index.html")
        k, x = len(cdp.events), log.mark()
        loaded = cdp.navigate(a.youtube, timeout=45)
        st = None
        for _ in range(40):
            try:
                st = cdp.eval("(()=>{const v=document.querySelector('video');return !!v&&v.readyState>=2})()")
            except Exception:
                st = False
            if st:
                break
            cdp.pump(1)
        if not st:
            title = cdp.eval("document.title")
            print(f"SKIP  youtube: no playing video after {'load' if loaded else 'no load event'} (page '{title}')", flush=True)
            results[name] = {"skip": f"no video, page {title}"}
        else:
            cdp.eval("(async()=>{const v=document.querySelector('video');v.muted=true;try{await v.play()}catch(e){};return 1})()", gesture=True)
            cdp.eval(JS_LIB + ";1")
            hook = cdp.eval(JS_YT_HOOK)
            at_hook = cdp.eval(JS_YT_STATE)
            samples = []
            cdp.pump(25)
            samples.append(cdp.eval(JS_YT_STATE))
            for t in (95, 200, 40):
                cdp.eval(f"(()=>{{const v=document.querySelector('video');v.currentTime={t};v.play();return 1}})()", gesture=True)
                cdp.pump(8)
                samples.append(cdp.eval(JS_YT_STATE))
            # stop decoding before the part's log window closes (what a playing video decodes after it would be in no
            # part; chrome-vp9-check.sh also sweeps the whole log)
            cdp.eval("(()=>{const v=document.querySelector('video');if(v)v.pause();return 1})()")
            cdp.pump(1.5)
            c, errs = log.counts(x, log.mark())
            pl = cdp.players(k)
            results[name] = {"samples": samples, "at_hook": at_hook, "trace": c, "players": pl, "hook": hook, "chrome_errors": errs}
            for s in samples:
                print(f"      t {s.get('t')} s, {s.get('size')} {s.get('codec')} {s.get('res')}, frames {s.get('total')} "
                      f"dropped {s.get('dropped')}, paused {s.get('paused')}, ad {s.get('ad')}", flush=True)
            last = samples[-1]
            codec = " ".join(str(s.get("codec")) for s in samples)
            if "vp09" not in codec:
                print(f"SKIP  youtube: served {codec or 'unknown codec'}, not VP9 (page '{last.get('title')}')", flush=True)
            else:
                platform_ok(name, pl)
                hk = last.get("hook") or {}
                check(name + " playback", (last.get("total") or 0) > samples[0].get("total", 0) > 0,
                      f"frames {samples[0].get('total')} -> {last.get('total')}, dropped {last.get('dropped')}")
                # the gray verdict only counts when the hook really looked at the frames shown since it was set
                shown = (last.get("total") or 0) - (at_hook.get("total") or 0)
                drawn = hk.get("frames") or 0
                covered = hook == "hooked" and not hk.get("err") and drawn > 0 and drawn * 2 >= shown
                check(name + " gray", covered and not hk.get("gray"),
                      f"gray frames {hk.get('gray')} at {hk.get('grayAt') or '-'}; the hook drew {drawn} of {shown} frames "
                      f"decoded since it was set ({hook}{', error ' + hk['err'] if hk.get('err') else ''}; needs half)")
                trace_ok(name, c)

    results["fails"] = fails


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        check("driver", False, f"{type(e).__name__}: {e}")
        results["fails"] = fails
    with open(sys.argv[sys.argv.index("--out") + 1], "w") as f:
        json.dump(results, f, indent=1, default=str)
    print(f"{fails} failed", flush=True)
    sys.exit(1 if fails else 0)
