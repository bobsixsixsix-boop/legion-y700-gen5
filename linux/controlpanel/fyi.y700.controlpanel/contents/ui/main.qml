// Y700 control panel plasmoid: a vertical stack of flat tiles for a right-edge panel (also works as a
// desktop widget; in a horizontal panel it collapses to an icon that pops the same stack up).
//   brightness   -> org.kde.plasma.private.brightnesscontrolplugin (same plugin as the Brightness applet)
//   volume       -> org.kde.plasma.private.volume (same plugin as the Audio Volume applet), default sink
//   rotation     -> /usr/local/bin/y700-autorotate never|tablet   (libkscreen auto-rotate policy)
//   game overlay -> ~/.local/bin/y700-hud-toggle                 (y700-hud-overlay.service start/stop)
//   bypass       -> tb323fu-ctl bypass on|off                   (polkit: active session, no password)
//   Android      -> tb323fu-ctl android --yes                   (two taps: the tile asks first)
// Shell commands run through the Plasma "executable" data engine; state is polled every 5 s and right
// after every action.
import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasma5support as P5Support
import org.kde.plasma.private.volume as Vol
import org.kde.plasma.private.brightnesscontrolplugin as Bright

PlasmoidItem {
    id: root
    preferredRepresentation: Plasmoid.formFactor === PlasmaCore.Types.Horizontal ? compactRepresentation : fullRepresentation
    Plasmoid.backgroundHints: PlasmaCore.Types.NoBackground

    // ---- state ----
    property bool bypass: false
    property bool hud: false
    property bool rotLocked: false
    property int battery: -1
    property bool charging: false
    property bool androidArmed: false
    property string pending: ""          // tile whose command is running

    readonly property string statusCmd:
        "tb323fu-ctl --json status 2>/dev/null; echo ===HUD; systemctl --user is-active y700-hud-overlay.service; echo ===ROT; /usr/local/bin/y700-autorotate status 2>/dev/null"

    P5Support.DataSource {
        id: exec
        engine: "executable"
        connectedSources: []
        onNewData: (source, data) => {
            const out = String(data["stdout"] || "")
            disconnectSource(source)
            if (source === root.statusCmd) root.parseStatus(out)
            else { root.pending = ""; refresh.restart() }
        }
        function run(cmd) { connectSource(cmd) }
    }
    function parseStatus(out) {
        const parts = out.split("===HUD")
        try {
            const j = JSON.parse(parts[0])
            root.bypass = !!(j.Battery && j.Battery.Bypass)
            root.battery = j.Battery ? Number(j.Battery.Capacity) : -1
            root.charging = !!(j.Battery && Number(j.Battery.InputCurrentMa) > 0)
        } catch (e) { }
        if (parts.length > 1) {
            const rest = parts[1].split("===ROT")
            root.hud = rest[0].trim() === "active"
            if (rest.length > 1) root.rotLocked = rest[1].indexOf(" never") >= 0
        }
    }
    Timer { id: poll; interval: 5000; running: true; repeat: true; triggeredOnStart: true; onTriggered: exec.run(root.statusCmd) }
    Timer { id: refresh; interval: 700; onTriggered: exec.run(root.statusCmd) }
    Timer { id: disarm; interval: 6000; onTriggered: root.androidArmed = false }
    function act(name, cmd) { root.pending = name; exec.run(cmd) }

    // ---- system plugins ----
    // PreferredDevice is a singleton in Plasma 6 (same as the Audio Volume applet uses)
    readonly property var sink: Vol.PreferredDevice.sink
    Bright.ScreenBrightnessControl { id: sbc; isSilent: true }

    compactRepresentation: Kirigami.Icon {
        source: "preferences-system"
        MouseArea { anchors.fill: parent; onClicked: root.expanded = !root.expanded }
    }

    fullRepresentation: Item {
        id: full
        Layout.minimumWidth: 84
        Layout.preferredWidth: 84
        Layout.minimumHeight: col.implicitHeight + 12
        Layout.preferredHeight: col.implicitHeight + 12
        Layout.maximumHeight: Layout.preferredHeight

        ColumnLayout {
            id: col
            anchors { top: parent.top; topMargin: 6; horizontalCenter: parent.horizontalCenter }
            width: 74
            spacing: 6

            // battery line
            Text {
                Layout.alignment: Qt.AlignHCenter
                text: root.battery < 0 ? "" : (root.charging ? "⚡ " : "") + root.battery + "%"
                color: Kirigami.Theme.textColor
                font.pixelSize: 11
                font.weight: Font.DemiBold
            }

            // brightness: first (internal) display of the plugin's model
            Repeater {
                model: sbc.displays
                delegate: VSlider {
                    required property var model
                    Layout.fillWidth: true
                    icon: "brightness-high"
                    available: sbc.isBrightnessAvailable
                    value: model.maxBrightness > 0 ? 100 * model.brightness / model.maxBrightness : 0
                    onMoved: (v) => sbc.setBrightness(model.displayName, Math.round(Math.max(1, v) / 100 * model.maxBrightness))
                }
            }

            VSlider {
                Layout.fillWidth: true
                icon: root.sink && root.sink.muted ? "audio-volume-muted" : "audio-volume-high"
                available: root.sink !== null && root.sink !== undefined
                value: root.sink ? 100 * root.sink.volume / 65536 : 0
                onMoved: (v) => { if (root.sink) { root.sink.muted = false; root.sink.volume = Math.round(v / 100 * 65536) } }
            }

            Tile {
                Layout.fillWidth: true
                icon: root.rotLocked ? "rotation-locked" : "rotation-allowed"
                title: "旋转锁定"
                caption: root.rotLocked ? "已锁定" : "自动"
                active: root.rotLocked
                busy: root.pending === "rot"
                onTapped: root.act("rot", "/usr/local/bin/y700-autorotate " + (root.rotLocked ? "tablet" : "never"))
            }
            Tile {
                Layout.fillWidth: true
                icon: "speedometer"
                title: "性能浮层"
                caption: root.hud ? "显示中" : "关"
                active: root.hud
                busy: root.pending === "hud"
                onTapped: root.act("hud", "~/.local/bin/y700-hud-toggle")
            }
            Tile {
                Layout.fillWidth: true
                icon: "battery-charging"
                title: "旁路供电"
                caption: root.bypass ? "开" : "关"
                active: root.bypass
                busy: root.pending === "bypass"
                onTapped: root.act("bypass", "tb323fu-ctl bypass " + (root.bypass ? "off" : "on"))
            }

            Item { Layout.preferredHeight: 10 }

            Tile {
                Layout.fillWidth: true
                icon: "smartphone"
                title: root.androidArmed ? "确认切换?" : "Android"
                caption: root.androidArmed ? "再点一次" : "重启切换"
                danger: root.androidArmed
                busy: root.pending === "android"
                onTapped: {
                    if (root.androidArmed) { root.androidArmed = false; root.act("android", "tb323fu-ctl android --yes") }
                    else { root.androidArmed = true; disarm.restart() }
                }
            }
        }
    }
}
