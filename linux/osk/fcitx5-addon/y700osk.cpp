// fcitx5 addon "y700osk": lets the Y700 on-screen keyboard commit whole strings (voice results,
// emoji, symbols, clipboard entries) into the focused app. fcitx5 5.1's DBus virtual keyboard
// backend only takes key events, which cannot carry CJK text.
//
//   org.fcitx.Fcitx5  /y700osk  fyi.y700.OskCommit1
//     CommitString(s text) -> b      commit into the focused input context
//     ForwardKey(s name, u xkbCode, b isRelease) -> b   send a key past the engines
//     HasFocus() -> b                 is there a focused input context
//     SelectCandidateCommit(i index) -> b   Mozc only: pick candidate <index> of the current page AND
//                                     commit (Mozc's own select only moves the selection; the owner
//                                     had to press Return after every tap)
//
// Runs on fcitx5's own bus connection and main loop. Targets the last *focused* input context
// only (mostRecentInputContext() may fall back to an unfocused one and the text would vanish).
#include <fcitx-utils/dbus/bus.h>
#include <fcitx-utils/dbus/objectvtable.h>
#include <fcitx-utils/key.h>
#include <fcitx/candidatelist.h>
#include <fcitx/event.h>
#include <fcitx/inputpanel.h>
#include <fcitx/addonfactory.h>
#include <fcitx/addoninstance.h>
#include <fcitx/addonmanager.h>
#include <fcitx/inputcontext.h>
#include <fcitx/inputcontextmanager.h>
#include <fcitx/instance.h>
#include "dbus_public.h"   // Fcitx5::Module::DBus puts fcitx-module/dbus on the include path

namespace fcitx {

class Y700OskService : public dbus::ObjectVTable<Y700OskService> {
public:
    explicit Y700OskService(Instance *instance) : instance_(instance) {}

    bool commitString(const std::string &text) {
        auto *ic = focused();
        if (!ic || text.empty()) return false;
        ic->commitString(text);
        return true;
    }

    bool forwardKey(const std::string &name, uint32_t xkbCode, bool isRelease) {
        auto *ic = focused();
        if (!ic) return false;
        Key parsed(name);
        Key key(parsed.sym(), parsed.states(), static_cast<int>(xkbCode));
        if (!key.isValid()) throw dbus::MethodCallError("org.freedesktop.DBus.Error.InvalidArgs", "bad key");
        ic->forwardKey(key, isRelease);
        return true;
    }

    // lets the keyboard tell an X11 app with its own IM context from one without
    bool hasFocus() { return focused() != nullptr; }

    // A tap on a Mozc candidate: select it, and if Mozc is still composing afterwards (its
    // SELECT_CANDIDATE only moves the conversion's selection), confirm with a virtual Return.
    // All of this runs synchronously in fcitx5's main loop, Mozc's server round trip included, so
    // the preedit check sees the state after the selection: a Return is only sent while there is
    // still something to confirm and can never reach the app as a stray newline.
    bool selectCandidateCommit(int32_t index) {
        auto *ic = focused();
        if (!ic || instance_->inputMethod(ic) != "mozc") return false;
        auto list = ic->inputPanel().candidateList();     // held by value: select() resets the panel
        if (!list) return false;
        const CandidateWord *word = nullptr;
        try {
            word = list->toBulk() ? &list->toBulk()->candidateFromAll(index) : &list->candidate(index);
        } catch (...) {
            return false;
        }
        if (word->isPlaceHolder()) return false;
        // Mozc sends SELECT_CANDIDATE: the conversion's focus moves to the word, the candidate window
        // closes, nothing is committed yet (fcitx/mozc session.cc SelectCandidateInternal)
        word->select(ic);
        auto &panel = ic->inputPanel();
        const bool composing = !panel.clientPreedit().toString().empty() || !panel.preedit().toString().empty();
        // a candidate list still there = the select did not take (IPC error, bad id): a Return now
        // would commit the raw kana instead of the tapped word, so leave it
        if (!composing || panel.candidateList()) return true;
        // Return = Commit in Mozc's conversion keymap (all segments). keyEvent() only delivers to the
        // engine; it never forwards, so this Return cannot reach the app as a newline.
        const Key ret(FcitxKey_Return, KeyStates{KeyState::Virtual}, 36);
        KeyEvent press(ic, ret, false);
        ic->keyEvent(press);
        KeyEvent release(ic, ret, true);
        ic->keyEvent(release);
        return true;
    }

private:
    InputContext *focused() {
        auto *ic = instance_->inputContextManager().lastFocusedInputContext();
        return (ic && ic->hasFocus()) ? ic : nullptr;
    }

    FCITX_OBJECT_VTABLE_METHOD(commitString, "CommitString", "s", "b");
    FCITX_OBJECT_VTABLE_METHOD(hasFocus, "HasFocus", "", "b");
    FCITX_OBJECT_VTABLE_METHOD(selectCandidateCommit, "SelectCandidateCommit", "i", "b");
    FCITX_OBJECT_VTABLE_METHOD(forwardKey, "ForwardKey", "sub", "b");
    Instance *instance_;
};

class Y700Osk : public AddonInstance {
public:
    explicit Y700Osk(Instance *instance);

private:
    Instance *instance_;
    FCITX_ADDON_DEPENDENCY_LOADER(dbus, instance_->addonManager());
    Y700OskService service_;
};

// out of line: the loader's auto-typed dbus() must be complete before it is used
Y700Osk::Y700Osk(Instance *instance) : instance_(instance), service_(instance) {
    dbus()->call<IDBusModule::bus>()->addObjectVTable("/y700osk", "fyi.y700.OskCommit1", service_);
}

class Y700OskFactory : public AddonFactory {
    AddonInstance *create(AddonManager *manager) override { return new Y700Osk(manager->instance()); }
};

} // namespace fcitx

FCITX_ADDON_FACTORY_V2(y700osk, fcitx::Y700OskFactory);
