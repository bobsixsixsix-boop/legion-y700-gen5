/*
    y700-stagecorners effect factory. Wayland only (the tablet's session; the bed's kwin_wayland too).
*/
#include "stagecorners.h"

#include "wayland_server.h"

namespace KWin
{

KWIN_EFFECT_FACTORY_SUPPORTED(StageCornersEffect, "metadata.json", return waylandServer() != nullptr;)

} // namespace KWin

#include "main.moc"
