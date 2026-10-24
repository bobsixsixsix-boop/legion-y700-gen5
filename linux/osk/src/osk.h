// The keyboard backend the QML sees as `osk`: fcitx5 bridge, window placement (layer shell,
// KWin blur, input region), show/hide, sound, haptics, voice, clipboard history.
// It also stands in for fcitx5-osk towards fcitx5-osk-kwin-launcher (fyi.fortime.Fcitx5Osk),
// so the launcher can start and stop it exactly like the original desktop keyboard.
#pragma once
#include <QDBusVirtualObject>
#include <QObject>
#include <QElapsedTimer>
#include <QPointer>
#include <QStringList>
#include <QVariantList>

class QQuickWindow;
class QTimer;
class Fcitx;
class Sound;
class Haptics;
class Voice;
class Gate;
class Osk;

// fyi.fortime.Fcitx5Osk.Controller1 (what the KWin launcher talks to) + fyi.y700.Osk (our CLI)
class OskBusObject : public QDBusVirtualObject
{
public:
    explicit OskBusObject(Osk *osk) : m_osk(osk) {}
    QString introspect(const QString &path) const override;
    bool handleMessage(const QDBusMessage &message, const QDBusConnection &connection) override;
private:
    Osk *m_osk;
};

class Osk : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool shown READ shown NOTIFY shownChanged)
    Q_PROPERTY(bool zh READ zh NOTIFY imChanged)
    Q_PROPERTY(QString lang READ lang NOTIFY imChanged)               // zh (rime) | en (keyboard-us) | ja (mozc, romaji)
    Q_PROPERTY(int candidateCursor READ candidateCursor NOTIFY compositionChanged)
    Q_PROPERTY(QString preedit READ preedit NOTIFY compositionChanged)
    Q_PROPERTY(QStringList candidates READ candidates NOTIFY compositionChanged)
    Q_PROPERTY(bool hasPrev READ hasPrev NOTIFY compositionChanged)
    Q_PROPERTY(bool hasNext READ hasNext NOTIFY compositionChanged)
    Q_PROPERTY(QObject *voice READ voiceObject CONSTANT)
    Q_PROPERTY(QStringList clipboard READ clipboard NOTIFY clipboardChanged)
    Q_PROPERTY(int screenWidth READ screenWidth NOTIFY screenChanged)
    Q_PROPERTY(int screenHeight READ screenHeight NOTIFY screenChanged)
    Q_PROPERTY(bool commitAvailable READ commitAvailable NOTIFY imChanged)
    Q_PROPERTY(QString previewState READ previewState CONSTANT)
public:
    explicit Osk(QObject *parent = nullptr);
    ~Osk() override;

    bool claimBus();
    void claimPreviewBus();              // --preview: only fyi.y700.OskPreview, for the debug hook (tests)
    void setPreview(const QString &state);
    QString previewState() const { return m_previewState; }
    void setWindow(QQuickWindow *win);

    bool shown() const { return m_shown; }
    bool zh() const;
    QString lang() const;
    int candidateCursor() const { return m_cursor; }
    QString preedit() const { return m_preedit; }
    QStringList candidates() const { return m_candidates; }
    bool hasPrev() const { return m_hasPrev; }
    bool hasNext() const { return m_hasNext; }
    QObject *voiceObject() const;
    QStringList clipboard() const { return m_clipboard; }
    int screenWidth() const;
    int screenHeight() const;
    bool commitAvailable() const;

    // typing
    Q_INVOKABLE void key(const QString &name);
    Q_INVOKABLE void keyCombo(const QString &name, const QStringList &mods);
    Q_INVOKABLE void commit(const QString &text);
    Q_INVOKABLE void selectCandidate(int index);
    // rime sends its whole menu in one bulk list (no paging); mozc pages, and says so with hasPrev/hasNext
    Q_INVOKABLE void nextPage();
    Q_INVOKABLE void prevPage();
    Q_INVOKABLE void setZh(bool zh);
    Q_INVOKABLE void setLang(const QString &lang);
    Q_INVOKABLE void hideKeyboard();     // the user closed it
    Q_INVOKABLE void clearAll();         // 滑至此处清空 (Ctrl+A, BackSpace as real keys, in order)
    // feedback
    Q_INVOKABLE void click(int kind);
    Q_INVOKABLE void haptic(const QString &side, int ms, int magnitude);
    Q_INVOKABLE void setVolume(int level);
    Q_INVOKABLE void setSoundStyle(int style);
    Q_INVOKABLE void setMotorSwap(bool swap);
    // window
    Q_INVOKABLE void setPlacement(bool floating, int x, int y, int w, int h, int exclusive);
    Q_INVOKABLE void setRegions(const QVariantList &rects, bool blur);
    Q_INVOKABLE void hideDone();         // QML finished the slide-out
    // misc
    Q_INVOKABLE void clearClipboard();
    Q_INVOKABLE QStringList graphemes(const QString &s) const;
    Q_INVOKABLE void openSettings();
    Q_INVOKABLE void setDebugState(const QString &s) { m_debugState = s; }
    Q_INVOKABLE void rawHelper(const QString &seq);                        // debug: key-helper sequence "37d,52d,52u,37u"
    Q_INVOKABLE void rawVk(int sym, int code, int state, bool release);    // debug: one VK backend ProcessKeyEvent
    QString debug(const QString &cmd, const QString &arg);   // test hook (fyi.y700.Osk.debug)

public slots:
    void refreshClipboard();

public:
    // launcher / CLI
    void show(bool force, bool fromFcitx = false);
    // fcitx5's ShowVirtualKeyboard and the launcher's Show: focus-driven, so gated (see osk.cpp)
    void showRequest(bool fromFcitx);
    void hide(bool immediate);
    void shutdown();

signals:
    void shownChanged();
    void imChanged();
    void compositionChanged();
    void clipboardChanged();
    void screenChanged();
    void debugCommand(const QString &cmd, const QString &arg);

private slots:
    void readTextInputSupport();

private:
    void applyMotorSide();

    Fcitx *m_fcitx = nullptr;
    Sound *m_sound = nullptr;
    Haptics *m_haptics = nullptr;
    Voice *m_voice = nullptr;
    Gate *m_gate = nullptr;               // the KWin effect's view of taps (created with the real bus)
    bool m_clientTextInput = true;        // KWin: the focused client speaks text-input (false: X11)
    QElapsedTimer m_since;
    qint64 m_ignoredShowAt = -100000;     // m_since ms of the last gated (ignored) focus-driven Show
    OskBusObject *m_busObject = nullptr;
    QPointer<QQuickWindow> m_win;
    QTimer *m_hideTimer = nullptr;
    QTimer *m_soundIdle = nullptr;

    bool m_shown = false;
    bool m_force = false;
    bool m_motorSwap = false;
    QString m_preedit;
    QStringList m_candidates;
    bool m_hasPrev = false, m_hasNext = false;
    int m_cursor = -1;
    QStringList m_clipboard;
    QString m_lastRegionKey;
    QMetaObject::Connection m_scrConn[2];
    QString m_previewState;
    QString m_debugState;
    bool m_preview = false;
};
