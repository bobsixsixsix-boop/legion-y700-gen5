// Place in the *real* profile directory (find it, do not guess the name):
//   find ~/.mozilla/firefox -maxdepth 1 -type d -name '*.default*'
// user.js is read at every startup and Firefox never rewrites it (unlike prefs.js).
//
// Hardware decoding works through V4L2 M2M, not VA-API, so it needs no backend.
user_pref("media.hardware-video-decoding.enabled", true);
user_pref("media.hardware-video-decoding.force-enabled", true);
// Chinese UI, if the firefox-esr-l10n-zh-cn package is installed
user_pref("intl.locale.requested", "zh-CN");
user_pref("intl.accept_languages", "zh-CN,zh,en-US,en");
