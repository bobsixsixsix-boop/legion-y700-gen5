#include "fcitx.h"

#include <QDBusConnection>
#include <QDBusConnectionInterface>
#include <QDBusMessage>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QDBusServiceWatcher>
#include <QDateTime>
#include <QDebug>
#include <QHash>
#include <QSettings>
#include <QTimer>

namespace {
const QString FCITX = QStringLiteral("org.fcitx.Fcitx5");
const QString VK_PATH = QStringLiteral("/virtualkeyboard");
const QString HELPER = QStringLiteral("fyi.fortime.Fcitx5OskKeyHelper");
const QString HELPER_PATH = QStringLiteral("/fyi/fortime/Fcitx5OskKeyHelper/Controller");
const QString HELPER_IF = QStringLiteral("fyi.fortime.Fcitx5OskKeyHelper.Controller1");
constexpr int MAX_CANDIDATES = 300;     // rime pushes its whole (unbounded) menu; draw the useful head

struct K { quint32 sym; quint16 code; };   // code = X11 keycode (evdev + 8), 0 = none
const QHash<QString, K> &keyTable()
{
    static const QHash<QString, K> t = [] {
        QHash<QString, K> h;
        const char *row = "qwertyuiopasdfghjklzxcvbnm";
        const quint16 codes[] = { 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 38, 39, 40, 41, 42, 43, 44, 45, 46, 52, 53, 54, 55, 56, 57, 58 };
        for (int i = 0; i < 26; ++i) {
            h.insert(QString(QLatin1Char(row[i])), { quint32(row[i]), codes[i] });
            h.insert(QString(QLatin1Char(row[i])).toUpper(), { quint32(row[i] - 32), codes[i] });
        }
        for (int d = 1; d <= 9; ++d) h.insert(QString::number(d), { quint32('0' + d), quint16(9 + d) });
        h.insert(QStringLiteral("0"), { '0', 19 });
        h.insert(QStringLiteral("space"), { 0x20, 65 });
        h.insert(QStringLiteral("comma"), { 0x2c, 59 });
        h.insert(QStringLiteral("period"), { 0x2e, 60 });
        h.insert(QStringLiteral("apostrophe"), { 0x27, 48 });
        h.insert(QStringLiteral("slash"), { 0x2f, 61 });
        h.insert(QStringLiteral("minus"), { 0x2d, 20 });
        h.insert(QStringLiteral("equal"), { 0x3d, 21 });
        h.insert(QStringLiteral("semicolon"), { 0x3b, 47 });
        h.insert(QStringLiteral("at"), { 0x40, 0 });
        h.insert(QStringLiteral("BackSpace"), { 0xff08, 22 });
        h.insert(QStringLiteral("Tab"), { 0xff09, 23 });
        h.insert(QStringLiteral("Return"), { 0xff0d, 36 });
        h.insert(QStringLiteral("Escape"), { 0xff1b, 9 });
        h.insert(QStringLiteral("Home"), { 0xff50, 110 });
        h.insert(QStringLiteral("Left"), { 0xff51, 113 });
        h.insert(QStringLiteral("Up"), { 0xff52, 111 });
        h.insert(QStringLiteral("Right"), { 0xff53, 114 });
        h.insert(QStringLiteral("Down"), { 0xff54, 116 });
        h.insert(QStringLiteral("Page_Up"), { 0xff55, 112 });
        h.insert(QStringLiteral("Page_Down"), { 0xff56, 117 });
        h.insert(QStringLiteral("End"), { 0xff57, 115 });
        h.insert(QStringLiteral("Delete"), { 0xffff, 119 });
        h.insert(QStringLiteral("Shift"), { 0xffe1, 50 });
        h.insert(QStringLiteral("Control"), { 0xffe3, 37 });
        h.insert(QStringLiteral("Alt"), { 0xffe9, 64 });
        return h;
    }();
    return t;
}
bool isEditingKey(const QString &n)
{
    static const QStringList keys = { QStringLiteral("BackSpace"), QStringLiteral("Return"), QStringLiteral("Tab"), QStringLiteral("Escape"),
        QStringLiteral("Left"), QStringLiteral("Right"), QStringLiteral("Up"), QStringLiteral("Down"), QStringLiteral("Home"),
        QStringLiteral("End"), QStringLiteral("Delete"), QStringLiteral("Page_Up"), QStringLiteral("Page_Down") };
    return keys.contains(n);
}
quint32 now32() { return quint32(QDateTime::currentMSecsSinceEpoch() & 0xffffffffu); }
} // namespace

// ---------------- adaptor (fcitx5 -> us) ----------------
ImPanelAdaptor::ImPanelAdaptor(Fcitx *parent) : QDBusAbstractAdaptor(parent), m_f(parent) {}

void ImPanelAdaptor::ShowVirtualKeyboard()
{
    if (m_f->takeModeEcho()) return;
    emit m_f->showRequested();
}
void ImPanelAdaptor::HideVirtualKeyboard()
{
    // a real key from key-helper flips fcitx5 to physical-keyboard mode, which sends Hide:
    // that one is ours, so re-assert the on-screen mode instead of hiding
    if (m_f->inHelperEcho()) {
        emit m_f->echoHideSwallowed();
        QTimer::singleShot(30, m_f, &Fcitx::requestShow);
        return;
    }
    emit m_f->hideRequested();
}
void ImPanelAdaptor::UpdateCandidateArea(const QStringList &c, bool hasPrev, bool hasNext, int, int cursorIndex)
{
    emit m_f->candidatesChanged(c.size() > MAX_CANDIDATES ? c.mid(0, MAX_CANDIDATES) : c, hasPrev, hasNext, cursorIndex);
}
void ImPanelAdaptor::UpdatePreeditArea(const QString &t) { emit m_f->preeditChanged(t); }
void ImPanelAdaptor::UpdatePreeditCaret(int) {}
void ImPanelAdaptor::NotifyIMActivated(const QString &im) { m_f->imActivated(im); }
void ImPanelAdaptor::NotifyIMDeactivated(const QString &) {}
void ImPanelAdaptor::NotifyIMListChanged() { m_f->queryIM(); }

// ---------------- Fcitx ----------------
Fcitx::Fcitx(QObject *parent) : QObject(parent)
{
    new ImPanelAdaptor(this);
    auto *w = new QDBusServiceWatcher(FCITX, QDBusConnection::sessionBus(), QDBusServiceWatcher::WatchForRegistration, this);
    connect(w, &QDBusServiceWatcher::serviceRegistered, this, [this] {
        // fcitx5 (re)started: our addon may have appeared, the IM state is new (and back to English)
        m_restored = false;
        QTimer::singleShot(400, this, [this] { probeCommit(); queryIM(); });
        QTimer::singleShot(1000, this, &Fcitx::restarted);   // its UI addons are up by then
    });
    m_rememberedIM = QSettings().value(QStringLiteral("im/last")).toString();
    probeCommit();
    queryIM();
}

bool Fcitx::registerUi()
{
    auto bus = QDBusConnection::sessionBus();
    if (!bus.registerObject(QStringLiteral("/org/fcitx/virtualkeyboard/impanel"), this, QDBusConnection::ExportAdaptors)) return false;
    // AllowReplacement: at screen lock the lock-screen keyboard (fcitx5-osk) takes this name over
    const auto r = bus.interface()->registerService(QStringLiteral("org.fcitx.Fcitx5.VirtualKeyboard"),
                                                    QDBusConnectionInterface::DontQueueService,
                                                    QDBusConnectionInterface::AllowReplacement);
    if (!r.isValid() || r.value() != QDBusConnectionInterface::ServiceRegistered) {
        qWarning() << "fcitx: org.fcitx.Fcitx5.VirtualKeyboard is taken";
        return false;
    }
    // QDBusConnectionInterface turns the bus's NameLost for our own names into serviceUnregistered
    connect(bus.interface(), &QDBusConnectionInterface::serviceUnregistered, this, [this](const QString &name) {
        if (name == QLatin1String("org.fcitx.Fcitx5.VirtualKeyboard")) emit nameLost();
    });
    return true;
}

void Fcitx::releaseUi()
{
    auto bus = QDBusConnection::sessionBus();
    bus.interface()->unregisterService(QStringLiteral("org.fcitx.Fcitx5.VirtualKeyboard"));
    bus.unregisterObject(QStringLiteral("/org/fcitx/virtualkeyboard/impanel"));
}

void Fcitx::requestShow()
{
    auto m = QDBusMessage::createMethodCall(FCITX, VK_PATH, QStringLiteral("org.fcitx.Fcitx.VirtualKeyboard1"), QStringLiteral("ShowVirtualKeyboard"));
    QDBusConnection::sessionBus().asyncCall(m);
}

// fcitx5 sends Show/Hide on focus changes only in OnScreenKeyboard mode, and it is in physical-keyboard
// mode when it starts and after this keyboard (re)started (2026-10-30: Steam's fields sent it FocusIn and
// we heard nothing). requestShow() switches it, and every show() makes that call - but only Wayland
// clients get the keyboard shown without fcitx5 (the gate's taps, the launcher), so a Steam field could
// not bring it up until a Wayland field had. Switch now; fcitx5 answers with a Show that is ours.
void Fcitx::enterOnScreenMode()
{
    m_modeClock.start();
    requestShow();
}

bool Fcitx::takeModeEcho()
{
    if (!m_modeClock.isValid()) return false;
    const bool echo = m_modeClock.elapsed() < 300;
    m_modeClock.invalidate();               // one Show per request: a later one is for a field
    return echo;
}

void Fcitx::requestHide()
{
    m_helperClock.invalidate();   // our own close: the Hide fcitx5 sends back is real, not a key-helper echo
    if (m_serialOk) {   // release anything key-helper might still hold
        auto r = QDBusMessage::createMethodCall(HELPER, HELPER_PATH, HELPER_IF, QStringLiteral("ResetSerial"));
        QDBusConnection::systemBus().asyncCall(r);
        m_serialOk = false;
    }
    auto m = QDBusMessage::createMethodCall(FCITX, VK_PATH, QStringLiteral("org.fcitx.Fcitx.VirtualKeyboard1"), QStringLiteral("HideVirtualKeyboard"));
    QDBusConnection::sessionBus().asyncCall(m);
}

void Fcitx::processKey(quint32 sym, quint32 code, quint32 state, bool release)
{
    if (sym == 0 && code == 0) return;      // fcitx5 5.1.19 dereferences a null event for this
    // right after a key-helper key fcitx5 may be in physical mode with the backend object gone;
    // a Show sent first on this same connection is handled first and resumes it synchronously
    if (inHelperEcho()) requestShow();
    auto m = QDBusMessage::createMethodCall(FCITX, VK_PATH, QStringLiteral("org.fcitx.Fcitx5.VirtualKeyboardBackend1"), QStringLiteral("ProcessKeyEvent"));
    m << sym << code << state << release << now32();
    auto *w = new QDBusPendingCallWatcher(QDBusConnection::sessionBus().asyncCall(m), this);
    connect(w, &QDBusPendingCallWatcher::finished, this, [this, sym, code, state, release](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        if (!w->isError()) return;
        // the backend object only exists in on-screen mode: re-enter it and resend at once (in order)
        qWarning() << "fcitx: ProcessKeyEvent failed:" << w->error().name() << "- re-entering on-screen mode";
        requestShow();
        auto m2 = QDBusMessage::createMethodCall(FCITX, VK_PATH, QStringLiteral("org.fcitx.Fcitx5.VirtualKeyboardBackend1"), QStringLiteral("ProcessKeyEvent"));
        m2 << sym << code << state << release << now32();
        QDBusConnection::sessionBus().asyncCall(m2);
    });
}

void Fcitx::key(const QString &name)
{
    const auto &t = keyTable();
    auto it = t.constFind(name);
    if (it == t.constEnd()) { qWarning() << "fcitx: unknown key" << name; return; }
    if (m_noTextInput) {
        // X11 clients (Steam/CEF/Wine): with no fcitx5 input context of their own, only real keys
        // reach them; with one, editing keys still need to be real, and plain text is committed
        if (!icFocused()) {
            if (name == QLatin1String("at")) realKey(11, true);
            else if (it->code) realKey(it->code, it->sym >= 'A' && it->sym <= 'Z');
            return;
        }
        if (isEditingKey(name) && it->code) { helperKeys({ { it->code, false }, { it->code, true } }); return; }
        if (m_commitOk && m_im == QLatin1String("keyboard-us") && it->sym >= 0x20 && it->sym < 0x7f) { commit(QString(QChar(it->sym))); return; }
    }
    // fcitx5's keyboard engine re-derives the character from keycode + modifier state (so layouts work),
    // so an upper-case letter needs the Shift bit or it comes out lower case (e2e 2026-10-14: "Ab" typed "ab")
    const quint32 state = it->sym >= 'A' && it->sym <= 'Z' ? 1 : 0;
    processKey(it->sym, it->code, state, false);
    processKey(it->sym, it->code, state, true);
}

// A modifier combo (Ctrl+Z, Ctrl+A, Shift+Return) for a Wayland text field. Measured on this tablet
// with tests/combo-probe.sh (2026-10-14, KWin 6.6 + fcitx5 5.1.19):
//   - the whole combo as real keys through key-helper: Qt (text-input-v2) clients get a bare "z";
//   - the key through the VK backend WITH the modifier in its state: fcitx5 forwards keysym+modifiers
//     and KWin drops the modifiers for text-input-v3 (GTK/Chromium) clients;
//   - what works for both: the modifier is HELD as a real key (key-helper), the key itself goes through
//     the VK backend as keycode only (keyval 0, state 0) — fcitx5 forwards that as a raw key and KWin
//     delivers it with the seat's live modifier state — then the modifier is released.
// The steps are spaced ~70 ms apart: the real modifier press flips fcitx5 to physical-keyboard mode and
// the Show that brings the VK backend back must land before the key.
void Fcitx::keyCombo(const QString &name, const QStringList &mods)
{
    if (mods.isEmpty()) { key(name); return; }
    const auto &t = keyTable();
    auto it = t.constFind(name);
    if (it == t.constEnd() || !it->code) return;
    QList<QPair<quint16, bool>> down, up;
    for (const QString &m : mods) if (t.contains(m)) { down.append({ t.value(m).code, false }); up.prepend({ t.value(m).code, true }); }
    if (down.isEmpty()) { key(name); return; }
    if (m_noTextInput && !icFocused()) {        // X11 client without an input context: real keys are all it gets
        helperKeys(down + QList<QPair<quint16, bool>>{ { it->code, false }, { it->code, true } } + up);
        return;
    }
    stagedCombo(down, { it->code }, up, {});
}

// modifiers down (real) -> keys as keycode-only VK events -> modifiers up (real) -> trailing plain keys
void Fcitx::stagedCombo(const QList<QPair<quint16, bool>> &down, const QList<quint16> &codes,
                        const QList<QPair<quint16, bool>> &up, const QStringList &after)
{
    if (!helperKeys(down)) return;
    requestShow();          // back to on-screen mode now, so the VK backend answers when the key arrives
    QTimer::singleShot(70, this, [this, codes, up, after] {
        for (quint16 c : codes) { processKey(0, c, 0, false); processKey(0, c, 0, true); }
        QTimer::singleShot(70, this, [this, up, after] {
            helperKeys(up);
            if (after.isEmpty()) return;
            QTimer::singleShot(40, this, [this, after] { for (const QString &n : after) key(n); });
        });
    });
}

bool Fcitx::helperKeys(const QList<QPair<quint16, bool>> &seq)
{
    auto sys = QDBusConnection::systemBus();
    auto call = [&](const QString &method, const QVariantList &args) {
        auto m = QDBusMessage::createMethodCall(HELPER, HELPER_PATH, HELPER_IF, method);
        m.setArguments(args);
        return sys.call(m, QDBus::Block, 300);
    };
    auto reset = [&] {
        const QDBusMessage r = call(QStringLiteral("ResetSerial"), {});
        m_serialOk = r.type() == QDBusMessage::ReplyMessage && !r.arguments().isEmpty();
        if (m_serialOk) m_serial = r.arguments().first().toULongLong();
        return m_serialOk;
    };
    if (!m_serialOk && !reset()) { qWarning() << "fcitx: key-helper unavailable"; return false; }
    m_helperClock.restart();
    bool ok = false;
    for (int attempt = 0; attempt < 2 && !ok; ++attempt) {
        int i = 0;
        QDBusMessage r;
        for (; i < seq.size(); ++i) {
            r = call(QStringLiteral("ProcessKeyEvent"), { QVariant::fromValue<quint64>(m_serial), QVariant::fromValue<quint16>(seq[i].first), seq[i].second });
            if (r.type() != QDBusMessage::ReplyMessage) break;
            m_serial = r.arguments().value(0).toULongLong();
        }
        if (i == seq.size()) { ok = true; break; }
        // ResetSerial releases everything the helper holds. Re-sending only key i would drop the
        // modifiers pressed before it (Shift+Return -> Return, Ctrl+V -> v): retry the WHOLE sequence
        // only when nothing of it went out yet; otherwise give the combo up.
        const bool first = i == 0;
        qWarning() << "fcitx: key-helper failed at" << i << r.errorName();
        if (!reset() || !first) break;
    }
    m_helperClock.restart();
    // a real key put fcitx5 into physical-keyboard mode: switch back so our keys keep working
    QTimer::singleShot(30, this, &Fcitx::requestShow);
    return ok;
}

void Fcitx::realKey(quint16 code, bool shift)
{
    if (!code) return;
    if (shift) helperKeys({ { 50, false }, { code, false }, { code, true }, { 50, true } });
    else helperKeys({ { code, false }, { code, true } });
}

// debug hook: "37d,52d,52u,37u" = X11 keycodes with d(own)/u(p), one key-helper sequence
void Fcitx::rawHelper(const QString &seq)
{
    QList<QPair<quint16, bool>> s;
    for (const QString &tok : seq.split(QLatin1Char(','), Qt::SkipEmptyParts)) {
        const QString t = tok.trimmed();
        if (t.size() < 2) continue;
        s.append({ quint16(t.chopped(1).toUInt()), t.endsWith(QLatin1Char('u')) });
    }
    if (!s.isEmpty()) helperKeys(s);
}

void Fcitx::clearAll()
{
    // Ctrl+A then BackSpace. All of it as real keys lost the Ctrl for both text-input protocols
    // (tests/combo-probe.sh V5: the field kept its text); the staged path (V8) clears it.
    if (m_noTextInput && !icFocused()) { helperKeys({ { 37, false }, { 38, false }, { 38, true }, { 37, true }, { 22, false }, { 22, true } }); return; }
    stagedCombo({ { 37, false } }, { 38 }, { { 37, true } }, { QStringLiteral("BackSpace") });
}

void Fcitx::clearComposition()
{
    // through the VK backend, never key-helper (that would re-show the keyboard)
    processKey(0xff1b, 9, 0, false);
    processKey(0xff1b, 9, 0, true);
}

bool Fcitx::icFocused()
{
    if (!m_commitOk) return false;
    auto m = QDBusMessage::createMethodCall(FCITX, QStringLiteral("/y700osk"), QStringLiteral("fyi.y700.OskCommit1"), QStringLiteral("HasFocus"));
    const QDBusMessage r = QDBusConnection::sessionBus().call(m, QDBus::Block, 150);
    return r.type() == QDBusMessage::ReplyMessage && r.arguments().value(0).toBool();
}

QString Fcitx::charKeyName(QChar c)
{
    const ushort u = c.unicode();
    if ((u >= 'a' && u <= 'z') || (u >= 'A' && u <= 'Z') || (u >= '0' && u <= '9')) return QString(c);
    switch (u) {
    case ' ': return QStringLiteral("space");
    case ',': return QStringLiteral("comma");
    case '.': return QStringLiteral("period");
    case 0x27: return QStringLiteral("apostrophe");
    case '/': return QStringLiteral("slash");
    case '-': return QStringLiteral("minus");
    case '=': return QStringLiteral("equal");
    case ';': return QStringLiteral("semicolon");
    case '@': return QStringLiteral("at");
    }
    return QString();
}

void Fcitx::commit(const QString &text)
{
    if (text.isEmpty()) return;
    if (m_noTextInput && !icFocused()) {
        // nothing in fcitx5 to commit into (X11 app without an IM module): type what has a key
        for (const QChar ch : text) { const QString n = charKeyName(ch); if (!n.isEmpty()) key(n); }
        return;
    }
    if (m_commitOk) {
        auto m = QDBusMessage::createMethodCall(FCITX, QStringLiteral("/y700osk"), QStringLiteral("fyi.y700.OskCommit1"), QStringLiteral("CommitString"));
        m << text;
        QDBusConnection::sessionBus().asyncCall(m);
        return;
    }
    // without the addon only plain ASCII can be typed (as keys)
    for (const QChar c : text) {
        const ushort u = c.unicode();
        if (u >= 0x20 && u < 0x7f) { processKey(u, 0, 0, false); processKey(u, 0, 0, true); }
    }
}

void Fcitx::selectCandidate(int index)
{
    // Mozc: its select only moves the selection; the addon selects AND confirms in one step
    if (m_im == QLatin1String("mozc") && m_commitOk) {
        auto m = QDBusMessage::createMethodCall(FCITX, QStringLiteral("/y700osk"), QStringLiteral("fyi.y700.OskCommit1"), QStringLiteral("SelectCandidateCommit"));
        m << index;
        auto *w = new QDBusPendingCallWatcher(QDBusConnection::sessionBus().asyncCall(m), this);
        connect(w, &QDBusPendingCallWatcher::finished, this, [this, index](QDBusPendingCallWatcher *w) {
            w->deleteLater();
            QDBusPendingReply<bool> r = *w;
            if (r.isValid() && r.value()) return;
            selectCandidateBackend(index);     // older addon or no focused field: the plain path
        });
        return;
    }
    selectCandidateBackend(index);
}

void Fcitx::selectCandidateBackend(int index)
{
    if (inHelperEcho()) requestShow();
    auto m = QDBusMessage::createMethodCall(FCITX, VK_PATH, QStringLiteral("org.fcitx.Fcitx5.VirtualKeyboardBackend1"), QStringLiteral("SelectCandidate"));
    m << index;
    auto *w = new QDBusPendingCallWatcher(QDBusConnection::sessionBus().asyncCall(m), this);
    connect(w, &QDBusPendingCallWatcher::finished, this, [this, index](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        if (!w->isError()) return;
        requestShow();
        auto m2 = QDBusMessage::createMethodCall(FCITX, VK_PATH, QStringLiteral("org.fcitx.Fcitx5.VirtualKeyboardBackend1"), QStringLiteral("SelectCandidate"));
        m2 << index;
        QDBusConnection::sessionBus().asyncCall(m2);
    });
}

// 中/英 is remembered (the owner: "whatever I set last time stays"). Within a session fcitx5 keeps it
// for every field (ShareInputState=All); after fcitx5 starts again (login, reboot) its state is back
// to English, so the first time a field takes focus we switch to the remembered IM. Only the
// owner's own switches are remembered, not ones fcitx5 makes by itself (a password field, say).
void Fcitx::imActivated(const QString &im)
{
    if (!m_restored) {
        m_restored = true;
        if ((m_rememberedIM == QLatin1String("rime") || m_rememberedIM == QLatin1String("keyboard-us") || m_rememberedIM == QLatin1String("mozc")) && im != m_rememberedIM) {
            setCurrentIM(m_rememberedIM, false);
            return;
        }
    }
    m_im = im;
    emit imChanged(im);
}

void Fcitx::restoreIMIfNeeded()
{
    if (m_restored) return;
    if (m_rememberedIM != QLatin1String("rime") && m_rememberedIM != QLatin1String("keyboard-us") && m_rememberedIM != QLatin1String("mozc")) { m_restored = true; return; }
    auto m = QDBusMessage::createMethodCall(FCITX, QStringLiteral("/controller"), QStringLiteral("org.fcitx.Fcitx.Controller1"), QStringLiteral("CurrentInputMethod"));
    auto *w = new QDBusPendingCallWatcher(QDBusConnection::sessionBus().asyncCall(m), this);
    connect(w, &QDBusPendingCallWatcher::finished, this, [this](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        QDBusPendingReply<QString> r = *w;
        if (m_restored || !r.isValid() || r.value().isEmpty()) return;
        m_restored = true;
        if (r.value() != m_rememberedIM) setCurrentIM(m_rememberedIM, false);
    });
}

void Fcitx::page(bool next)
{
    if (inHelperEcho()) requestShow();
    auto m = QDBusMessage::createMethodCall(FCITX, VK_PATH, QStringLiteral("org.fcitx.Fcitx5.VirtualKeyboardBackend1"),
                                            next ? QStringLiteral("NextPage") : QStringLiteral("PrevPage"));
    QDBusConnection::sessionBus().asyncCall(m);
}

void Fcitx::setCurrentIM(const QString &im, bool remember)
{
    if (remember && im != m_rememberedIM) {
        m_rememberedIM = im;
        QSettings().setValue(QStringLiteral("im/last"), im);
    }
    auto m = QDBusMessage::createMethodCall(FCITX, QStringLiteral("/controller"), QStringLiteral("org.fcitx.Fcitx.Controller1"), QStringLiteral("SetCurrentIM"));
    m << im;
    QDBusConnection::sessionBus().asyncCall(m);
    m_im = im;
    emit imChanged(im);
}

void Fcitx::queryIM()
{
    auto m = QDBusMessage::createMethodCall(FCITX, QStringLiteral("/controller"), QStringLiteral("org.fcitx.Fcitx.Controller1"), QStringLiteral("CurrentInputMethod"));
    auto *w = new QDBusPendingCallWatcher(QDBusConnection::sessionBus().asyncCall(m), this);
    connect(w, &QDBusPendingCallWatcher::finished, this, [this](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        QDBusPendingReply<QString> r = *w;
        if (r.isValid() && !r.value().isEmpty() && r.value() != m_im) { m_im = r.value(); emit imChanged(m_im); }
    });
}

void Fcitx::probeCommit()
{
    auto m = QDBusMessage::createMethodCall(FCITX, QStringLiteral("/y700osk"), QStringLiteral("org.freedesktop.DBus.Introspectable"), QStringLiteral("Introspect"));
    auto *w = new QDBusPendingCallWatcher(QDBusConnection::sessionBus().asyncCall(m), this);
    connect(w, &QDBusPendingCallWatcher::finished, this, [this](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        QDBusPendingReply<QString> r = *w;
        m_commitOk = r.isValid() && r.value().contains(QLatin1String("fyi.y700.OskCommit1"));
        if (!m_commitOk) qWarning() << "fcitx: commit addon not loaded; only ASCII text can be typed directly";
    });
}
