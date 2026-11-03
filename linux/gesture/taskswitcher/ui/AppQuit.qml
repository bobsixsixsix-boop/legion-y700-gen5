// y700: swiping a card away quits the app, not only its window (owner 10-21: 「把卡片继续往上划走就关掉那个程序」;
// 10-31: Steam and Claude only went to the tray). Lives in main.qml's root (y700-taskswitcher.patch): the view is
// destroyed when the cards close, and the window often goes after that. The view calls watch() right before
// closeWindow. A watched window that KWin removes within 5 s is due, also when its card came back meanwhile (a tray
// app slow to hide, a "save?" answered: the swipe asked for the quit); 3 s later (time to quit on its own) systemd
// starts y700-appquit@PID_WINPID_....service: PID owned the window, the WINPIDs own every window still there, and
// appquit.py decides (gone, still has a window, kept, Steam ...).
// Only strings go to systemd: DBusCall sends a JS number as int32 ('i') and GetUnitByPID wants uint32 ('u').
import QtQuick
import org.kde.kwin 3.0 as KWinComponents

QtObject {
    id: quit
    property var watched: []    // [{w, pid, until}]
    property var due: []        // pids

    function watch(w): void {
        if (!w || w.deleted || w.pid <= 0) return;
        const now = Date.now();
        watched = watched.filter(e => e.w && e.w !== w && e.until > now).concat([{ w: w, pid: w.pid, until: now + 5000 }]);
    }
    function fire(): void {
        const pids = [], ws = KWinComponents.Workspace.windows;
        for (let i = 0; i < ws.length; i++) {
            if (ws[i].pid > 0 && pids.indexOf(ws[i].pid) < 0) pids.push(ws[i].pid);
        }
        for (const pid of due) {
            // the same process shows a window again (tapped in the dock meanwhile): only this sees it, its pid is not
            // among the WINPIDs appquit.py gets
            if (pids.indexOf(pid) >= 0) {
                console.info("y700-taskswitcher: app quit: " + pid + " has a window again");
                continue;
            }
            const unit = "y700-appquit@" + [pid].concat(pids).join("_") + ".service";
            if (unit.length > 255) {   // systemd's limit on unit names; that many windows: leave it
                console.info("y700-taskswitcher: app quit: " + pid + " skipped, too many windows");
            } else {
                start.arguments = [unit, "replace"];
                start.call();
                console.info("y700-taskswitcher: app quit: start " + unit);
            }
        }
        due = [];
    }

    property Connections removed: Connections {
        target: KWinComponents.Workspace
        function onWindowRemoved(w) {
            const e = quit.watched.find(x => x.w === w);
            if (!e) return;
            quit.watched = quit.watched.filter(x => x !== e);
            if (Date.now() > e.until) return;
            quit.due = quit.due.concat([e.pid]);
            quit.grace.restart();
        }
    }
    property Timer grace: Timer {
        interval: 3000
        onTriggered: quit.fire()
    }
    // call() builds the message from the properties at that moment, so one object serves calls in a row
    property KWinComponents.DBusCall start: KWinComponents.DBusCall {
        service: "org.freedesktop.systemd1"; path: "/org/freedesktop/systemd1"
        dbusInterface: "org.freedesktop.systemd1.Manager"; method: "StartUnit"
        onFailed: console.info("y700-taskswitcher: app quit: StartUnit failed")
    }
}
