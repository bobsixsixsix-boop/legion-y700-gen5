#include "voice.h"

#include <pipewire/pipewire.h>
#include <spa/param/audio/format-utils.h>

#include <QDir>
#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRegularExpression>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QTimer>
#include <QtEndian>

#include <cmath>

namespace {
constexpr int RATE = 16000;
constexpr int MIN_MS = 350;          // shorter holds are accidental
constexpr int MAX_MS = 120000;

QString codeFile()
{
    const QByteArray env = qgetenv("Y700_OSK_ASR_CODE_FILE");
    return env.isEmpty() ? QDir::homePath() + QStringLiteral("/.config/y700-osk/asr.code") : QString::fromLocal8Bit(env);
}
QUrl asrUrl()
{
    const QByteArray env = qgetenv("Y700_OSK_ASR_URL");
    return QUrl(env.isEmpty() ? QStringLiteral("https://asr.example.invalid/v1/asr") : QString::fromLocal8Bit(env));
}
} // namespace

struct Voice::Hook { pw_stream_events events{}; };

void Voice::processThunk(void *data)
{
    auto *self = static_cast<Voice *>(data);
    pw_stream *s = self->m_stream;
    if (!s) return;
    pw_buffer *pb = pw_stream_dequeue_buffer(s);
    if (!pb) return;
    spa_data &d = pb->buffer->datas[0];
    if (d.data && d.chunk) {
        const auto *pcm = reinterpret_cast<const int16_t *>(static_cast<const uint8_t *>(d.data) + d.chunk->offset);
        self->onCapture(pcm, int(d.chunk->size / sizeof(int16_t)));
    }
    pw_stream_queue_buffer(s, pb);
}

Voice::Voice(QObject *parent) : QObject(parent)
{
    pw_init(nullptr, nullptr);
    m_loop = pw_thread_loop_new("y700-osk-voice", nullptr);
    if (m_loop) pw_thread_loop_start(m_loop);
    m_hook = new Hook;
    m_hook->events.version = PW_VERSION_STREAM_EVENTS;
    m_hook->events.process = &Voice::processThunk;

    m_net = new QNetworkAccessManager(this);
    m_meter = new QTimer(this);
    m_meter->setInterval(33);
    connect(m_meter, &QTimer::timeout, this, [this] {
        const float rms = m_rms.load();
        const double db = rms > 1e-6 ? 20 * std::log10(rms) : -90;
        const qreal target = std::clamp((db + 55) / 45, 0.0, 1.0);
        m_level = target > m_level ? target : m_level * 0.82 + target * 0.18;   // fast attack, soft release
        emit levelChanged();
    });
    m_cap = new QTimer(this);
    m_cap->setSingleShot(true);
    m_cap->setInterval(MAX_MS);
    connect(m_cap, &QTimer::timeout, this, [this] { finish(); });   // 120 s cap: recognise what we have
}

Voice::~Voice()
{
    stopCapture();
    if (m_loop) { pw_thread_loop_stop(m_loop); pw_thread_loop_destroy(m_loop); }
    delete m_hook;
}

void Voice::setState(int s)
{
    if (s == m_state) return;
    m_state = s;
    emit stateChanged();
}

void Voice::warmUp()
{
    const QUrl u = asrUrl();
    if (u.scheme() == QLatin1String("https")) m_net->connectToHostEncrypted(u.host(), quint16(u.port(443)));
    else m_net->connectToHost(u.host(), quint16(u.port(80)));
}

void Voice::start()
{
    if (m_state == 1) return;
    // a recognition still in flight is kept: dictating sentence by sentence must not lose one
    {
        std::lock_guard<std::mutex> l(m_mx);
        m_pcm.clear();
        m_pcm.reserve(RATE * 2 * 10);
    }
    m_rms = 0;
    m_level = 0;
    if (!m_loop) { emit failed(QStringLiteral("麦克风不可用")); return; }

    pw_thread_loop_lock(m_loop);
    pw_properties *props = pw_properties_new(
        PW_KEY_MEDIA_TYPE, "Audio", PW_KEY_MEDIA_CATEGORY, "Capture", PW_KEY_MEDIA_ROLE, "Communication",
        PW_KEY_APP_NAME, "Y700 屏幕键盘", PW_KEY_NODE_NAME, "y700-osk-voice", PW_KEY_NODE_LATENCY, "800/16000", nullptr);
    m_stream = pw_stream_new_simple(pw_thread_loop_get_loop(m_loop), "y700-osk-voice", props, &m_hook->events, this);
    bool ok = m_stream != nullptr;
    if (ok) {
        uint8_t buffer[1024];
        spa_pod_builder b = SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
        spa_audio_info_raw info{};
        info.format = SPA_AUDIO_FORMAT_S16_LE;
        info.channels = 1;
        info.rate = RATE;
        info.position[0] = SPA_AUDIO_CHANNEL_MONO;
        const spa_pod *params[1] = { spa_format_audio_raw_build(&b, SPA_PARAM_EnumFormat, &info) };
        ok = pw_stream_connect(m_stream, PW_DIRECTION_INPUT, PW_ID_ANY,
                               pw_stream_flags(PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_MAP_BUFFERS | PW_STREAM_FLAG_RT_PROCESS),
                               params, 1) >= 0;
        if (!ok) { pw_stream_destroy(m_stream); m_stream = nullptr; }
    }
    pw_thread_loop_unlock(m_loop);
    if (!ok) { emit failed(QStringLiteral("麦克风不可用")); return; }

    m_clock.start();
    m_meter->start();
    m_cap->start();
    setState(1);
    warmUp();
}

void Voice::onCapture(const int16_t *pcm, int frames)
{
    if (frames <= 0) return;
    double acc = 0;
    for (int i = 0; i < frames; ++i) { const double x = pcm[i] / 32768.0; acc += x * x; }
    m_rms = float(std::sqrt(acc / frames));
    std::lock_guard<std::mutex> l(m_mx);
    if (m_pcm.size() < RATE * 2 * (MAX_MS / 1000 + 1))
        m_pcm.append(reinterpret_cast<const char *>(pcm), frames * int(sizeof(int16_t)));
}

void Voice::stopCapture()
{
    m_meter->stop();
    m_cap->stop();
    if (!m_stream) return;
    pw_thread_loop_lock(m_loop);
    pw_stream_disconnect(m_stream);
    pw_stream_destroy(m_stream);
    m_stream = nullptr;
    pw_thread_loop_unlock(m_loop);
    m_level = 0;
    emit levelChanged();
}

void Voice::cancel()
{
    // cancels the capture only; speech already sent for recognition is still delivered (discard() drops it)
    stopCapture();
    { std::lock_guard<std::mutex> l(m_mx); m_pcm.clear(); }
    updateState();
}

void Voice::discard()
{
    // A result is typed into whatever has the focus when it arrives: after a hop to the next chat in the
    // same Telegram window, or to the address bar, it landed there (10-19 audit D2, 10-31 audit osk A3).
    // Osk calls this on fcitx5's Hide (the field lost the focus) and when the keyboard goes away; dictating
    // into one field sentence by sentence gets no Hide in between, so nothing is lost there.
    if (m_pending.isEmpty()) return;
    const QList<QNetworkReply *> pending = m_pending;
    m_pending.clear();
    for (QNetworkReply *r : pending) {
        r->disconnect(this);       // abort() emits finished(): it must not reach drain()
        r->abort();
        r->deleteLater();
    }
    updateState();
    emit failed(QStringLiteral("换了输入框，这句语音没有上屏"));
}

void Voice::updateState() { setState(m_stream ? 1 : m_pending.isEmpty() ? 0 : 2); }

void Voice::drain()
{
    while (!m_pending.isEmpty() && m_pending.first()->property("y700done").toBool()) {
        QNetworkReply *r = m_pending.takeFirst();
        r->deleteLater();
        const int code = r->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (code == 200) {
            const QString text = QJsonDocument::fromJson(r->readAll()).object().value(QStringLiteral("text")).toString().trimmed();
            if (text.isEmpty()) emit failed(QStringLiteral("没有听清，请再说一次"));
            else emit recognised(text);
        } else if (code == 401) emit failed(QStringLiteral("语音访问码无效"));
        else if (code == 403) emit failed(QStringLiteral("这个账号没有翻译成外语的权限"));
        else if (code == 429) emit failed(QStringLiteral("说得太频繁了，稍后再试"));
        else if (code == 503) emit failed(QStringLiteral("识别服务忙，请再试一次"));
        else if (code == 0) emit failed(QStringLiteral("识别失败：网络不通"));
        else emit failed(QStringLiteral("识别失败（%1）").arg(code));
    }
    updateState();
}

QByteArray Voice::wav() const
{
    QByteArray pcm;
    { std::lock_guard<std::mutex> l(const_cast<Voice *>(this)->m_mx); pcm = m_pcm; }
    QByteArray h(44, 0);
    auto put32 = [&](int at, quint32 v) { qToLittleEndian(v, h.data() + at); };
    auto put16 = [&](int at, quint16 v) { qToLittleEndian(v, h.data() + at); };
    memcpy(h.data(), "RIFF", 4); put32(4, quint32(36 + pcm.size())); memcpy(h.data() + 8, "WAVEfmt ", 8);
    put32(16, 16); put16(20, 1); put16(22, 1); put32(24, RATE); put32(28, RATE * 2); put16(32, 2); put16(34, 16);
    memcpy(h.data() + 36, "data", 4); put32(40, quint32(pcm.size()));
    return h + pcm;
}

void Voice::finish(const QString &target)
{
    if (m_state != 1) return;
    const qint64 ms = m_clock.elapsed();
    stopCapture();
    if (ms < MIN_MS) { cancel(); emit failed(QStringLiteral("short")); return; }

    QFile f(codeFile());
    QByteArray code;
    if (f.open(QIODevice::ReadOnly)) code = f.readAll().trimmed();
    if (code.isEmpty()) { cancel(); emit failed(QStringLiteral("语音识别还没配置访问码")); return; }

    setState(2);
    QUrl url = asrUrl();
    if (target == QLatin1String("ja") || target == QLatin1String("en")) {
        QString p = url.path();
        p.replace(QRegularExpression(QStringLiteral("/asr$")), QStringLiteral("/voice"));
        url.setPath(p);
        url.setQuery(QStringLiteral("target=") + target);
    }
    QNetworkRequest req(url);
    req.setRawHeader("Authorization", "Bearer " + code);
    req.setRawHeader("Content-Type", "audio/wav");
    req.setRawHeader("X-Client-Platform", "desktop");
    req.setRawHeader("X-Client-Version", "11202");
    req.setTransferTimeout(20000);
    QNetworkReply *r = m_net->post(req, wav());
    { std::lock_guard<std::mutex> l(m_mx); m_pcm.clear(); }
    m_pending.append(r);
    connect(r, &QNetworkReply::finished, this, [this, r] { r->setProperty("y700done", true); drain(); });
}

