// Voice input: capture the microphone in-process (PipeWire, s16 mono 16 kHz, resampled by
// PipeWire), then send one WAV to an HTTP speech-recognition gateway (POST /v1/asr, one-shot,
// returns {"text": ...}). No public gateway is bundled: point Y700_OSK_ASR_URL at your own
// (full URL of the /asr endpoint; the built-in default is a placeholder that never resolves,
// so recognition fails until it is set).
// Translating instead: POST /v1/voice?target=ja|en (the trailing /asr of the URL becomes /voice),
// same WAV body, returns {"text": translation, "asr": original}; 403 = the gateway refuses
// translation for this access code.
//
// The access code is read from a file at request time (path only, never logged) and sent as
// "Authorization: Bearer <code>"; set its path with Y700_OSK_ASR_CODE_FILE (default:
// ~/.config/y700-osk/asr.code). Use an https URL: with http the code travels in clear text.
// Holds shorter than 0.35 s are dropped, recordings are capped at 120 s, audio never touches disk.
#pragma once
#include <QByteArray>
#include <QElapsedTimer>
#include <QObject>
#include <QPointer>
#include <atomic>
#include <mutex>

class QNetworkAccessManager;
class QNetworkReply;
class QTimer;
struct pw_thread_loop;
struct pw_stream;

class Voice : public QObject
{
    Q_OBJECT
    Q_PROPERTY(int state READ state NOTIFY stateChanged)         // 0 idle, 1 listening, 2 recognising
    Q_PROPERTY(qreal level READ level NOTIFY levelChanged)       // 0..1, ~30 Hz while listening
    Q_PROPERTY(int seconds READ seconds NOTIFY levelChanged)
public:
    explicit Voice(QObject *parent = nullptr);
    ~Voice() override;

    int state() const { return m_state; }
    qreal level() const { return m_level; }
    int seconds() const { return int(m_clock.isValid() && m_state == 1 ? m_clock.elapsed() / 1000 : 0); }

    Q_INVOKABLE void start();
    // stop recording and recognise; target "ja"/"en" = recognise AND translate in one request
    // (gateway /v1/voice?target=..), empty = plain recognition (/v1/asr)
    Q_INVOKABLE void finish(const QString &target = QString());
    Q_INVOKABLE void cancel();      // stop and throw the audio away
    void discard();                 // the field lost the focus / the keyboard went away: drop what is still being recognised
    Q_INVOKABLE void warmUp();      // open the TLS connection early (called when a hold begins)

    void onCapture(const int16_t *pcm, int frames);   // PipeWire RT thread

signals:
    void stateChanged();
    void levelChanged();
    void recognised(const QString &text);
    void failed(const QString &message);

private:
    static void processThunk(void *data);
    void stopCapture();
    void setState(int s);
    QByteArray wav() const;

    int m_state = 0;
    qreal m_level = 0;
    QElapsedTimer m_clock;
    QTimer *m_meter = nullptr;
    QTimer *m_cap = nullptr;

    std::mutex m_mx;
    QByteArray m_pcm;
    std::atomic<float> m_rms{0};

    pw_thread_loop *m_loop = nullptr;
    pw_stream *m_stream = nullptr;
    struct Hook; Hook *m_hook = nullptr;

    QNetworkAccessManager *m_net = nullptr;
    QList<QNetworkReply *> m_pending;      // submitted recognitions, oldest first
    void drain();
    void updateState();
};
