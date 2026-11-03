// fcitx5 side of the keyboard (session bus).
//
// We are the UI: own org.fcitx.Fcitx5.VirtualKeyboard and serve
//   /org/fcitx/virtualkeyboard/impanel  org.fcitx.Fcitx5.VirtualKeyboard1
// (Show/HideVirtualKeyboard, UpdateCandidateArea(asbbii), UpdatePreeditArea(s), UpdatePreeditCaret(i),
//  NotifyIMActivated(s), NotifyIMDeactivated(s), NotifyIMListChanged()).
// We call fcitx5:
//   org.fcitx.Fcitx5 /virtualkeyboard org.fcitx.Fcitx.VirtualKeyboard1        Show/HideVirtualKeyboard
//   org.fcitx.Fcitx5 /virtualkeyboard org.fcitx.Fcitx5.VirtualKeyboardBackend1 ProcessKeyEvent(uuubu), SelectCandidate(i)
//   org.fcitx.Fcitx5 /controller      org.fcitx.Fcitx.Controller1              SetCurrentIM(s), CurrentInputMethod()
//   org.fcitx.Fcitx5 /y700osk         fyi.y700.OskCommit1                      CommitString(s) (our addon)
// and, for real key presses fcitx5 cannot forward (Ctrl/Shift combos, X11 apps), the root
// key-helper on the system bus (fyi.fortime.Fcitx5OskKeyHelper.Controller1, serial-chained).
//
// Every outgoing call is asynchronous and sent in order on one connection, so typing never
// blocks the UI and keys arrive in the order they were pressed.
#pragma once
#include <QDBusAbstractAdaptor>
#include <QElapsedTimer>
#include <QObject>
#include <QStringList>

class Fcitx;

class ImPanelAdaptor : public QDBusAbstractAdaptor
{
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.fcitx.Fcitx5.VirtualKeyboard1")
public:
    explicit ImPanelAdaptor(Fcitx *parent);
public slots:
    Q_NOREPLY void ShowVirtualKeyboard();
    Q_NOREPLY void HideVirtualKeyboard();
    Q_NOREPLY void UpdateCandidateArea(const QStringList &candidates, bool hasPrev, bool hasNext, int pageIndex, int cursorIndex);
    Q_NOREPLY void UpdatePreeditArea(const QString &text);
    Q_NOREPLY void UpdatePreeditCaret(int caret);
    Q_NOREPLY void NotifyIMActivated(const QString &im);
    Q_NOREPLY void NotifyIMDeactivated(const QString &im);
    Q_NOREPLY void NotifyIMListChanged();
private:
    Fcitx *m_f;
};

class Fcitx : public QObject
{
    Q_OBJECT
public:
    explicit Fcitx(QObject *parent = nullptr);

    bool registerUi();                    // claim org.fcitx.Fcitx5.VirtualKeyboard (AllowReplacement)
    void releaseUi();

    // keys: name = X keysym name ("a", "A", "BackSpace", "Return", "space", "comma"...)
    void key(const QString &name);
    // a combination with modifiers ("Control", "Shift", "Alt"): goes out as real keys via key-helper
    void keyCombo(const QString &name, const QStringList &mods);
    void commit(const QString &text);
    void selectCandidate(int index);
    void selectCandidateBackend(int index);   // fcitx5's own SelectCandidate (page-local for Mozc, global for rime)
    void page(bool next);                 // mozc's paged candidate list (NextPage/PrevPage take no arguments)
    void setCurrentIM(const QString &im, bool remember = true);   // remember: the owner's own 中/英 switch
    void imActivated(const QString &im);                          // fcitx5's NotifyIMActivated
    void restoreIMIfNeeded();                                     // once per fcitx5 run: switch to the remembered IM
    void requestShow();                   // tell fcitx5 the on-screen keyboard is up (OnScreenKeyboard mode)
    void requestHide();                   // user closed the keyboard
    void enterOnScreenMode();             // OnScreenKeyboard mode without the keyboard: swallow fcitx5's Show back
    void clearAll();                      // 滑至此处清空: Ctrl+A, BackSpace on ONE ordered path (key-helper)
    void clearComposition();              // drop rime's pinyin (Escape through the VK backend)
    // debug hook experiments (tests/combo-probe.sh): one raw key-helper sequence "37d,52d,52u,37u", one VK backend event
    void rawHelper(const QString &seq);
    void rawKey(quint32 sym, quint32 code, quint32 state, bool release) { processKey(sym, code, state, release); }
    void setClientWithoutTextInput(bool x11) { m_noTextInput = x11; }
    bool inputFocused() { return icFocused(); }   // fcitx5 has a focused input context (needs the addon)
    bool commitAvailable() const { return m_commitOk; }
    QString currentIM() const { return m_im; }

signals:
    void showRequested();
    void hideRequested();
    void echoHideSwallowed();             // a Hide taken for key-helper's echo: it may have been a real FocusOut too
    void candidatesChanged(const QStringList &list, bool hasPrev, bool hasNext, int cursor);
    void preeditChanged(const QString &text);
    void imChanged(const QString &im);
    void nameLost();
    void restarted();                     // fcitx5 (re)appeared on the bus, in physical-keyboard mode

private:
    friend class ImPanelAdaptor;
    void processKey(quint32 sym, quint32 code, quint32 state, bool release);
    bool helperKeys(const QList<QPair<quint16, bool>> &seq);
    void realKey(quint16 code, bool shift);   // a real key (with Shift) through key-helper
    void stagedCombo(const QList<QPair<quint16, bool>> &down, const QList<quint16> &codes,
                     const QList<QPair<quint16, bool>> &up, const QStringList &after);
    bool icFocused();                         // does fcitx5 have a focused input context (addon HasFocus)
    static QString charKeyName(QChar c);
    void probeCommit();
    void queryIM();
    bool inHelperEcho() const { return m_helperClock.isValid() && m_helperClock.elapsed() < 450; }
    bool takeModeEcho();                  // the one Show fcitx5 answers enterOnScreenMode() with

    QString m_im;
    QString m_rememberedIM;               // last IM the owner picked (QSettings im/last), restored after fcitx5 restarts
    bool m_restored = false;              // the first activation since fcitx5 (re)started has been checked
    bool m_commitOk = false;
    bool m_noTextInput = false;
    quint64 m_serial = 0;
    bool m_serialOk = false;
    QElapsedTimer m_helperClock;          // fcitx5 sends Hide after a real key: ignore it shortly after ours
    QElapsedTimer m_modeClock;            // enterOnScreenMode() asked: its Show is not for a field
};
