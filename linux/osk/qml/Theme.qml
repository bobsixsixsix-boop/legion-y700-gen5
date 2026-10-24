// Colour tokens of the four skins, 1:1 with the design mockup's CSS (.kb, .s-glass-light,
// .s-solid-light, .s-solid-dark). Dark glass = default: control-centre hue with vivo's 0.80 tint.
pragma Singleton
import QtQuick

QtObject {
    id: t
    property string skin: "glass-dark"          // glass-dark | glass-light | solid-light | solid-dark
    readonly property bool light: skin.endsWith("light")
    readonly property bool glass: skin.startsWith("glass")

    readonly property color mat: skin === "glass-light" ? Qt.rgba(231/255, 234/255, 240/255, .80)
                               : skin === "solid-light" ? "#ebedf1"
                               : skin === "solid-dark" ? "#232323" : Qt.rgba(22/255, 24/255, 30/255, .80)
    readonly property color hair: skin === "glass-light" ? Qt.rgba(1, 1, 1, .55)
                                : skin === "solid-light" ? Qt.rgba(0, 0, 0, .05)
                                : skin === "solid-dark" ? Qt.rgba(1, 1, 1, .06) : Qt.rgba(1, 1, 1, .10)
    readonly property color key: skin === "glass-light" ? Qt.rgba(1, 1, 1, .50)
                               : skin === "solid-light" ? "#ffffff"
                               : skin === "solid-dark" ? "#4d4d4d" : Qt.rgba(1, 1, 1, .18)
    readonly property color keyP: skin === "glass-light" ? Qt.rgba(1, 1, 1, .15)
                                : skin === "solid-light" ? "#bfc5cf"
                                : skin === "solid-dark" ? "#5c5c5c" : Qt.rgba(1, 1, 1, .28)
    readonly property color fn: skin === "glass-light" ? Qt.rgba(150/255, 158/255, 173/255, .40)
                              : skin === "solid-light" ? "#bfc5cf"
                              : skin === "solid-dark" ? "#333333" : Qt.rgba(1, 1, 1, .09)
    readonly property color fnP: skin === "glass-light" ? Qt.rgba(148/255, 156/255, 173/255, .12)
                               : skin === "solid-light" ? "#909499"
                               : skin === "solid-dark" ? "#4d4d4d" : Qt.rgba(1, 1, 1, .18)
    readonly property color lip: skin === "solid-light" ? "#a7a9b0" : skin === "solid-dark" ? "#131313" : Qt.rgba(0, 0, 0, .30)
    readonly property color lipP: skin === "glass-light" ? Qt.rgba(0, 0, 0, .09) : skin.startsWith("solid") ? "transparent" : Qt.rgba(0, 0, 0, .10)
    readonly property color edge: skin === "solid-dark" ? Qt.rgba(1, 1, 1, .05) : light ? "transparent" : Qt.rgba(1, 1, 1, .07)
    readonly property color ink: light ? "#333333" : skin === "solid-dark" ? "#e8e8e8" : Qt.rgba(1, 1, 1, .92)
    readonly property color ink2: light ? Qt.rgba(51/255, 51/255, 51/255, .30) : skin === "solid-dark" ? Qt.rgba(232/255, 232/255, 232/255, .36) : Qt.rgba(1, 1, 1, .35)
    readonly property color ink3: light ? Qt.rgba(51/255, 51/255, 51/255, .60) : skin === "solid-dark" ? Qt.rgba(232/255, 232/255, 232/255, .60) : Qt.rgba(1, 1, 1, .60)
    readonly property color icon: ink
    readonly property color icon2: light ? "#333333" : skin === "solid-dark" ? Qt.rgba(232/255, 232/255, 232/255, .85) : Qt.rgba(1, 1, 1, .85)
    readonly property color acc: "#2e6bf6"
    readonly property color accP: light ? "#2658ca" : "#5486f8"
    readonly property color accInk: light ? "#2e6bf6" : "#5486f8"
    readonly property color accLip: skin === "solid-light" ? "#0c3262" : skin === "glass-light" ? Qt.rgba(12/255, 50/255, 98/255, .45) : Qt.rgba(8/255, 22/255, 64/255, .55)
    readonly property color accSoft: light ? Qt.rgba(46/255, 107/255, 246/255, skin === "solid-light" ? .14 : .16) : Qt.rgba(46/255, 107/255, 246/255, .22)
    readonly property color pop: light ? "#fcfefd" : skin === "solid-dark" ? "#4a4a4a" : "#464950"
    readonly property color popLine: light ? "#c5c5c5" : skin === "solid-dark" ? Qt.rgba(1, 1, 1, .08) : Qt.rgba(1, 1, 1, .14)
    readonly property real popShadow: light ? .12 : .30
    readonly property color card: skin === "glass-light" ? Qt.rgba(1, 1, 1, .40) : skin === "solid-light" ? "#ffffff" : skin === "solid-dark" ? "#333333" : Qt.rgba(1, 1, 1, .12)
    readonly property color cardP: skin === "glass-light" ? Qt.rgba(1, 1, 1, .75) : skin === "solid-light" ? "#dfe2e8" : skin === "solid-dark" ? "#4d4d4d" : Qt.rgba(1, 1, 1, .20)
    readonly property color chip: skin === "glass-light" ? Qt.rgba(0, 0, 0, .06) : skin === "solid-light" ? "#e6e9ef" : skin === "solid-dark" ? "#454545" : Qt.rgba(1, 1, 1, .14)
    readonly property color sep: light ? Qt.rgba(0, 0, 0, .078) : skin === "solid-dark" ? Qt.rgba(1, 1, 1, .08) : Qt.rgba(1, 1, 1, .10)
    readonly property color tap: skin === "glass-light" ? Qt.rgba(1, 1, 1, .70) : glass ? Qt.rgba(1, 1, 1, .24) : "transparent"
    readonly property color sheet: skin === "glass-light" ? Qt.rgba(235/255, 237/255, 241/255, .97) : skin === "solid-light" ? "#f5f6f9"
                                 : skin === "solid-dark" ? "#2b2b2b" : Qt.rgba(34/255, 37/255, 44/255, .97)
    readonly property color pillTrack: light ? Qt.rgba(0, 0, 0, .08) : card
    readonly property color pillFill: light ? "#ffffff" : Qt.rgba(1, 1, 1, .88)
    readonly property color mask: Qt.rgba(0, 0, 0, .75)
    readonly property color danger: "#ff3b30"
    readonly property bool pressSinks: light       // light skins sink on press, dark ones brighten

    readonly property string font: "Noto Sans CJK SC"
    // control-centre motion: press 160 ms OutCubic, colour 150 ms
    readonly property int pressMs: 160
    readonly property int colourMs: 150

    // image://icon/<name>/<aarrggbb>/<stroke>
    function ic(name, colour, stroke) {
        var c = Qt.color(colour);
        function h(v) { var s = Math.round(v * 255).toString(16); return s.length < 2 ? "0" + s : s; }
        return "image://icon/" + name + "/" + h(c.a) + h(c.r) + h(c.g) + h(c.b) + "/" + (stroke || 2);
    }
}
