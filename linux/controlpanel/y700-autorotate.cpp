// y700-autorotate: read or set KWin's automatic screen rotation policy through libkscreen.
//   y700-autorotate              -> prints "<output> <never|tablet|always>" for every enabled output
//   y700-autorotate never|tablet|always
// kscreen-doctor 6.6 has no option for the auto-rotate policy (only the Display KCM does), hence this
// tool. Built against the installed libKF6Screen.so.8 with the headers of the matching libkscreen
// source tarball (no -dev package in Ubuntu 26.04); see build.sh.
#include <KScreen/GetConfigOperation>
#include <KScreen/SetConfigOperation>
#include <KScreen/Config>
#include <KScreen/Output>
#include <QGuiApplication>
#include <cstdio>
#include <cstring>

static const char *policyName(KScreen::Output::AutoRotatePolicy p)
{
    switch (p) {
    case KScreen::Output::AutoRotatePolicy::Never: return "never";
    case KScreen::Output::AutoRotatePolicy::InTabletMode: return "tablet";
    case KScreen::Output::AutoRotatePolicy::Always: return "always";
    }
    return "?";
}

int main(int argc, char **argv)
{
    qputenv("QT_QPA_PLATFORM", "wayland");   // the kwayland backend needs a Wayland QGuiApplication
    QGuiApplication app(argc, argv);
    const char *want = argc > 1 ? argv[1] : "status";
    KScreen::Output::AutoRotatePolicy policy = KScreen::Output::AutoRotatePolicy::InTabletMode;
    if (!strcmp(want, "never")) policy = KScreen::Output::AutoRotatePolicy::Never;
    else if (!strcmp(want, "tablet")) policy = KScreen::Output::AutoRotatePolicy::InTabletMode;
    else if (!strcmp(want, "always")) policy = KScreen::Output::AutoRotatePolicy::Always;
    else if (strcmp(want, "status")) { fprintf(stderr, "usage: y700-autorotate [status|never|tablet|always]\n"); return 2; }
    const bool set = strcmp(want, "status") != 0;

    auto *op = new KScreen::GetConfigOperation();
    QObject::connect(op, &KScreen::ConfigOperation::finished, &app, [&](KScreen::ConfigOperation *o) {
        if (o->hasError()) { fprintf(stderr, "%s\n", qPrintable(o->errorString())); app.exit(1); return; }
        KScreen::ConfigPtr cfg = static_cast<KScreen::GetConfigOperation *>(o)->config();
        for (const KScreen::OutputPtr &out : cfg->outputs()) {
            if (!out->isEnabled()) continue;
            // only the built-in panel follows the accelerometer; an external monitor keeps its own policy
            if (set && out->type() != KScreen::Output::Panel) continue;
            if (set) out->setAutoRotatePolicy(policy);
            else printf("%s %s\n", qPrintable(out->name()), policyName(out->autoRotatePolicy()));
        }
        if (!set) { app.exit(0); return; }
        auto *sop = new KScreen::SetConfigOperation(cfg);
        QObject::connect(sop, &KScreen::ConfigOperation::finished, &app, [&](KScreen::ConfigOperation *s) {
            if (s->hasError()) { fprintf(stderr, "%s\n", qPrintable(s->errorString())); app.exit(1); return; }
            printf("%s\n", policyName(policy));
            app.exit(0);
        });
    });
    return app.exec();
}
