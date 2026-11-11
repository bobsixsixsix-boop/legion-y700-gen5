// y700-split entry. KWin caches a script's QML by URL for the life of the process, so a file edited in
// place keeps running the old code until a re-login. install.sh puts each install's code in a fresh
// contents/build-<BuildId>/ and writes the id to kwinrc: a new URL, loaded after unload + reconfigure.
// This file itself never changes. No BuildId (a checkout copied as is, as ts-bed does): ui/Split.qml here.
// (The same as linux/stage/y700-stage/contents/ui/main.qml.)
import QtQuick

Loader {
    readonly property string build: /^[0-9]+$/.test(String(KWin.readConfig("BuildId", "") || ""))
        ? String(KWin.readConfig("BuildId", "")) : ""
    source: build ? "../build-" + build + "/ui/Split.qml" : "Split.qml"
}
