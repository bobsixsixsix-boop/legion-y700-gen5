// Test hook: `busctl --user call fyi.y700.Osk /Osk fyi.y700.Osk debug ss <cmd> <arg>` drives the
// keyboard through the same code a finger uses (KeyArea.begin/move/end), so the whole path
// keyboard -> fcitx5 -> app can be checked without touching the screen.
//   tap <key>            e.g. tap n, tap space, tap del, tap enter, tap lang
//   down <key> / up <key>  press and hold a key / lift it (hold shift while tapping letters)
//   move <key>:<dx>:<dy>   slide a held finger, design px from the key centre (del:0:-80 = up to the clear pill)
//   hold <key>:<ms>      long press (alternates, hold-to-talk, delete repeat, newline)
//   flick <key>          upward flick (types the corner hint)
//   seq <cmd arg;cmd arg;...>  several commands in ONE call, back to back (timing-sensitive sequences:
//                        double taps, two thumbs; separate bus calls are tens of ms apart)
//   pick <index>         tap candidate <index> in the band
//   panel <id>|close     open/close a panel
//   sym <index>          pick symbol <index> of the open symbol page (same code as the button)
//   symlock on|off
//   mode dock|split|float
//   clearall / undo      the clear gesture's action (Ctrl+A, BackSpace) / the toast's undo (Ctrl+Z)
//   raw <seq> / vk <sym:code:state:release>  key-helper sequence "37d,52d,52u,37u" / one VK backend key event
//   reset                lift every finger, shift off, panel closed, typed log cleared
//   state                -> JSON (shown, zh, preedit, candidates head, panel, mode, layout, talking, shift, typed, ...)
import QtQuick

Item {
    id: hook
    required property var kb
    readonly property var area: kb.keysArea
    property int nextId: 9000
    property var heldPts: ({})          // key name -> touch point, for down/up/move

    function pt(k, dx, dy) { return { pointId: hook.nextId, x: k.x + k.width / 2 + (dx || 0), y: k.y + k.height / 2 + (dy || 0) } }
    function keyOf(name) { return area.keyByName(name) }

    function run(cmd, arg) {
        var k
        switch (cmd) {
        case "tap":
            k = keyOf(arg); if (!k) { osk.setDebugState("no key " + arg); return }
            nextId++; area.begin(pt(k)); area.end(pt(k), false); break
        case "down":
            k = keyOf(arg); if (!k) { osk.setDebugState("no key " + arg); return }
            if (heldPts[arg]) { osk.setDebugState("already down " + arg); return }
            nextId++; heldPts[arg] = pt(k); area.begin(heldPts[arg]); break
        case "up":
            if (!heldPts[arg]) { osk.setDebugState("not down " + arg); return }
            area.end(heldPts[arg], false); delete heldPts[arg]; break
        case "move": {
            var mp = arg.split(":"), hp = heldPts[mp[0]]
            if (!hp) { osk.setDebugState("not down " + mp[0]); return }
            var k0 = keyOf(mp[0]); if (!k0) return
            var np = { pointId: hp.pointId, x: k0.x + k0.width / 2 + parseFloat(mp[1] || "0") * kb.u, y: k0.y + k0.height / 2 + parseFloat(mp[2] || "0") * kb.u }
            heldPts[mp[0]] = np; area.move(np); break
        }
        case "flick":
            k = keyOf(arg); if (!k) return
            // in steps like a finger (one 40 px update would read as a two-finger jump, KeyArea.move)
            nextId++; area.begin(pt(k))
            for (var fs = 1; fs <= 4; fs++) area.move(pt(k, 0, -10 * fs * kb.u))
            area.end(pt(k, 0, -40 * kb.u), false); break
        case "hold": {
            var parts = arg.split(":"); k = keyOf(parts[0]); if (!k) return
            nextId++; var p = pt(k); area.begin(p)
            holdTimer.point = p; holdTimer.interval = parseInt(parts[1] || "600"); holdTimer.start(); break
        }
        case "seq": {
            var cmds = arg.split(";")
            for (var i = 0; i < cmds.length; i++) {
                var c = cmds[i].trim(); if (c === "") continue
                var sp = c.indexOf(" ")
                run(sp < 0 ? c : c.slice(0, sp), sp < 0 ? "" : c.slice(sp + 1).trim())
            }
            break
        }
        case "pick": osk.selectCandidate(parseInt(arg)); break
        case "panel": if (arg === "close") kb.closePanel(); else kb.openPanel(arg); break
        case "sym": {
            var page = kb.panelsItem.symPage(), si = parseInt(arg)
            if (kb.panel !== "sym" || !page || isNaN(si) || si < 0 || si >= page.length) { osk.setDebugState("no symbol " + arg); return }
            kb.pickSymbol(page[si]); break
        }
        case "symlock": kb.setSymLock(arg === "on"); break
        case "mode": kb.setMode(arg); break
        case "lang": kb.setLang(arg); break
        case "clearall": kb.clearAll(); break
        case "undo": osk.keyCombo("z", ["Control"]); break
        case "raw": osk.rawHelper(arg); break
        case "vk": { var vp = arg.split(":"); osk.rawVk(parseInt(vp[0]), parseInt(vp[1]), parseInt(vp[2] || "0"), vp[3] === "1"); break }
        case "reset":
            area.abortAll(); heldPts = ({}); holdTimer.stop()
            if (kb.panel !== "") kb.closePanel()
            kb.shift = 0; kb.shiftHeld = 0; kb.shiftUsed = false; kb.shiftWasOnce = false; kb.shiftTapT = 0
            kb.typedLog = ""; break
        case "state":
            osk.setDebugState(JSON.stringify({ shown: osk.shown, zh: kb.zh, lang: kb.lang, preedit: osk.preedit, candidates: osk.candidates.slice(0, 8),
                                               ncand: osk.candidates.length, panel: kb.panel, mode: kb.mode, layout: kb.layout,
                                               talking: kb.talking, shift: kb.shift, shiftHeld: kb.shiftHeld, typed: kb.typedLog,
                                               symCat: kb.symCat, symLock: kb.symLock, clearPill: kb.clearPillOn, clearHot: kb.clearHot,
                                               commit: osk.commitAvailable }))
            break
        default: osk.setDebugState("unknown command " + cmd)
        }
    }

    Connections {
        target: osk
        function onDebugCommand(cmd, arg) { hook.run(cmd, arg) }
    }
    Timer { id: holdTimer; property var point; onTriggered: hook.area.end(point, false) }
}
