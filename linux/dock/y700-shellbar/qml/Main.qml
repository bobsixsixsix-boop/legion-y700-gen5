// y700-shellbar's state: which windows are open (Plasma's task manager model), whether we are on the desktop,
// the dock's recent apps, and the four layer-shell windows (src/main.cpp gives them their roles, then sets ready).
//   statusWin  status bar, top, 28 px
//   stripWin   8 px pull strip over it, overlay layer (pulls over fullscreen apps)
//   dockWin    the dock: on the desktop always, in an app only after reveal() (mode B+)
//   gridWin    all apps, full screen, from the dock's first button
//   bannerWin  notification banners at the top - and the notification server itself (Banners.qml)
//   backWin    the stage manager's blurred backdrop, Bottom layer, while the KWin script says so (Backdrop.qml)
import QtQuick
import QtQuick.Window
import org.kde.taskmanager as TaskManager

QtObject {
    id: root
    property bool ready: false

    // ---------------- windows
    property var winRows: []           // [{row, id, active, minimized}] app windows, last activated first; id "" = unknown app
    property bool onDesktop: true      // no app window is showing
    property string activeId: ""
    property bool fullscreenActive: false   // the active window is fullscreen (KWin raises it over the Top layer)
    property var recents: []           // desktop ids, last used first (in memory only; 8 kept so unpinning leaves 3)
    property bool seeded: false
    readonly property var recentShown: {
        const out = [];
        for (const id of recents) if (apps.pinned.indexOf(id) < 0 && out.length < 3) out.push(id);
        return out;
    }
    readonly property var running: {
        const s = {};
        for (const w of winRows) if (w.id) s[w.id] = true;
        return s;
    }

    // B+: in an app the dock is away; a short slow swipe from the bottom edge (y700-taskswitcher -> reveal())
    // brings it up for a few seconds
    property bool revealed: false
    property bool gridOpen: false
    // The swipe that reveals also opened the cards for a moment: the switcher minimized everything and gives the
    // app back as the call arrives, so onDesktop / activeId flip around it (bed, 2026-10-22: one reveal in two was
    // lost). Those flips within revealGrace ms of a reveal do not put the dock away; later ones (home, another app) do.
    readonly property int revealGrace: 1200
    property real revealAt: 0
    function settled() { return Date.now() - revealAt > revealGrace }
    onOnDesktopChanged: {
        if (revealed) shell.log("onDesktop " + onDesktop + (settled() ? ": dock away" : ": kept (just revealed)"));
        if (settled()) revealed = false;
    }
    onActiveIdChanged: {
        if (revealed) shell.log("active " + activeId + (settled() ? ": dock away" : ": kept (just revealed)"));
        if (settled()) revealed = false;
        if (activeId) touchRecent(activeId);
    }
    property Timer revealTimer: Timer { interval: 4000; onTriggered: root.revealed = false }
    // the stage manager's flights (linux/stage, a card tapped or dropped): it puts the staged windows down as the
    // copies start and brings the next ones up as they land, 0.5 s on; holdDock(ms) says so, and for that long no
    // window up keeps onDesktop as it was (11-09: the dock slid in and out on every swap)
    property real heldUntil: 0
    property Timer heldTimer: Timer { onTriggered: root.recompute() }
    property Connections shellConn: Connections {
        target: shell
        function onRevealRequested() {
            if (root.gridOpen) return;
            shell.log("reveal" + (root.onDesktop ? " (on the desktop for now)" : ""));
            root.revealAt = Date.now();
            root.revealed = true;
            root.revealTimer.restart();
        }
        function onHideRequested() { shell.log("hideDock"); root.revealed = false }
        function onDockHeld(ms) {
            root.heldUntil = Date.now() + ms;
            root.heldTimer.interval = Math.max(1, ms);
            root.heldTimer.restart();
        }
    }
    function keepRevealed() { if (revealed) revealTimer.restart() }

    property TaskManager.TasksModel tasks: TaskManager.TasksModel {
        sortMode: TaskManager.TasksModel.SortLastActivated
        groupMode: TaskManager.TasksModel.GroupDisabled
    }
    // one object per row, only to read its roles from script; any change recomputes once per event loop turn
    property Instantiator rows: Instantiator {
        model: root.tasks
        delegate: QtObject {
            required property var model
            required property int index
            readonly property string appId: model.AppId || ""
            readonly property bool isWindow: model.IsWindow === true
            readonly property bool minimized: model.IsMinimized === true
            readonly property bool active: model.IsActive === true
            readonly property bool skip: model.SkipTaskbar === true
            readonly property bool fullscreen: model.IsFullScreen === true
            onIndexChanged: Qt.callLater(root.recompute)
            onAppIdChanged: Qt.callLater(root.recompute)
            onIsWindowChanged: Qt.callLater(root.recompute)
            onMinimizedChanged: Qt.callLater(root.recompute)
            onActiveChanged: Qt.callLater(root.recompute)
            onSkipChanged: Qt.callLater(root.recompute)
            onFullscreenChanged: Qt.callLater(root.recompute)
        }
        onObjectAdded: Qt.callLater(root.recompute)
        onObjectRemoved: Qt.callLater(root.recompute)
    }
    property Connections appsConn: Connections {
        target: apps
        function onChanged() { Qt.callLater(root.recompute) }
    }

    // a window's AppId is its desktop file id ("org.kde.dolphin", sometimes "applications:x.desktop") or,
    // for apps without one, the Wayland app_id; apps.byKey knows both the ids and StartupWMClass
    function desktopId(appId) {
        const k = appId.replace(/^applications:/, "").replace(/\.desktop$/, "").toLowerCase();
        return apps.byKey[k] || "";
    }

    function recompute() {
        const list = [];
        let shown = 0, active = "", fs = false;
        for (let i = 0; i < rows.count; i++) {
            const o = rows.objectAt(i);
            if (!o || !o.isWindow || o.skip) continue;
            const id = desktopId(o.appId);
            list.push({ row: i, id: id, active: o.active, minimized: o.minimized });
            if (!o.minimized) shown++;
            if (o.active && !o.minimized) active = id;
            if (o.active && !o.minimized && o.fullscreen) fs = true;
        }
        winRows = list;
        if (shown > 0 || Date.now() >= heldUntil) onDesktop = shown === 0;
        fullscreenActive = fs;
        if (!seeded && list.length) {
            seeded = true;
            for (let j = list.length - 1; j >= 0; j--) if (list[j].id) touchRecent(list[j].id);
        }
        activeId = active;
    }

    function touchRecent(id) {
        if (recents[0] === id) return;
        recents = [id].concat(recents.filter(x => x !== id)).slice(0, 8);
    }

    // a dock or grid tap: bring its newest window forward, or start it
    function open(id, fromWin) {
        const w = winRows.find(r => r.id === id);
        if (w) {
            if (!w.active || w.minimized) tasks.requestActivate(tasks.makeModelIndex(w.row));
        } else {
            apps.launch(id, fromWin);
        }
        revealed = false;
        gridOpen = false;
    }

    // ---------------- windows
    property Window statusWin: StatusBar { shellRoot: root }
    // The performance line over a fullscreen app (a game): KWin raises the active fullscreen window above the Top
    // layer, where the bar lives, so while the HUD is on the bar moves to the Overlay layer (where the overlay bar
    // used to sit) and back when the HUD goes off or the app leaves fullscreen. HUD off: fullscreen stays fullscreen.
    readonly property bool barOverlay: hud.on && fullscreenActive
    onBarOverlayChanged: { shell.log("status bar: " + (barOverlay ? "overlay layer" : "top layer")); shell.setOverlay(statusWin, barOverlay) }
    property Window stripWin: Window {
        visible: root.ready && !shell.ccOpen
        width: Screen.width
        height: 8                       // KWin's own touch edge is 8 logical px too
        color: "transparent"
        flags: Qt.FramelessWindowHint
        title: "y700-pull"
    }
    property Window dockWin: Dock { shellRoot: root }
    // the performance numbers on the desktop (in an app they are the status bar's HudLine)
    property Window hudWin: HudWidget { shellRoot: root }
    property Window gridWin: AppGrid { shellRoot: root }
    property Window bannerWin: Banners { shellRoot: root }
    property Window backWin: Backdrop { shellRoot: root }
}
