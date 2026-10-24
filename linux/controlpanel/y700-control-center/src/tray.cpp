#include "tray.h"
#include <KWaylandExtras>
#include <QCoreApplication>
#include <QDBusArgument>
#include <QDBusConnection>
#include <QDBusConnectionInterface>
#include <QDBusError>
#include <QDBusObjectPath>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QDBusServiceWatcher>
#include <QDBusVariant>
#include <QDir>
#include <QEvent>
#include <QFile>
#include <QFileInfo>
#include <QFutureWatcher>
#include <QGuiApplication>
#include <QIcon>
#include <QMutexLocker>
#include <QRegularExpression>
#include <QStandardPaths>
#include <QWindow>
#include <algorithm>
#include <limits>
#include <QtEndian>
#include <QtMath>
#include <cstdio>

static const QString WATCHER = QStringLiteral("org.kde.StatusNotifierWatcher");
static const QString WATCHER_PATH = QStringLiteral("/StatusNotifierWatcher");
static const QString SNI = QStringLiteral("org.kde.StatusNotifierItem");
static const QString DBUSMENU = QStringLiteral("com.canonical.dbusmenu");
static const QString PROPS = QStringLiteral("org.freedesktop.DBus.Properties");

// one stderr line per event (the journal of the user unit; the tray test greps these prefixes)
static QByteArray u8(const QString &s) { return s.toUtf8(); }

// no answer in time: the app is busy or hung (Electron answers on its UI thread), not "it cannot"
static bool noAnswer(const QDBusError &e) { return e.type() == QDBusError::NoReply || e.type() == QDBusError::Timeout; }
// the name has no owner (any more): the app, or the watcher, is not there
static bool noOwner(const QDBusError &e)
{
    return e.type() == QDBusError::ServiceUnknown || e.name() == QLatin1String("org.freedesktop.DBus.Error.NameHasNoOwner");
}

// ---------------------------------------------------------------- icons

// IconPixmap / AttentionIconPixmap a(iiay): ARGB32 in network byte order, one image per size
static QImage argbImage(int w, int h, const QByteArray &data)
{
    if (w <= 0 || h <= 0 || w > 1024 || h > 1024 || data.size() < qsizetype(w) * h * 4) return {};
    QImage img(w, h, QImage::Format_ARGB32);
    const uchar *src = reinterpret_cast<const uchar *>(data.constData());
    for (int y = 0; y < h; ++y) {
        QRgb *dst = reinterpret_cast<QRgb *>(img.scanLine(y));
        for (int x = 0; x < w; ++x, src += 4) dst[x] = qFromBigEndian<quint32>(src);
    }
    return img;
}

// a QDBusArgument is read once (its copies share the read position): every property is parsed in one place
static QList<QImage> readPixmaps(const QVariant &v)
{
    QList<QImage> out;
    if (v.userType() != qMetaTypeId<QDBusArgument>()) return out;
    const QDBusArgument a = v.value<QDBusArgument>();
    if (a.currentSignature() != QLatin1String("a(iiay)")) return out;
    a.beginArray();
    while (!a.atEnd()) {
        int w = 0, h = 0;
        QByteArray data;
        a.beginStructure();
        a >> w >> h >> data;
        a.endStructure();
        const QImage img = argbImage(w, h, data);
        if (!img.isNull()) out << img;
    }
    a.endArray();
    return out;
}

// ToolTip (sa(iiay)ss): icon name, icon pixmaps, title, text. The title is Electron's only name for itself
// (its Title is empty: Claude's says "Claude" here)
static QString toolTipTitle(const QVariant &v)
{
    if (v.userType() != qMetaTypeId<QDBusArgument>()) return {};
    const QDBusArgument a = v.value<QDBusArgument>();
    if (a.currentSignature() != QLatin1String("(sa(iiay)ss)")) return {};
    QString icon, title, text;
    a.beginStructure();
    a >> icon;
    a.beginArray();
    while (!a.atEnd()) {
        int w = 0, h = 0;
        QByteArray data;
        a.beginStructure();
        a >> w >> h >> data;
        a.endStructure();
    }
    a.endArray();
    a >> title >> text;
    a.endStructure();
    return title;
}

static QString objectPath(const QVariant &v)
{
    if (v.userType() == qMetaTypeId<QDBusObjectPath>()) return v.value<QDBusObjectPath>().path();
    return v.toString();
}

// a reply's 'v' as the value inside it
static QVariant unwrap(const QVariant &v)
{
    return v.userType() == qMetaTypeId<QDBusVariant>() ? v.value<QDBusVariant>().variant() : v;
}

// the curtain's own scale (1.9 on the tablet: fractional-scale-v1, known once it is mapped; before that the screen's
// integer one), the scale the QML's Image asks the provider for (sourceSize x it)
qreal Tray::iconDpr() const
{
    return m_window ? m_window->devicePixelRatio() : qGuiApp->devicePixelRatio();
}

// device pixels for an icon of `logical` px, rounded as QQuickImage rounds sourceSize x scale (32 at 1.9 = 61): a
// theme icon is rendered at exactly that size and handed over 1:1 (one rendered bigger and scaled down by 64/61
// came out soft)
int Tray::iconPx(int logical) const
{
    return qMax(1, qRound(logical * iconDpr()));
}

// IconThemePath: an app's own icon directory (a theme or just files). Its files first (libappindicator apps write
// theirs there, a new name for every change), then an index of the tree three levels down (<path>/hicolor/48x48/apps),
// built once per path: this runs on the GUI thread, and walking an app's big tree on every icon change stalled it
QIcon Tray::iconFromPath(const QString &name, const QString &themePath)
{
    static const QStringList exts = {QStringLiteral(".png"), QStringLiteral(".svg"), QStringLiteral(".svgz"), QStringLiteral(".xpm")};
    QIcon icon;
    const QDir top(themePath);
    for (const QString &e : exts)
        if (QFileInfo::exists(top.filePath(name + e))) icon.addFile(top.filePath(name + e));
    if (!icon.isNull()) return icon;
    auto idx = m_pathIndex.constFind(themePath);
    if (idx == m_pathIndex.constEnd()) {
        QHash<QString, QStringList> files;
        QList<QPair<QString, int>> dirs = {{themePath, 0}};
        int visited = 0;
        while (!dirs.isEmpty() && ++visited <= 64) {
            const auto [path, depth] = dirs.takeFirst();
            const QDir d(path);
            for (const QFileInfo &f : d.entryInfoList({"*.png", "*.svg", "*.svgz", "*.xpm"}, QDir::Files))
                files[f.completeBaseName()] << f.filePath();
            if (depth < 3)
                for (const QString &sub : d.entryList(QDir::Dirs | QDir::NoDotAndDotDot)) dirs << qMakePair(d.filePath(sub), depth + 1);
        }
        if (m_pathIndex.size() >= 16) m_pathIndex.clear();     // a handful of apps have one; never many
        idx = m_pathIndex.insert(themePath, files);
    }
    for (const QString &f : idx->value(name)) icon.addFile(f);
    return icon;
}

// an icon name (or a file path, which some apps give) at px device pixels; GUI thread only. Null if nothing has it.
QImage Tray::themeImage(const QString &name, const QString &themePath, int px)
{
    if (name.isEmpty()) return {};
    QIcon icon;
    if (QDir::isAbsolutePath(name)) {
        if (QFileInfo::exists(name)) icon = QIcon(name);
    } else {
        if (!themePath.isEmpty()) icon = iconFromPath(name, themePath);
        if (icon.isNull() && QIcon::hasThemeIcon(name)) icon = QIcon::fromTheme(name);
    }
    if (icon.isNull()) return {};
    return icon.pixmap(QSize(px, px), 1.0).toImage();
}

// [Icons] Theme from kdeglobals: ~/.config first, then the XDG_CONFIG_DIRS cascade (Plasma keeps the look-and-feel's
// default in ~/.config/kdedefaults, which the session puts first there). None: breeze-dark, not breeze - the curtain
// is always dark (its tint over the blur), and breeze's monochrome icons are dark glyphs (the tablet's own is
// breeze-dark too, from kdedefaults)
static QString kdeglobalsTheme()
{
    QStringList files;
    const QString home = qEnvironmentVariable("XDG_CONFIG_HOME", QDir::homePath() + "/.config");
    files << home + "/kdeglobals";
    for (const QString &d : qEnvironmentVariable("XDG_CONFIG_DIRS", "/etc/xdg").split(':', Qt::SkipEmptyParts)) files << d + "/kdeglobals";
    for (const QString &f : files) {
        QFile file(f);
        if (!file.open(QIODevice::ReadOnly)) continue;
        bool icons = false;
        for (const QByteArray &raw : file.readAll().split('\n')) {
            const QByteArray l = raw.trimmed();
            if (l.startsWith('[')) { icons = l == "[Icons]"; continue; }
            if (icons && l.startsWith("Theme=")) {
                const QString t = QString::fromUtf8(l.mid(6)).trimmed();
                if (!t.isEmpty()) return t;
            }
        }
    }
    return QStringLiteral("breeze-dark");
}

TrayImages::TrayImages(std::shared_ptr<TrayIconStore> store)
    : QQuickImageProvider(QQuickImageProvider::Image), m_store(std::move(store))
{
}

QImage TrayImages::requestImage(const QString &id, QSize *size, const QSize &requestedSize)
{
    // "<n>/<rev>": the revision only made the url new
    const QString key = id.startsWith(QLatin1String("theme/")) || id.startsWith(QLatin1String("data/")) ? id : id.section('/', 0, 0);
    QList<QImage> imgs;
    {
        QMutexLocker l(&m_store->lock);
        imgs = m_store->images.value(key);
    }
    if (imgs.isEmpty()) { if (size) *size = QSize(); return {}; }   // -> Image.Error: the QML draws the letter
    const int want = qMax(requestedSize.width(), requestedSize.height());
    // the smallest image at least as big as asked for, else the biggest there is
    const QImage *best = nullptr;
    for (const QImage &img : imgs) {
        const int s = qMax(img.width(), img.height());
        const int b = best ? qMax(best->width(), best->height()) : 0;
        if (!best || (want > 0 && s >= want && (b < want || s < b)) || ((want <= 0 || b < want) && s > b)) best = &img;
    }
    QImage out = *best;
    if (want > 0 && qMax(out.width(), out.height()) != want)
        out = out.scaled(QSize(want, want), Qt::KeepAspectRatio, Qt::SmoothTransformation);
    if (size) *size = out.size();
    return out;
}

// ---------------------------------------------------------------- host

bool Tray::Item::hasMenu() const
{
    // KStatusNotifierItem says /NO_DBUSMENU when it has none
    return !menuPath.isEmpty() && menuPath != QLatin1String("/") && menuPath != QLatin1String("/NO_DBUSMENU");
}

QString Tray::Item::label() const
{
    return !title.isEmpty() ? title : !tipTitle.isEmpty() ? tipTitle : !id.isEmpty() ? id : service;
}

Tray::Tray(QObject *parent) : QObject(parent), m_store(std::make_shared<TrayIconStore>())
{
    // Theme icons need a theme in our process. It comes through KDE's platform theme: the unit's environment has
    // XDG_CURRENT_DESKTOP=KDE and no QT_QPA_PLATFORMTHEME, and KDEPlasmaPlatformTheme6 is installed (10-23), so Qt
    // loads it and it reads kdeglobals (breeze-dark from ~/.config/kdedefaults on the tablet; the live process maps
    // KDEPlasmaPlatformTheme6.so, checked 10-23). Without it QIcon has no theme, or Qt's generic one says "hicolor"
    // (the sb-bed: no XDG_CURRENT_DESKTOP), the fallback that holds only app icons: read kdeglobals ourselves, else
    // breeze-dark. A platform without a theme (offscreen) has no search paths either: the XDG data dirs' icons then.
    if (QIcon::themeName().isEmpty() || QIcon::themeName() == QLatin1String("hicolor")) QIcon::setThemeName(kdeglobalsTheme());
    QStringList paths = QIcon::themeSearchPaths();
    if (std::none_of(paths.cbegin(), paths.cend(), [](const QString &p) { return !p.startsWith(':') && QFileInfo(p).isDir(); })) {
        paths << QStandardPaths::locateAll(QStandardPaths::GenericDataLocation, QStringLiteral("icons"), QStandardPaths::LocateDirectory);
        QIcon::setThemeSearchPaths(paths);
    }
    fprintf(stderr, "tray: icon theme %s\n", u8(QIcon::themeName()).constData());

    m_clock.start();
    m_refetchTimer.setSingleShot(true);
    connect(&m_refetchTimer, &QTimer::timeout, this, [this] {
        const qint64 now = m_clock.elapsed();
        QStringList due;
        for (auto i = m_refetch.cbegin(); i != m_refetch.cend(); ++i)
            if (i.value() <= now + 5) due << i.key();
        for (const QString &k : std::as_const(due)) {
            m_refetch.remove(k);
            if (auto it = find(k)) fetch(it);
        }
        armRefetch();
    });
    m_menuRefresh.setSingleShot(true);
    m_menuRefresh.setInterval(100);
    connect(&m_menuRefresh, &QTimer::timeout, this, [this] {
        if (!m_menuKey.isEmpty() && !m_levels.isEmpty()) loadLevel(m_levels.last().id, false, Load::Refresh, QString());
    });
    m_syncRetry.setSingleShot(true);
    connect(&m_syncRetry, &QTimer::timeout, this, [this] { registerHost(); });

    QDBusConnection bus = QDBusConnection::sessionBus();
    m_owners = new QDBusServiceWatcher(this);
    m_owners->setConnection(bus);
    m_owners->setWatchMode(QDBusServiceWatcher::WatchForUnregistration);
    connect(m_owners, &QDBusServiceWatcher::serviceUnregistered, this, [this](const QString &service) {
        QStringList gone;
        for (const auto &it : std::as_const(m_items))
            if (it->service == service) gone << it->key;
        for (const QString &k : gone) remove(k);
    });
    // the signals follow the watcher's name to whichever process owns it (QtDBus tracks the owner)
    bus.connect(WATCHER, WATCHER_PATH, WATCHER, QStringLiteral("StatusNotifierItemRegistered"), this, SLOT(onRegistered(QString)));
    bus.connect(WATCHER, WATCHER_PATH, WATCHER, QStringLiteral("StatusNotifierItemUnregistered"), this, SLOT(onUnregistered(QString)));
    // kded6 restarted: its items are gone with it (the apps register again with the new one, which also needs us
    // registered again as a host)
    m_watcherWatch = new QDBusServiceWatcher(WATCHER, bus, QDBusServiceWatcher::WatchForOwnerChange, this);
    connect(m_watcherWatch, &QDBusServiceWatcher::serviceOwnerChanged, this,
            [this](const QString &, const QString &oldOwner, const QString &newOwner) {
                m_syncRetry.stop();
                m_retries = 0;
                m_hostOk = m_listOk = false;
                if (!oldOwner.isEmpty()) clearAll();
                if (!newOwner.isEmpty()) registerHost();
            });
    registerHost();     // no watcher yet: the call fails, and its arrival registers us
}

Tray::~Tray() = default;

void Tray::setWindow(QWindow *w)
{
    if (m_window) m_window->removeEventFilter(this);
    m_window = w;
    if (w) w->installEventFilter(this);
}

// the curtain's scale arrives with its first show (1.9 on the tablet, the screen said 2 before): the icons are
// rendered again at the new size, 1:1 with what the QML asks for
bool Tray::eventFilter(QObject *o, QEvent *e)
{
    if (o == m_window && e->type() == QEvent::DevicePixelRatioChange) QTimer::singleShot(0, this, [this] { rerenderIcons(); });
    return QObject::eventFilter(o, e);
}

void Tray::registerHost()
{
    QDBusConnection bus = QDBusConnection::sessionBus();
    if (m_hostName.isEmpty()) {
        // a call to the bus daemon only (main.cpp takes its name the same way). kded6 ignores a host whose name it
        // cannot see owned, without an error: the name must be ours before we tell it
        const QString name = QStringLiteral("org.kde.StatusNotifierHost-%1").arg(QCoreApplication::applicationPid());
        if (!bus.registerService(name)) fprintf(stderr, "tray: could not own %s\n", u8(name).constData());
        m_hostName = name;
    }
    m_hostOk = m_listOk = false;
    QDBusMessage m = QDBusMessage::createMethodCall(WATCHER, WATCHER_PATH, WATCHER, QStringLiteral("RegisterStatusNotifierHost"));
    m << m_hostName;
    auto *w = new QDBusPendingCallWatcher(bus.asyncCall(m, 2000), this);
    connect(w, &QDBusPendingCallWatcher::finished, this, [this](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        if (!w->isError()) {
            m_hostOk = true;
            fprintf(stderr, "tray: host registered as %s\n", u8(m_hostName).constData());
        } else if (!noOwner(w->error())) {     // no watcher at all is no error: its arrival registers us
            fprintf(stderr, "tray: host not registered (%s)\n", u8(w->error().name()).constData());
            retrySync();
        }
    });
    readItems();
}

void Tray::readItems()
{
    QDBusMessage get = QDBusMessage::createMethodCall(WATCHER, WATCHER_PATH, PROPS, QStringLiteral("Get"));
    get << WATCHER << QStringLiteral("RegisteredStatusNotifierItems");
    auto *w = new QDBusPendingCallWatcher(QDBusConnection::sessionBus().asyncCall(get, 2000), this);
    connect(w, &QDBusPendingCallWatcher::finished, this, [this](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        const QDBusMessage r = w->reply();
        if (r.type() == QDBusMessage::ReplyMessage && !r.arguments().isEmpty()) {
            m_listOk = true;
            sync(unwrap(r.arguments().first()).toStringList());
            return;
        }
        if (w->isError() && noOwner(w->error())) return;
        fprintf(stderr, "tray: item list unreadable (%s)\n", u8(w->isError() ? w->error().name() : QStringLiteral("empty reply")).constData());
        retrySync();
    });
}

// The watcher is there but did not answer in time (kded6 is single-threaded and busy at login, when this starts too):
// the items it had would never show (apps do not register twice with one watcher). Again after 1, 3 and 10 s, then
// on every show; a second registration and sync() are harmless.
void Tray::retrySync()
{
    static constexpr int steps[] = {1000, 3000, 10000};
    if (m_syncRetry.isActive() || m_retries >= 3) return;
    m_syncRetry.start(steps[m_retries++]);
}

// The watcher's list as it was when it answered: every Registered/Unregistered it sent before that has been
// delivered already (one sender, in order), every later one comes after. So it is the truth at this point.
void Tray::sync(const QStringList &registered)
{
    QStringList gone;
    for (const auto &it : std::as_const(m_items))
        if (!registered.contains(it->key)) gone << it->key;
    for (const QString &k : gone) remove(k);
    for (const QString &k : registered) add(k);
}

void Tray::onRegistered(const QString &item) { add(item); }
void Tray::onUnregistered(const QString &item) { remove(item); }

std::shared_ptr<Tray::Item> Tray::find(const QString &key) const
{
    for (const auto &it : m_items)
        if (it->key == key) return it;
    return nullptr;
}

void Tray::add(const QString &key)
{
    if (key.isEmpty() || find(key)) return;
    auto it = std::make_shared<Item>();
    it->key = key;
    // "service/path"; a bare service is the spec's default path (kded6 stores them normalized, others may not)
    const int slash = key.indexOf('/');
    it->service = slash > 0 ? key.left(slash) : key;
    it->path = slash > 0 ? key.mid(slash) : QStringLiteral("/StatusNotifierItem");
    it->n = ++m_serial;
    m_owners->addWatchedService(it->service);
    m_items << it;
    if (m_open) connectSignals(it);
    fetch(it);      // always, open or not: an item is listed only once its properties are in
}

void Tray::remove(const QString &key)
{
    qsizetype i = 0;
    while (i < m_items.size() && m_items[i]->key != key) ++i;
    if (i == m_items.size()) return;
    const std::shared_ptr<Item> it = m_items.takeAt(i);
    if (it->sig) it->sig->deleteLater();          // its matches go with it
    m_refetch.remove(key);
    if (it->announced) fprintf(stderr, "tray: - %s\n", u8(key).constData());
    {
        QMutexLocker l(&m_store->lock);
        m_store->images.remove(QString::number(it->n));
    }
    bool used = false;
    for (const auto &o : std::as_const(m_items)) used = used || o->service == it->service;
    if (!used) m_owners->removeWatchedService(it->service);
    if (m_menuKey == key) {         // the app behind the open menu went: the page closes
        endMenu(false);
        Q_EMIT menuChanged();
        Q_EMIT menuStateChanged();
    }
    rebuild();
}

void Tray::clearAll()
{
    while (!m_items.isEmpty()) remove(m_items.first()->key);
}

// ---------------------------------------------------------------- an item's properties

// its change signals, only while the curtain is up (setOpen)
void Tray::connectSignals(const std::shared_ptr<Item> &it)
{
    if (it->sig) return;
    std::weak_ptr<Item> weak = it;
    it->sig = new TraySignals([this, weak] { changed(weak); }, this);
    QDBusConnection bus = QDBusConnection::sessionBus();
    for (const char *s : {"NewIcon", "NewAttentionIcon", "NewOverlayIcon", "NewTitle", "NewToolTip", "NewStatus",
                          "NewIconThemePath", "NewMenu"})
        bus.connect(it->service, it->path, SNI, QString::fromLatin1(s), it->sig, SLOT(fire(QDBusMessage)));
}

void Tray::fetch(const std::shared_ptr<Item> &it)
{
    if (it->fetching) { it->again = true; return; }
    it->fetching = true;
    it->readAt = m_clock.elapsed();
    QDBusMessage m = QDBusMessage::createMethodCall(it->service, it->path, PROPS, QStringLiteral("GetAll"));
    m << SNI;
    auto *w = new QDBusPendingCallWatcher(QDBusConnection::sessionBus().asyncCall(m, 1000), this);
    std::weak_ptr<Item> weak = it;
    connect(w, &QDBusPendingCallWatcher::finished, this, [this, weak](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        const QDBusPendingReply<QVariantMap> r = *w;
        const auto it = weak.lock();
        if (!it) return;
        if (r.isValid()) { fetched(it, r.value()); return; }
        // gone before we asked (registered and quit at once): the owner watch never saw it go
        if (noOwner(r.error())) { remove(it->key); return; }
        // busy: a failed read for now (no eleven more calls at an app that is not answering)
        if (noAnswer(r.error())) { fetched(it, {}); return; }
        fetchEach(it);      // refused (no GetAll in this implementation): one property at a time
    });
}

// GetAll refused (not every implementation has it): the properties one by one, each one allowed to fail
void Tray::fetchEach(const std::shared_ptr<Item> &it)
{
    static const QStringList names = {"Id", "Title", "Status", "Category", "IconName", "IconPixmap", "AttentionIconName",
                                      "AttentionIconPixmap", "IconThemePath", "Menu", "ItemIsMenu", "ToolTip"};
    struct Acc { qsizetype left; QVariantMap props; };
    auto acc = std::make_shared<Acc>(Acc{names.size(), {}});
    std::weak_ptr<Item> weak = it;
    for (const QString &p : names) {
        QDBusMessage m = QDBusMessage::createMethodCall(it->service, it->path, PROPS, QStringLiteral("Get"));
        m << SNI << p;
        auto *w = new QDBusPendingCallWatcher(QDBusConnection::sessionBus().asyncCall(m, 1000), this);
        connect(w, &QDBusPendingCallWatcher::finished, this, [this, weak, acc, p](QDBusPendingCallWatcher *w) {
            w->deleteLater();
            const QDBusMessage r = w->reply();
            if (r.type() == QDBusMessage::ReplyMessage && !r.arguments().isEmpty()) acc->props[p] = unwrap(r.arguments().first());
            if (--acc->left > 0) return;
            if (const auto it = weak.lock()) fetched(it, acc->props);
        });
    }
}

void Tray::fetched(const std::shared_ptr<Item> &it, const QVariantMap &props)
{
    it->fetching = false;
    // nothing readable (no answer in time, or GetAll and every Get refused while the app is still on the bus): not
    // listed as a tile named after a bus name, the last good reading kept. Never given up: read again 3 s later
    // while the curtain is up, and on every show (an item whose first read failed would otherwise stay missing
    // until the app happened to change something)
    if (props.isEmpty()) {
        it->again = false;
        if (!it->failed) fprintf(stderr, "tray: %s unreadable\n", u8(it->key).constData());
        it->failed = true;
        if (m_open) queue(it, 3000);
        return;
    }
    it->failed = false;
    // missing properties are normal (Electron has no IconName at all)
    auto str = [&](const char *k) { return props.value(QLatin1String(k)).toString(); };
    it->id = str("Id");
    it->title = str("Title");
    it->status = str("Status");
    it->category = str("Category");
    it->iconName = str("IconName");
    it->attnName = str("AttentionIconName");
    it->themePath = str("IconThemePath");
    it->menuPath = objectPath(props.value(QStringLiteral("Menu")));
    it->itemIsMenu = props.value(QStringLiteral("ItemIsMenu")).toBool();
    it->pixmaps = readPixmaps(props.value(QStringLiteral("IconPixmap")));
    it->attnPixmaps = readPixmaps(props.value(QStringLiteral("AttentionIconPixmap")));
    it->tipTitle = toolTipTitle(props.value(QStringLiteral("ToolTip")));
    if (!it->announced) {
        it->announced = true;
        fprintf(stderr, "tray: + %s %s\n", u8(it->key).constData(), u8(it->label()).constData());
    }
    updateIcon(*it);
    if (it->again) {                // changed again while this was read: the next read, a second after this one
        it->again = false;
        if (m_open) queue(it, 0);
    }
    rebuild();
}

void Tray::changed(const std::weak_ptr<Item> &weak)
{
    const auto it = weak.lock();
    if (it && m_open) queue(it, 100);     // closed: its matches are on their way out; the next show reads it
}

// A read of an item, due `delay` ms from now (a burst of signals is one read) and never sooner than a second after
// its last one: an icon that changes all the time (Spectacle's animation while it records, a sync client's spinner)
// is read once a second, its last frame included, instead of every 100 ms
void Tray::queue(const std::shared_ptr<Item> &it, int delay)
{
    if (m_refetch.contains(it->key)) return;
    const qint64 now = m_clock.elapsed();
    m_refetch.insert(it->key, qMax(now + delay, it->readAt < 0 ? now : it->readAt + 1000));
    armRefetch();
}

void Tray::armRefetch()
{
    if (m_refetch.isEmpty()) { m_refetchTimer.stop(); return; }
    qint64 next = std::numeric_limits<qint64>::max();
    for (const qint64 due : std::as_const(m_refetch)) next = qMin(next, due);
    m_refetchTimer.start(int(qBound(qint64(0), next - m_clock.elapsed(), qint64(60000))));
}

void Tray::setOpen(bool open)
{
    if (open == m_open) return;
    m_open = open;
    if (!open) {
        m_refetchTimer.stop();
        m_refetch.clear();
        for (const auto &it : std::as_const(m_items))
            if (it->sig) { it->sig->deleteLater(); it->sig = nullptr; }
        return;
    }
    rerenderIcons();        // the scale may have changed while down (a rotation to another output)
    // a registration or list read that failed against a busy watcher, after the timed retries
    if ((!m_hostOk || !m_listOk) && !m_syncRetry.isActive()) registerHost();
    // the matches first (sent before the reads, on the same connection): a change after them is seen, one before
    // is in the read
    for (const auto &it : std::as_const(m_items)) connectSignals(it);
    for (const auto &it : std::as_const(m_items)) fetch(it);
}

// NeedsAttention shows the attention icon if there is one. A name is looked up in the theme (and the app's own
// IconThemePath); the pixmaps are the fallback, or the icon when there is no name (Electron). Neither: no icon,
// the QML draws the label's first letter. True if the stored icon changed.
bool Tray::updateIcon(Item &it)
{
    const bool attn = it.status == QLatin1String("NeedsAttention") && (!it.attnName.isEmpty() || !it.attnPixmaps.isEmpty());
    const QString name = attn ? it.attnName : it.iconName;
    const QList<QImage> &pix = attn ? it.attnPixmaps : it.pixmaps;
    const int px = iconPx(32);
    size_t h = 0;
    for (const QImage &img : pix) h = qHashMulti(h, img.width(), img.height(), qHashBits(img.constBits(), img.sizeInBytes()));
    const QString sig = name + QChar(0x1f) + it.themePath + QChar(0x1f) + QString::number(h, 16) + QChar(0x1f) + QString::number(px);
    if (sig == it.iconSig) return false;
    it.iconSig = sig;
    QList<QImage> imgs;
    QString kind;
    const QImage themed = themeImage(name, it.themePath, px);
    if (!themed.isNull()) {
        imgs << themed;
        kind = QStringLiteral("theme ") + name;
    } else if (!pix.isEmpty()) {
        imgs = pix;
        kind = QStringLiteral("pixmap %1x%2").arg(pix.first().width()).arg(pix.first().height());
    } else {
        kind = QStringLiteral("none");
    }
    {
        QMutexLocker l(&m_store->lock);
        m_store->images.insert(QString::number(it.n), imgs);
    }
    it.hasIcon = !imgs.isEmpty();
    ++it.rev;
    // a line when the icon's source changes, not for every frame of an animated pixmap (same kind, same size)
    if (kind != it.iconLog) {
        it.iconLog = kind;
        fprintf(stderr, "tray: icon %s %s\n", u8(it.key).constData(), u8(kind).constData());
    }
    return true;
}

void Tray::rerenderIcons()
{
    bool any = false;
    for (const auto &it : std::as_const(m_items))
        if (it->announced && updateIcon(*it)) any = true;
    if (any) rebuild();
}

void Tray::rebuild()
{
    QVariantList list;
    QStringList keys;
    QHash<QString, int> seen;
    for (const auto &it : std::as_const(m_items)) {
        if (!it->announced || it->status == QLatin1String("Passive")) continue;
        // two items of one name (two Claude desktop instances on the tablet, 10-23) are numbered in registration
        // order, the menu page's title too: the owner can tell whose 「退出」 they are about to press
        const QString l = it->label();
        const int nth = ++seen[l];
        it->shown = nth > 1 ? QStringLiteral("%1 %2").arg(l).arg(nth) : l;
        QVariantMap m;
        m[QStringLiteral("key")] = it->key;
        m[QStringLiteral("label")] = it->shown;
        m[QStringLiteral("icon")] = it->hasIcon ? QStringLiteral("image://sni/%1/%2").arg(it->n).arg(it->rev) : QString();
        m[QStringLiteral("attention")] = it->status == QLatin1String("NeedsAttention");
        m[QStringLiteral("hasMenu")] = it->hasMenu();
        m[QStringLiteral("itemIsMenu")] = it->itemIsMenu;
        m[QStringLiteral("category")] = it->category;
        keys << it->key;
        list << m;
    }
    const bool newList = list != m_list, newKeys = keys != m_keys;
    m_list = list;
    m_keys = keys;
    // the items first: tiles made for a new key list read the new items
    if (newList) Q_EMIT itemsChanged();
    if (newKeys) Q_EMIT keysChanged();
}

// ---------------------------------------------------------------- activate

void Tray::activate(const QString &key, int x, int y)
{
    const auto it = find(key);
    if (!it) { Q_EMIT activateDone(key, false, false, QStringLiteral("gone")); return; }
    if (it->itemIsMenu) { Q_EMIT wantMenu(key); return; }      // the spec: such an item only has its menu
    const QString service = it->service, path = it->path;
    auto send = [this, key, service, path, x, y](const QString &token) {
        fprintf(stderr, "tray: token %s %s\n", u8(key).constData(), token.isEmpty() ? "no" : "yes");
        QDBusConnection bus = QDBusConnection::sessionBus();
        // the token lets the app's window come up focused (KWin's focus stealing prevention). Errors ignored: fcitx
        // and Electron do not have the method. Same connection as the Activate after it, so it arrives first.
        if (!token.isEmpty()) {
            QDBusMessage t = QDBusMessage::createMethodCall(service, path, SNI, QStringLiteral("ProvideXdgActivationToken"));
            t << token;
            bus.send(t);
        }
        QDBusMessage a = QDBusMessage::createMethodCall(service, path, SNI, QStringLiteral("Activate"));
        a << x << y;
        auto *w = new QDBusPendingCallWatcher(bus.asyncCall(a, 1000), this);
        connect(w, &QDBusPendingCallWatcher::finished, this, [this, key](QDBusPendingCallWatcher *w) {
            w->deleteLater();
            const bool ok = !w->isError();
            const QDBusError e = w->error();
            QString reason;
            if (ok) {
                fprintf(stderr, "tray: activate %s -> ok\n", u8(key).constData());
            } else if (noAnswer(e)) {
                reason = QStringLiteral("timeout");
                fprintf(stderr, "tray: activate %s -> timeout\n", u8(key).constData());
            } else {
                reason = noOwner(e) ? QStringLiteral("gone") : QStringLiteral("error");
                fprintf(stderr, "tray: activate %s -> error %s\n", u8(key).constData(), u8(e.name()).constData());
            }
            const auto it = find(key);
            if (!ok && !it) reason = QStringLiteral("gone");
            Q_EMIT activateDone(key, ok, it && it->hasMenu(), reason);
        });
    };
    if (!m_window) { send(QString()); return; }
    // as linux/dock/y700-shellbar/src/apps.cpp: KWin answers at once, the timer only covers a lost answer
    auto *fw = new QFutureWatcher<QString>(this);
    auto done = std::make_shared<bool>(false);
    auto go = [fw, done, send](const QString &token) {
        if (*done) return;
        *done = true;
        send(token);
        fw->deleteLater();
    };
    connect(fw, &QFutureWatcher<QString>::finished, this, [fw, go] { go(fw->future().isValid() && fw->future().resultCount() ? fw->future().result() : QString()); });
    QTimer::singleShot(500, this, [go] { go(QString()); });
    fw->setFuture(KWaylandExtras::xdgActivationToken(m_window, QStringLiteral("y700-control-center")));
}

// ---------------------------------------------------------------- menus (com.canonical.dbusmenu)

void Tray::sendEvent(int id, const char *event)
{
    // libdbusmenu's events: "opened" / "closed" around a menu being up, "clicked" for an entry (fcitx fills some
    // entries when its menu opens). No reply wanted.
    QDBusMessage m = QDBusMessage::createMethodCall(m_menuService, m_menuPath, DBUSMENU, QStringLiteral("Event"));
    m << id << QString::fromLatin1(event) << QVariant::fromValue(QDBusVariant(QVariant(int(0)))) << uint(0);
    QDBusConnection::sessionBus().send(m);
}

// the shown level: the contract's line, and its labels (separators "-", an entry with an icon "*", a submenu ">")
void Tray::logLevel()
{
    fprintf(stderr, "tray: menu %s %d rows depth %d\n", u8(m_menuKey).constData(), int(menu().size()), menuDepth());
    QStringList parts;
    for (const QVariant &v : menu()) {
        const QVariantMap r = v.toMap();
        if (r.value(QStringLiteral("separator")).toBool()) { parts << QStringLiteral("-"); continue; }
        parts << (r.value(QStringLiteral("icon")).toString().isEmpty() ? QString() : QStringLiteral("*"))
                     + r.value(QStringLiteral("label")).toString() + (r.value(QStringLiteral("submenu")).toBool() ? QStringLiteral(">") : QString());
    }
    fprintf(stderr, "tray: labels %s %d %s :: %s\n", u8(m_menuKey).constData(), menuDepth(), u8(menuTitle()).constData(),
            u8(parts.join('|')).constData());
}

void Tray::openMenu(const QString &key)
{
    const auto it = find(key);
    if (!it) return;
    if (!m_menuKey.isEmpty()) endMenu(true);    // another one was open: closed quietly, the page stays
    m_menuKey = key;
    m_menuService = it->service;
    m_menuPath = it->menuPath;
    m_menuThemePath = it->themePath;
    m_levels = {Level{0, it->shown.isEmpty() ? it->label() : it->shown, {}}};
    m_menuFailed = false;
    if (!it->hasMenu()) {
        m_menuLoading = false;
        logLevel();
        Q_EMIT menuChanged();
        Q_EMIT menuStateChanged();
        return;
    }
    m_menuLoading = true;
    // while it is open the app may change it (fcitx after AboutToShow, an Electron app's status line): read the shown level
    // again. Only GetLayout then, never AboutToShow (that makes fcitx update its layout: a loop)
    m_menuSig = new TraySignals([this] { if (!m_menuRefresh.isActive()) m_menuRefresh.start(); }, this);
    QDBusConnection bus = QDBusConnection::sessionBus();
    bus.connect(m_menuService, m_menuPath, DBUSMENU, QStringLiteral("LayoutUpdated"), m_menuSig, SLOT(fire(QDBusMessage)));
    bus.connect(m_menuService, m_menuPath, DBUSMENU, QStringLiteral("ItemsPropertiesUpdated"), m_menuSig, SLOT(fire(QDBusMessage)));
    Q_EMIT menuChanged();
    Q_EMIT menuStateChanged();
    loadLevel(0, true, Load::Open, QString());
}

void Tray::menuEnter(int id)
{
    if (m_menuKey.isEmpty() || m_levels.isEmpty()) return;
    QString title;
    for (const QVariant &r : std::as_const(m_levels.last().rows))
        if (r.toMap().value(QStringLiteral("id")).toInt() == id) title = r.toMap().value(QStringLiteral("label")).toString();
    if (m_pendingEnter >= 0) sendEvent(m_pendingEnter, "closed");    // another submenu was still being read
    ++m_nav;
    m_pendingEnter = id;
    m_menuLoading = true;
    Q_EMIT menuStateChanged();     // the rows stay (and the entry dims) until the submenu is in
    loadLevel(id, true, Load::Enter, title);
}

bool Tray::menuBack()
{
    if (m_menuKey.isEmpty()) return false;
    if (m_pendingEnter >= 0) {      // a submenu still being read: given up
        sendEvent(m_pendingEnter, "closed");
        m_pendingEnter = -1;
        m_menuLoading = false;
        ++m_nav;
        Q_EMIT menuStateChanged();
    }
    if (m_levels.size() <= 1) return false;
    sendEvent(m_levels.takeLast().id, "closed");
    ++m_nav;
    logLevel();
    Q_EMIT menuChanged();
    // the level kept from before; it may have changed while the submenu was up
    loadLevel(m_levels.last().id, false, Load::Refresh, QString());
    return true;
}

void Tray::menuClick(int id)
{
    if (m_menuKey.isEmpty() || m_levels.isEmpty()) return;
    QVariantMap row;
    for (const QVariant &r : std::as_const(m_levels.last().rows))
        if (r.toMap().value(QStringLiteral("id")).toInt() == id) row = r.toMap();
    if (row.isEmpty() || row.value(QStringLiteral("separator")).toBool() || !row.value(QStringLiteral("enabled")).toBool()) return;
    if (row.value(QStringLiteral("submenu")).toBool()) { menuEnter(id); return; }
    sendEvent(id, "clicked");
    fprintf(stderr, "tray: click %s %d\n", u8(m_menuKey).constData(), id);
    Q_EMIT menuClicked();
}

void Tray::closeMenu()
{
    if (m_menuKey.isEmpty()) return;
    endMenu(true);
    Q_EMIT menuChanged();
    Q_EMIT menuStateChanged();
}

// events = the app is still there: tell it the menu (and every submenu still open) closed, innermost first
void Tray::endMenu(bool events)
{
    if (events && !m_menuService.isEmpty() && !m_menuPath.isEmpty() && m_menuSig) {
        if (m_pendingEnter >= 0) sendEvent(m_pendingEnter, "closed");
        for (qsizetype i = m_levels.size() - 1; i >= 0; --i) sendEvent(m_levels[i].id, "closed");
    }
    if (m_menuSig) { m_menuSig->deleteLater(); m_menuSig = nullptr; }
    m_menuRefresh.stop();
    m_menuKey.clear();
    m_menuService.clear();
    m_menuPath.clear();
    m_menuThemePath.clear();
    m_levels.clear();
    m_menuLoading = false;
    m_menuFailed = false;
    m_pendingEnter = -1;
    ++m_menuSession;
    ++m_nav;
    // the menu's icons go with it: an app that puts new icon-data in every layout (a cover, an avatar) would
    // otherwise pile them up for the life of the process, and a name not found stays unknown only until next time
    QMutexLocker l(&m_store->lock);
    for (auto i = m_store->images.begin(); i != m_store->images.end();) {
        if (i.key().startsWith(QLatin1String("theme/")) || i.key().startsWith(QLatin1String("data/"))) i = m_store->images.erase(i);
        else ++i;
    }
}

// AboutToShow(id) first when a menu or submenu opens (fcitx fills parts of its menu then; libdbusmenu-qt does the
// same), then GetLayout of that level once it has answered (or failed: not every app has it). Replies for a menu
// closed since, or a navigation overtaken by another, are dropped.
void Tray::loadLevel(int id, bool aboutToShow, Load kind, const QString &title)
{
    const int session = m_menuSession, nav = m_nav;
    auto getLayout = [this, id, kind, title, session, nav] {
        if (session != m_menuSession || nav != m_nav) return;     // closed, or left (back) while AboutToShow ran
        QDBusMessage m = QDBusMessage::createMethodCall(m_menuService, m_menuPath, DBUSMENU, QStringLiteral("GetLayout"));
        m << id << -1 << QStringList();
        auto *w = new QDBusPendingCallWatcher(QDBusConnection::sessionBus().asyncCall(m, 1000), this);
        connect(w, &QDBusPendingCallWatcher::finished, this, [this, id, kind, title, session, nav](QDBusPendingCallWatcher *w) {
            w->deleteLater();
            if (session != m_menuSession || nav != m_nav || m_levels.isEmpty()) return;
            QString err;
            const QVariantList rows = rowsFrom(w->reply(), id, &err);
            if (!err.isEmpty()) fprintf(stderr, "tray: menu %s level %d unreadable (%s)\n", u8(m_menuKey).constData(), id, u8(err).constData());
            if (kind == Load::Refresh) {
                // a level that failed to open and answers now (LayoutUpdated) is a menu after all
                if (m_levels.last().id != id || !err.isEmpty() || (rows == m_levels.last().rows && !m_menuFailed)) return;
                m_levels.last().rows = rows;
                if (m_menuFailed) { m_menuFailed = false; Q_EMIT menuStateChanged(); }
                Q_EMIT menuChanged();
                return;
            }
            if (kind == Load::Open) {
                m_levels.last().rows = rows;        // unreadable: empty, and the page says the app did not answer
                m_menuLoading = false;
                m_menuFailed = !err.isEmpty();
            } else {
                m_pendingEnter = -1;
                m_menuLoading = false;
                if (!err.isEmpty()) {               // stays where it was
                    sendEvent(id, "closed");
                    Q_EMIT menuStateChanged();
                    return;
                }
                m_levels.append(Level{id, title, rows});
            }
            logLevel();
            Q_EMIT menuChanged();
            Q_EMIT menuStateChanged();
        });
    };
    if (!aboutToShow) { getLayout(); return; }
    QDBusMessage m = QDBusMessage::createMethodCall(m_menuService, m_menuPath, DBUSMENU, QStringLiteral("AboutToShow"));
    m << id;
    auto *w = new QDBusPendingCallWatcher(QDBusConnection::sessionBus().asyncCall(m, 1000), this);
    connect(w, &QDBusPendingCallWatcher::finished, this, [getLayout](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        getLayout();
    });
    sendEvent(id, "opened");
}

namespace {
struct MenuNode
{
    int id = 0;
    QVariantMap props;
    QList<MenuNode> children;
};
}

// (ia{sv}av): id, properties, children - each child a variant holding the same structure. Read by hand: QtDBus
// has no type for the recursion. Deeper than 8 levels is not read (each child is its own argument, so skipping
// one leaves the rest of the stream intact).
static void readNode(const QDBusArgument &a, MenuNode &n, int depth)
{
    a.beginStructure();
    a >> n.id >> n.props;
    a.beginArray();
    while (!a.atEnd()) {
        QDBusVariant v;
        a >> v;
        const QVariant cv = v.variant();
        if (depth >= 8 || cv.userType() != qMetaTypeId<QDBusArgument>()) continue;
        const QDBusArgument ca = cv.value<QDBusArgument>();
        if (ca.currentSignature() != QLatin1String("(ia{sv}av)")) continue;
        MenuNode c;
        readNode(ca, c, depth + 1);
        n.children << c;
    }
    a.endArray();
    a.endStructure();
}

// "_File" -> "File", "a__b" -> "a_b" (the spec's mnemonic marks)
static QString stripMnemonic(const QString &s)
{
    QString out;
    out.reserve(s.size());
    for (qsizetype i = 0; i < s.size(); ++i) {
        if (s[i] == '_') {
            if (i + 1 < s.size() && s[i + 1] == '_') { out += '_'; ++i; }
            continue;
        }
        out += s[i];
    }
    return out;
}

// GetLayout's reply (u(ia{sv}av)) -> the rows of level `id` (the returned node is that level, its children the rows)
QVariantList Tray::rowsFrom(const QDBusMessage &reply, int id, QString *err)
{
    if (reply.type() != QDBusMessage::ReplyMessage) { *err = reply.errorName(); return {}; }
    if (reply.signature() != QLatin1String("u(ia{sv}av)") || reply.arguments().size() < 2) { *err = "signature " + reply.signature(); return {}; }
    MenuNode root;
    readNode(reply.arguments().at(1).value<QDBusArgument>(), root, 0);
    if (root.id != id) { *err = QStringLiteral("asked for %1, got %2").arg(id).arg(root.id); return {}; }
    QVariantList rows;
    bool lastSep = true;            // a separator first, after another or last is dropped
    for (const MenuNode &c : std::as_const(root.children)) {
        const QVariantMap &p = c.props;
        if (!p.value(QStringLiteral("visible"), true).toBool()) continue;
        const bool sep = p.value(QStringLiteral("type")).toString() == QLatin1String("separator");
        if (sep && lastSep) continue;
        lastSep = sep;
        QVariantMap r;
        r[QStringLiteral("id")] = c.id;
        r[QStringLiteral("separator")] = sep;
        r[QStringLiteral("label")] = sep ? QString() : stripMnemonic(p.value(QStringLiteral("label")).toString());
        r[QStringLiteral("enabled")] = !sep && p.value(QStringLiteral("enabled"), true).toBool();
        const QString toggle = p.value(QStringLiteral("toggle-type")).toString();
        r[QStringLiteral("toggle")] = toggle == QLatin1String("checkmark") || toggle == QLatin1String("radio") ? toggle : QString();
        r[QStringLiteral("checked")] = p.value(QStringLiteral("toggle-state"), -1).toInt() == 1;
        r[QStringLiteral("submenu")] = !sep && (p.value(QStringLiteral("children-display")).toString() == QLatin1String("submenu") || !c.children.isEmpty());
        QString icon;
        if (!sep) {
            const QString name = p.value(QStringLiteral("icon-name")).toString();
            if (!name.isEmpty()) icon = menuIcon(name, m_menuThemePath);
            if (icon.isEmpty() && p.value(QStringLiteral("icon-data")).userType() == QMetaType::QByteArray)
                icon = dataIcon(p.value(QStringLiteral("icon-data")).toByteArray());
        }
        r[QStringLiteral("icon")] = icon;
        rows << r;
    }
    while (!rows.isEmpty() && rows.last().toMap().value(QStringLiteral("separator")).toBool()) rows.removeLast();
    return rows;
}

// a menu entry's icon-name, rendered here once per open menu (GUI thread) and kept until it closes; a name that is
// not a plain icon name (a file path), or one looked up in an app's own IconThemePath (another app may have its own
// icon of that name), gets a hashed key so the url stays clean. A miss is kept too: the entry just has no icon.
QString Tray::menuIcon(const QString &name, const QString &themePath)
{
    static const QRegularExpression plain(QStringLiteral("^[A-Za-z0-9._+-]+$"));
    const QString key = QStringLiteral("theme/") + (themePath.isEmpty() && plain.match(name).hasMatch()
                                                         ? name : QLatin1Char('h') + QString::number(qHash(themePath + QChar(0x1f) + name), 16));
    bool have = false, known = false;
    {
        QMutexLocker l(&m_store->lock);
        known = m_store->images.contains(key);
        have = known && !m_store->images.value(key).isEmpty();
    }
    if (!known) {
        const QImage img = themeImage(name, themePath, iconPx(22));
        have = !img.isNull();
        QMutexLocker l(&m_store->lock);
        m_store->images.insert(key, have ? QList<QImage>{img} : QList<QImage>());
    }
    return have ? QStringLiteral("image://sni/") + key : QString();
}

// icon-data: PNG bytes (the spec), keyed by their hash
QString Tray::dataIcon(const QByteArray &png)
{
    if (png.isEmpty()) return {};
    const QString key = QStringLiteral("data/") + QString::number(qHash(png), 16);
    bool have = false, known = false;
    {
        QMutexLocker l(&m_store->lock);
        known = m_store->images.contains(key);
        have = known && !m_store->images.value(key).isEmpty();
    }
    if (!known) {
        const QImage img = QImage::fromData(png);
        have = !img.isNull();
        QMutexLocker l(&m_store->lock);
        m_store->images.insert(key, have ? QList<QImage>{img} : QList<QImage>());
    }
    return have ? QStringLiteral("image://sni/") + key : QString();
}
