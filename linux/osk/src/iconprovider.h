// image://icon/<name>/<colour>/<stroke>  e.g. image://icon/backspace/ebffffff/2
// Draws our own line icons (data/icons.json, 24x24 grid; "__space" is 48x24) in any colour and
// stroke width, so one icon set serves all four keyboard skins. <colour> is QColor hex without '#'
// (rrggbb or aarrggbb). Ask for sourceSize in device pixels.
#pragma once
#include <QHash>
#include <QQuickImageProvider>

class IconProvider : public QQuickImageProvider
{
public:
    explicit IconProvider(const QString &jsonPath);
    QImage requestImage(const QString &id, QSize *size, const QSize &requestedSize) override;

private:
    QHash<QString, QString> m_paths;
};
