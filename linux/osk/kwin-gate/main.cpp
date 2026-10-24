/*
    y700-oskgate effect factory. Wayland only (the text-input objects live on the Wayland seat).
*/
#include "oskgate.h"

#include "wayland_server.h"

namespace KWin
{

KWIN_EFFECT_FACTORY_SUPPORTED(OskGateEffect, "metadata.json", return waylandServer() != nullptr;)

} // namespace KWin

#include "main.moc"
