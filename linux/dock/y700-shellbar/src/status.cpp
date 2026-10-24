#include "status.h"
#include <QDBusArgument>
#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusMetaType>
#include <QDBusObjectPath>
#include <QDBusVariant>

using IfaceMap = QMap<QString, QVariantMap>;
using ObjMap = QMap<QDBusObjectPath, IfaceMap>;
Q_DECLARE_METATYPE(IfaceMap)
Q_DECLARE_METATYPE(ObjMap)

static const char *PROPS = "org.freedesktop.DBus.Properties";
static const char *NM = "org.freedesktop.NetworkManager";

static QVariant prop(const QString &svc, const QString &path, const QString &iface, const QString &name)
{
    QDBusMessage m = QDBusMessage::createMethodCall(svc, path, PROPS, "Get");
    m << iface << name;
    const QDBusMessage r = QDBusConnection::systemBus().call(m, QDBus::Block, 500);
    if (r.type() != QDBusMessage::ReplyMessage || r.arguments().isEmpty()) return {};
    return r.arguments().first().value<QDBusVariant>().variant();
}

static QString pathOf(const QVariant &v)
{
    if (v.canConvert<QDBusObjectPath>()) return v.value<QDBusObjectPath>().path();
    return v.toString();
}

Status::Status(QObject *parent) : QObject(parent)
{
    qDBusRegisterMetaType<IfaceMap>();
    qDBusRegisterMetaType<ObjMap>();
    m_debounce.setSingleShot(true);
    m_debounce.setInterval(300);
    connect(&m_debounce, &QTimer::timeout, this, &Status::readAll);

    QDBusConnection bus = QDBusConnection::systemBus();
    bus.connect("org.freedesktop.UPower", "/org/freedesktop/UPower/devices/DisplayDevice", PROPS, "PropertiesChanged",
                this, SLOT(kickBattery()));
    // empty path = every object of the service: NM's root, the active connection, the access point (Strength)
    bus.connect(NM, QString(), PROPS, "PropertiesChanged", this, SLOT(kick()));
    bus.connect("org.bluez", QString(), PROPS, "PropertiesChanged", this, SLOT(kick()));
    bus.connect("org.bluez", "/", "org.freedesktop.DBus.ObjectManager", "InterfacesAdded", this, SLOT(kick()));
    bus.connect("org.bluez", "/", "org.freedesktop.DBus.ObjectManager", "InterfacesRemoved", this, SLOT(kick()));
    readAll();
}

void Status::readAll()
{
    readBattery();
    readNetwork();
    readBluetooth();
}

void Status::readBattery()
{
    const QString dev = "/org/freedesktop/UPower/devices/DisplayDevice";
    const QVariant pct = prop("org.freedesktop.UPower", dev, "org.freedesktop.UPower.Device", "Percentage");
    const uint state = prop("org.freedesktop.UPower", dev, "org.freedesktop.UPower.Device", "State").toUInt();
    const int b = pct.isValid() ? qRound(pct.toDouble()) : -1;
    const bool c = state == 1 || state == 4 || state == 5;   // charging, full, pending charge (on the charger)
    if (b != m_battery || c != m_charging) {
        m_battery = b; m_charging = c;
        Q_EMIT changed();
    }
}

void Status::readNetwork()
{
    const QString type = prop(NM, "/org/freedesktop/NetworkManager", NM, "PrimaryConnectionType").toString();
    int wifi = -1;
    bool wired = false;
    if (type == "802-11-wireless") {
        const QString ac = pathOf(prop(NM, "/org/freedesktop/NetworkManager", NM, "PrimaryConnection"));
        const QString ap = pathOf(prop(NM, ac, "org.freedesktop.NetworkManager.Connection.Active", "SpecificObject"));
        const int s = ap.isEmpty() || ap == "/" ? 0 : prop(NM, ap, "org.freedesktop.NetworkManager.AccessPoint", "Strength").toInt();
        wifi = s >= 75 ? 4 : s >= 50 ? 3 : s >= 25 ? 2 : s > 0 ? 1 : 0;
    } else if (!type.isEmpty() && type != "loopback") {
        wired = true;
    }
    if (wifi != m_wifi || wired != m_wired) {
        m_wifi = wifi; m_wired = wired;
        Q_EMIT changed();
    }
}

void Status::readBluetooth()
{
    QDBusMessage m = QDBusMessage::createMethodCall("org.bluez", "/", "org.freedesktop.DBus.ObjectManager", "GetManagedObjects");
    const QDBusMessage r = QDBusConnection::systemBus().call(m, QDBus::Block, 500);
    int bt = 0;
    if (r.type() == QDBusMessage::ReplyMessage && !r.arguments().isEmpty()) {
        const ObjMap objs = qdbus_cast<ObjMap>(r.arguments().first());
        bool powered = false, connected = false;
        for (const IfaceMap &ifs : objs) {
            if (ifs.contains("org.bluez.Adapter1") && ifs.value("org.bluez.Adapter1").value("Powered").toBool()) powered = true;
            if (ifs.contains("org.bluez.Device1") && ifs.value("org.bluez.Device1").value("Connected").toBool()) connected = true;
        }
        bt = !powered ? 0 : connected ? 2 : 1;
    }
    if (bt != m_bt) {
        m_bt = bt;
        Q_EMIT changed();
    }
}
