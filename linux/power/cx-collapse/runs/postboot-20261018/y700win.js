// 2026-10-18: list plasmashell's surfaces (which popup is left open?) - printed to kwin_wayland's journal
const ws = workspace.windowList();
for (let i = 0; i < ws.length; i++) {
    const w = ws[i];
    const g = w.frameGeometry;
    print("Y700WIN class=" + w.resourceClass + " name=" + w.resourceName + " caption=[" + w.caption + "] popup=" + w.popupWindow
          + " dock=" + w.dock + " normal=" + w.normalWindow + " dialog=" + w.dialog + " notification=" + w.notification
          + " onscreendisplay=" + w.onScreenDisplay + " geom=" + g.width + "x" + g.height + "@" + g.x + "," + g.y
          + " minimized=" + w.minimized + " hidden=" + w.hidden + " skipTaskbar=" + w.skipTaskbar + " layer=" + w.layer);
}
