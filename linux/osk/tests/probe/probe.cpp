// y700-osk-probe [seconds]: a window with a multi-line text field that has focus at start.
// Prints "TEXT <json-escaped text>" whenever the text changes; quits after N seconds (default 60).
#include <QApplication>
#include <QJsonDocument>
#include <QJsonArray>
#include <QPlainTextEdit>
#include <QTimer>
#include <cstdio>

int main(int argc, char **argv)
{
    QApplication app(argc, argv);
    QPlainTextEdit edit;
    edit.setWindowTitle(QStringLiteral("y700-osk-probe"));
    edit.resize(900, 300);
    QObject::connect(&edit, &QPlainTextEdit::textChanged, [&] {
        const QByteArray j = QJsonDocument(QJsonArray{ edit.toPlainText() }).toJson(QJsonDocument::Compact);
        std::printf("TEXT %s\n", j.constData());
        std::fflush(stdout);
    });
    edit.show();
    edit.activateWindow();
    edit.setFocus();
    QTimer::singleShot((argc > 1 ? atoi(argv[1]) : 60) * 1000, &app, &QApplication::quit);
    return app.exec();
}
