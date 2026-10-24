#include "iconprovider.h"

#include <QColor>
#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QPainter>
#include <QSvgRenderer>

IconProvider::IconProvider(const QString &jsonPath)
    : QQuickImageProvider(QQuickImageProvider::Image)
{
    QFile f(jsonPath);
    if (f.open(QIODevice::ReadOnly)) {
        const QJsonObject o = QJsonDocument::fromJson(f.readAll()).object();
        for (auto it = o.begin(); it != o.end(); ++it) m_paths.insert(it.key(), it.value().toString());
    }
}

QImage IconProvider::requestImage(const QString &id, QSize *size, const QSize &requestedSize)
{
    const QStringList parts = id.split(QLatin1Char('/'));
    const QString name = parts.value(0);
    QColor colour(QLatin1Char('#') + parts.value(1, QStringLiteral("ffffff")));
    if (!colour.isValid()) colour = Qt::white;
    const double stroke = parts.value(2, QStringLiteral("2")).toDouble();
    const bool wide = name == QLatin1String("__space");
    const QSize box = requestedSize.isValid() && !requestedSize.isEmpty() ? requestedSize : (wide ? QSize(96, 48) : QSize(48, 48));
    if (size) *size = box;

    const QString rgb = colour.name(QColor::HexRgb);
    QString body = m_paths.value(name);
    body.replace(QStringLiteral("currentColor"), rgb);
    const QString svg = QStringLiteral(
        "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 %1 24\" fill=\"none\" stroke=\"%2\" "
        "stroke-width=\"%3\" stroke-linecap=\"round\" stroke-linejoin=\"round\">%4</svg>")
        .arg(wide ? 48 : 24).arg(rgb).arg(stroke).arg(body);

    QImage img(box, QImage::Format_ARGB32_Premultiplied);
    img.fill(Qt::transparent);
    QSvgRenderer r(svg.toUtf8());
    QPainter p(&img);
    p.setRenderHint(QPainter::Antialiasing);
    p.setOpacity(colour.alphaF());
    r.render(&p);
    return img;
}
