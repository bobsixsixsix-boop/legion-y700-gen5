// Y700 video state, page world, before any page script: what pages are told about AV1.
// v1.5 (2026-10-18): every AV1 codec string was answered "no", so pages picked VP9 / H.264 / HEVC, which the tablet's
// VA-API driver (Iris V4L2) plays in hardware. That driver had no AV1 profile: YouTube's av01 1080p60 (what it sends a
// fresh profile) ran in software at 1.7 CPU cores, VP9 1080p60 in hardware at 0.5 (linux/video/chrome-video-power-ab.sh;
// whole-device power not shown to drop, README "视频播放功耗").
// v1.6 (2026-10-28): qcom-va-driver 1.1.1 (35eff37, formerly libva-v4l2) decodes AV1 Main, vainfo lists
// VAProfileAV1Profile0. 8-bit AV1 Main is let through, and only where Chrome itself reports a hardware decoder for it
// (MediaCapabilities powerEfficient): a driver rolled back to one without AV1 gets v1.5's answers, not software AV1.
// Still hidden: 10-bit (10-28 on y14 the firmware failed 1080p10 / tiles10 / still10 of av1.py with session errors,
// FFmpeg exit 251, while 4k10 passed; 10-29 on y15 the kernel's LINE-buffer fix 1057 made them decode, av1-10bit-probe
// 5/5 and av1.py 1080p10 bit-exact, but YouTube sends 10-bit AV1 only for HDR, which this tablet does not do, so not
// opened up for that alone), profiles 1 and 2, monochrome and any chroma subsampling but
// 4:2:0 (the driver's av1_bitstream() refuses them: VA_STATUS_ERROR_UNSUPPORTED_RT_FORMAT), and a bare or truncated
// "av01" that states no bit depth (refusing it costs at most v1.5's answer; allowing it could hand the firmware 10-bit).
// Hidden AV1 reference frames need the kernel's NOSHOW recycling (radxa 0005 = our 1052, y15): on y14 they come out
// gray, so v1.6 belongs on y15 and later (linux/video/libva-v4l2-update.sh, chrome-vp9-check.sh CODEC=vp9,av1).
// AV1_MAIN_8BIT = false below hides every AV1 codec string again (v1.5); dropping this file from manifest.json lets all
// of AV1 through, 10-bit included.
// Codec string (AV1 ISO-BMFF binding, "Codecs Parameter String"): av01.P.LLT.DD[.M.CCC.cp.tc.mc.F] - P profile (0 =
// Main), LL level, T tier (M / H), DD bit depth, M monochrome, CCC chroma subsampling (4:2:0 = 11x). Not in it: film
// grain synthesis, which the driver does not do (VA_STATUS_ERROR_UNIMPLEMENTED), nor a picture under 128 px a side,
// which it refuses - such a stream still reaches the hardware decoder and fails there (or Chrome falls back to its
// software decoder; not observed yet).
// Hooks as before (the h264ify way): MediaSource.isTypeSupported, HTMLMediaElement.canPlayType and
// MediaCapabilities.decodingInfo; a type without "av01" is passed through untouched. The first two answer
// synchronously, so they let 8-bit AV1 Main through only once the hardware probe below (one decodingInfo call at
// document_start, 1080p30 av01.0.08M.08) came back powerEfficient: a page that asks before it resolves gets "no" (v1.5's
// answer) for that load. decodingInfo asks Chrome every time and turns an answer that is not powerEfficient into "no".
(() => {
  const AV1_MAIN_8BIT = true;   // false: hide every AV1 codec string, as v1.5 did
  const AV1 = /av01/i, IDS = /av01[^\s,;"']*/gi;
  // av01.P.LLT.DD[.M.CCC...]: Main profile, a level with its tier, 8 bits; if given, not monochrome and 4:2:0
  const main8 = (id) => {
    const f = id.split(".");
    return f.length >= 4 && f[1] === "0" && /^\d\d[MH]$/i.test(f[2]) && f[3] === "08" &&
      (f.length < 5 || f[4] === "0") && (f.length < 6 || /^11[0-3]$/.test(f[5]));
  };
  // "pass" (no AV1 in the type), "main8" (every AV1 id in it is 8-bit AV1 Main) or "hide"
  const kind = (type) => {
    const s = String(type);
    if (!AV1.test(s)) return "pass";
    const ids = s.match(IDS) || [];
    return AV1_MAIN_8BIT && ids.length && ids.every(main8) ? "main8" : "hide";
  };
  let hw = false;   // the probe: Chrome has a hardware (powerEfficient) decoder for 8-bit AV1 Main
  const allow = (type) => { const k = kind(type); return k === "pass" || (k === "main8" && hw); };
  const no = () => ({supported: false, smooth: false, powerEfficient: false});
  if (window.MediaCapabilities && MediaCapabilities.prototype.decodingInfo) {
    const decodingInfo = MediaCapabilities.prototype.decodingInfo;
    if (AV1_MAIN_8BIT && navigator.mediaCapabilities) {
      try {
        decodingInfo.call(navigator.mediaCapabilities, {type: "media-source", video: {
          contentType: 'video/mp4; codecs="av01.0.08M.08"', width: 1920, height: 1080, bitrate: 8e6, framerate: 30}})
          .then((r) => { hw = !!(r && r.supported && r.powerEfficient); }, () => {});
      } catch (e) {}
    }
    MediaCapabilities.prototype.decodingInfo = function (cfg) {
      const k = kind((cfg && cfg.video && cfg.video.contentType) || "");
      if (k === "hide") return Promise.resolve(no());
      const answer = decodingInfo.call(this, cfg);
      return k === "pass" ? answer : answer.then((r) => (r && r.supported && r.powerEfficient ? r : no()));
    };
  }
  if (window.MediaSource && MediaSource.isTypeSupported) {
    const isTypeSupported = MediaSource.isTypeSupported.bind(MediaSource);
    MediaSource.isTypeSupported = (type) => (allow(type) ? isTypeSupported(type) : false);
  }
  if (window.HTMLMediaElement) {
    const canPlayType = HTMLMediaElement.prototype.canPlayType;
    HTMLMediaElement.prototype.canPlayType = function (type) { return allow(type) ? canPlayType.call(this, type) : ""; };
  }
})();
