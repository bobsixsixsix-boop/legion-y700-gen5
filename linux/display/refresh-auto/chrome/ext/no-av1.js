// Y700 video state (2026-10-18), page world, before any page script: pages are told that this Chrome cannot play AV1,
// so they pick VP9 / H.264 / HEVC, which the tablet's VA-API decoder (Iris V4L2) plays in hardware. It has no AV1
// profile, so YouTube's av01 1080p60 (what it sends a fresh profile) ran in software at 1.7 CPU cores; with this file
// it sends VP9 1080p60 instead, decoded in hardware at 0.5 cores (linux/video/chrome-video-power-ab.sh). Whole-device
// power is not shown to drop yet (one 60 s window, 4.12 W vs 3.7-3.9 W for AV1; README "视频播放功耗" has the
// follow-up A/B). Kept for the CPU it frees, at the same resolution. The same way h264ify does it:
// MediaSource.isTypeSupported, canPlayType and MediaCapabilities.decodingInfo answer "no" for av01 codec strings;
// everything else is passed through untouched.
// If a later VA-API backend gets an AV1 profile (vainfo lists VAProfileAV1Profile0), drop this file from manifest.json.
(() => {
  const AV1 = /av01/i;
  if (window.MediaSource && MediaSource.isTypeSupported) {
    const isTypeSupported = MediaSource.isTypeSupported.bind(MediaSource);
    MediaSource.isTypeSupported = (type) => (AV1.test(String(type)) ? false : isTypeSupported(type));
  }
  if (window.HTMLMediaElement) {
    const canPlayType = HTMLMediaElement.prototype.canPlayType;
    HTMLMediaElement.prototype.canPlayType = function (type) { return AV1.test(String(type)) ? "" : canPlayType.call(this, type); };
  }
  if (window.MediaCapabilities && MediaCapabilities.prototype.decodingInfo) {
    const decodingInfo = MediaCapabilities.prototype.decodingInfo;
    MediaCapabilities.prototype.decodingInfo = function (cfg) {
      const type = (cfg && cfg.video && cfg.video.contentType) || "";
      if (AV1.test(type)) return Promise.resolve({supported: false, smooth: false, powerEfficient: false});
      return decodingInfo.call(this, cfg);
    };
  }
})();
