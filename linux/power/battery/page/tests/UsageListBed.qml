// The A6 half of state-test.cpp: the page's own UsageList.qml (the directory import) as the landscape column, which
// scrolls its own list. state-test.cpp sets the range and reads the place through the functions below.
import QtQuick
import "../qml"

Window {
    width: 528
    height: 600
    visible: true

    UsageList {
        id: list
        anchors.fill: parent
    }

    // the list's ListView: its only child with a contentY
    function view() {
        for (var i = 0; i < list.children.length; i++)
            if (list.children[i].contentY !== undefined)
                return list.children[i]
        return null
    }
    function setRange(r) {
        list.range = r
    }
    function count() {
        return view().count
    }
    function scrollTo(y) {
        view().contentY = view().originY + y
    }
    function pos() {
        return view().contentY - view().originY
    }
    function rowPct(i) {
        var it = view().itemAtIndex(i)
        return it && it.item ? it.item.pct_raw : -1
    }
}
