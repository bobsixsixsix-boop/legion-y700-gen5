// The tray, moved into the control centre (README「Dock 与状态栏」第 4 阶段): a StatusNotifierItem host. The Plasma
// panel went in phase 3 (10-22) and its system tray with it; since then nothing showed the apps' tray icons, and an
// app whose only way back is its icon was out of reach (Spectacle's "stop recording": the owner got stuck in one).
// Here: one entry per registered item for the curtain's 「后台应用」 tiles (tap = the item's Activate, long press =
// the app's own menu, read over com.canonical.dbusmenu and shown as a page of the thumb column), and the "sni" image
// provider for their icons. The watcher stays kded6's (org.kde.StatusNotifierWatcher): we only register as one more
// host next to plasmashell's; hosting a watcher of our own would fight kded and take plasmashell's items away.
#pragma once
#include <QDBusMessage>
#include <QElapsedTimer>
#include <QHash>
#include <QImage>
#include <QList>
#include <QMutex>
#include <QObject>
#include <QPointer>
#include <QQuickImageProvider>
#include <QSet>
#include <QStringList>
#include <QTimer>
#include <QVariantList>
#include <QWindow>
#include <functional>
#include <memory>

class QDBusServiceWatcher;
class QIcon;

// The icons as QImages. Filled on the GUI thread (theme icons are rendered there: QIcon's loaders, Qt's and
// KIconLoader, are not thread-safe), read by TrayImages::requestImage (on the GUI thread for the tiles, which load
// synchronously; on Qt Quick's image loader thread for the menu's): all access under the lock, images copied out
// (QImage is implicitly shared).
struct TrayIconStore
{
    QMutex lock;
    QHash<QString, QList<QImage>> images;   // "<n>" (an item's serial) | "theme/<name>" | "data/<hash>" -> its sizes
};

// image://sni/<n>/<rev> (an item's icon; rev only makes the url new when the icon changes), image://sni/theme/<name>
// and image://sni/data/<hash> (menu entries): the stored image closest to the size asked for, scaled to it
class TrayImages : public QQuickImageProvider
{
public:
    explicit TrayImages(std::shared_ptr<TrayIconStore> store);
    QImage requestImage(const QString &id, QSize *size, const QSize &requestedSize) override;

private:
    std::shared_ptr<TrayIconStore> m_store;
};

// One receiver per item (and one for the open menu) for its D-Bus signals: QtDBus delivers the sender's unique name,
// and an item registered under a well-known one (Electron's org.freedesktop.StatusNotifierItem-<pid>-1) would have
// to be mapped back. A slot with only the QDBusMessage takes any signature; deleting the receiver drops the matches.
class TraySignals : public QObject
{
    Q_OBJECT
public:
    TraySignals(std::function<void()> fn, QObject *parent) : QObject(parent), m_fn(std::move(fn)) {}
public Q_SLOTS:
    void fire(const QDBusMessage &) { m_fn(); }

private:
    std::function<void()> m_fn;
};

class Tray : public QObject
{
    Q_OBJECT
    // [{key, label, icon (url or ""), attention, hasMenu, itemIsMenu, category}] in the watcher's registration order;
    // Passive items are left out, Active and NeedsAttention shown. label: two items of one name are numbered
    Q_PROPERTY(QVariantList items READ items NOTIFY itemsChanged)
    // the shown items' keys, in the same order. Changes only when an item comes, goes, or turns Passive or back, not
    // with its icon or label: the QML's Repeaters are made from this, so a tile lives as long as its item (one made
    // anew under the finger loses the press; an animated icon, Spectacle's while it records, made every tile anew
    // ten times a second and no long press could finish), and reads its item from `items` by key
    Q_PROPERTY(QStringList keys READ keys NOTIFY keysChanged)
    // the open menu's current level: [{id, label, enabled, separator, toggle ("" | "checkmark" | "radio"), checked,
    // submenu, icon (url or "")}]; invisible entries left out, separators collapsed
    Q_PROPERTY(QVariantList menu READ menu NOTIFY menuChanged)
    Q_PROPERTY(QString menuTitle READ menuTitle NOTIFY menuChanged)   // the item's label, a submenu's inside one
    Q_PROPERTY(int menuDepth READ menuDepth NOTIFY menuChanged)       // 0 = the menu's top level
    Q_PROPERTY(QString menuKey READ menuKey NOTIFY menuChanged)       // "" = no menu open
    // the state around the rows (its own signal: the rows' Repeater is not made anew when only this changes)
    Q_PROPERTY(bool menuLoading READ menuLoading NOTIFY menuStateChanged)   // an open or a submenu being read
    Q_PROPERTY(bool menuFailed READ menuFailed NOTIFY menuStateChanged)     // the app did not answer: not "no menu"
    Q_PROPERTY(int menuPending READ menuPending NOTIFY menuStateChanged)    // the submenu entry being read, -1 none
public:
    explicit Tray(QObject *parent = nullptr);
    ~Tray() override;
    void setWindow(QWindow *w);   // the xdg-activation token is asked for this window; its scale sizes the icons
    // The curtain is up: the items' change signals are followed (a burst is one read, an item read at most once a
    // second). While it is down their matches are dropped (an animated icon would wake us on every frame, the screen
    // off) and nothing is read; the next show reads every item. Items coming and going are followed either way.
    void setOpen(bool open);
    QQuickImageProvider *imageProvider() const { return new TrayImages(m_store); }   // the engine owns it
    QVariantList items() const { return m_list; }
    QStringList keys() const { return m_keys; }
    QVariantList menu() const { return m_levels.isEmpty() ? QVariantList() : m_levels.last().rows; }
    QString menuTitle() const { return m_levels.isEmpty() ? QString() : m_levels.last().title; }
    int menuDepth() const { return qMax(0, int(m_levels.size()) - 1); }
    bool menuLoading() const { return m_menuLoading; }
    bool menuFailed() const { return m_menuFailed; }
    int menuPending() const { return m_pendingEnter; }
    QString menuKey() const { return m_menuKey; }

    // a tap on the tile: x, y = its centre in window (= screen) coordinates. ItemIsMenu -> wantMenu(key); else a token
    // for our window, ProvideXdgActivationToken(token) and Activate(x, y); activateDone tells the QML how it went
    Q_INVOKABLE void activate(const QString &key, int x, int y);
    Q_INVOKABLE void openMenu(const QString &key);
    Q_INVOKABLE void menuEnter(int id);        // a submenu entry: its level replaces the shown one
    Q_INVOKABLE bool menuBack();               // one level up; false at the top (the page closes)
    Q_INVOKABLE void menuClick(int id);        // an entry: the app runs it
    Q_INVOKABLE void closeMenu();

Q_SIGNALS:
    void itemsChanged();
    void keysChanged();
    void menuChanged();
    void menuStateChanged();
    void wantMenu(const QString &key);
    // reason: "" (ok) | "timeout" (no answer in 1 s: busy or hung) | "error" (an error reply: no Activate, as
    // ayatana's items) | "gone" (the item or its app went)
    void activateDone(const QString &key, bool ok, bool hasMenu, const QString &reason);
    void menuClicked();

protected:
    bool eventFilter(QObject *o, QEvent *e) override;

private Q_SLOTS:
    void onRegistered(const QString &item);     // org.kde.StatusNotifierWatcher's StatusNotifierItemRegistered
    void onUnregistered(const QString &item);

private:
    struct Item
    {
        QString key, service, path;             // key = the watcher's "service/path"
        int n = 0;                              // serial: the icon's image id
        int rev = 0;                            // bumped with every new icon
        bool announced = false;                 // properties read once ("tray: +" printed): listed from then on
        bool fetching = false, again = false;
        bool failed = false;                    // the last read got nothing (logged once per run of failures)
        qint64 readAt = -1;                     // m_clock when its last read went out
        QString id, title, status, tipTitle, iconName, attnName, themePath, menuPath, category;
        QString shown;                          // the label as listed (a second "Claude" is "Claude 2")
        bool itemIsMenu = false;
        QList<QImage> pixmaps, attnPixmaps;
        QString iconSig;                        // what the stored icon was made from
        QString iconLog;                        // its source as last logged ("theme NAME" | "pixmap WxH" | "none")
        bool hasIcon = false;
        TraySignals *sig = nullptr;             // only while the curtain is up
        bool hasMenu() const;
        QString label() const;
    };
    struct Level
    {
        int id = 0;
        QString title;
        QVariantList rows;
    };
    enum class Load { Open, Enter, Refresh };

    void registerHost();
    void readItems();
    void retrySync();
    void sync(const QStringList &registered);
    void add(const QString &key);
    void remove(const QString &key);
    void clearAll();
    std::shared_ptr<Item> find(const QString &key) const;
    void connectSignals(const std::shared_ptr<Item> &it);
    void fetch(const std::shared_ptr<Item> &it);
    void fetchEach(const std::shared_ptr<Item> &it);
    void fetched(const std::shared_ptr<Item> &it, const QVariantMap &props);
    void changed(const std::weak_ptr<Item> &weak);
    void queue(const std::shared_ptr<Item> &it, int delay);
    void armRefetch();
    qreal iconDpr() const;
    int iconPx(int logical) const;
    QIcon iconFromPath(const QString &name, const QString &themePath);
    QImage themeImage(const QString &name, const QString &themePath, int px);
    bool updateIcon(Item &it);
    void rerenderIcons();
    void rebuild();
    void loadLevel(int id, bool aboutToShow, Load kind, const QString &title);
    void logLevel();
    void endMenu(bool events);
    void sendEvent(int id, const char *event);
    QVariantList rowsFrom(const QDBusMessage &reply, int id, QString *err);
    QString menuIcon(const QString &name, const QString &themePath);
    QString dataIcon(const QByteArray &png);

    std::shared_ptr<TrayIconStore> m_store;
    QPointer<QWindow> m_window;
    bool m_open = false;
    QString m_hostName;
    bool m_hostOk = false, m_listOk = false;         // registered with the watcher / its list read
    int m_retries = 0;
    QTimer m_syncRetry;
    QDBusServiceWatcher *m_watcherWatch = nullptr;   // org.kde.StatusNotifierWatcher (kded6) coming and going
    QDBusServiceWatcher *m_owners = nullptr;         // the items' services: an app that dies takes its items along
    QList<std::shared_ptr<Item>> m_items;            // registration order
    int m_serial = 0;
    QVariantList m_list;
    QStringList m_keys;
    QElapsedTimer m_clock;
    QHash<QString, qint64> m_refetch;                // key -> when (m_clock) its next read is due (only while open)
    QTimer m_refetchTimer;
    QHash<QString, QHash<QString, QStringList>> m_pathIndex;   // IconThemePath -> icon name -> its files
    // the open menu
    QString m_menuKey, m_menuService, m_menuPath, m_menuThemePath;
    QList<Level> m_levels;                           // the top level first; the one shown last
    bool m_menuLoading = false, m_menuFailed = false;
    int m_pendingEnter = -1;                         // a submenu being read (its "opened" was sent)
    int m_menuSession = 0, m_nav = 0;                // replies for a closed menu / an older navigation are dropped
    TraySignals *m_menuSig = nullptr;
    QTimer m_menuRefresh;
};
