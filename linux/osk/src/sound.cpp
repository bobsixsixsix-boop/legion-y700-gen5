#include "sound.h"

#include <pipewire/pipewire.h>
#include <spa/param/audio/format-utils.h>

#include <QDebug>
#include <QTimer>
#include <algorithm>
#include <cmath>
#include <cstring>

namespace {
constexpr int RATE = 48000;
constexpr double PI = 3.14159265358979323846;

float dbToGain(double db) { return float(std::pow(10.0, db / 20.0)); }

// vivo "标准": a 6-cycle sine burst with a fast linear attack and a two-step decay.
std::vector<float> sineBurst(double f, double db, int cycles, bool triangle)
{
    const double T = 1.0 / f, e = cycles * T;
    const int n = int(std::ceil(e * RATE)) + 2;
    const float A = dbToGain(db);
    std::vector<float> out(n);
    for (int i = 0; i < n; ++i) {
        const double t = double(i) / RATE;
        double env;
        if (t < 1e-4) env = t / 1e-4;
        else if (t < T) env = 1.0 - 0.29 * (t - 1e-4) / (T - 1e-4);
        else if (t < e - T) env = 0.71 - 0.21 * (t - T) / std::max(1e-6, e - 2 * T);
        else if (t < e) env = 0.5 * (e - t) / T;
        else env = 0;
        const double ph = std::fmod(t * f, 1.0);
        const double w = triangle ? (ph < 0.5 ? 4 * ph - 1 : 3 - 4 * ph) : std::sin(2 * PI * f * t);
        out[i] = float(A * env * w);
    }
    return out;
}

// "木琴音" for toolbar buttons and the candidate expander: two partials with exponential decay.
std::vector<float> mallet(double f, double tau, double db, double partialDb)
{
    const int n = int((tau * 4.6 + 0.004) * RATE);
    const float A = dbToGain(db), P = A * dbToGain(partialDb);
    const double attack = 1.5 / f;
    std::vector<float> out(n);
    for (int i = 0; i < n; ++i) {
        const double t = double(i) / RATE;
        const double a = t < attack ? t / attack : 1.0;
        const double d1 = t < attack ? 1.0 : std::exp(-(t - attack) / tau);
        const double d2 = t < attack ? 1.0 : std::exp(-(t - attack) / (tau / 2));
        out[i] = float(a * (A * d1 * std::sin(2 * PI * f * t) + P * d2 * std::sin(2 * PI * 4 * f * t)));
    }
    return out;
}

// "机械": a band-passed noise click plus a short low thump (our own sound, not vivo's).
std::vector<float> mechClick(double band, double thump, uint32_t seed)
{
    const int n = int(0.036 * RATE);
    std::vector<float> out(n, 0.f);
    // RBJ band-pass, constant 0 dB peak gain
    const double w0 = 2 * PI * band / RATE, Q = 0.9, alpha = std::sin(w0) / (2 * Q);
    const double b0 = alpha, b2 = -alpha, a0 = 1 + alpha, a1 = -2 * std::cos(w0), a2 = 1 - alpha;
    double x1 = 0, x2 = 0, y1 = 0, y2 = 0;
    const int nn = int(0.012 * RATE);
    for (int i = 0; i < nn; ++i) {
        seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5;
        const double x = (double(seed) / 4294967295.0 * 2 - 1) * std::exp(-double(i) / (nn / 5.0));
        const double y = (b0 * x + b2 * x2 - a1 * y1 - a2 * y2) / a0;
        x2 = x1; x1 = x; y2 = y1; y1 = y;
        out[i] += float(0.5 * y);
    }
    for (int i = 0; i < n; ++i) {
        const double t = double(i) / RATE;
        out[i] += float(0.18 * std::exp(-t / 0.0065) * std::sin(2 * PI * thump * t));
    }
    return out;
}
} // namespace

struct Sound::Hook {
    pw_stream_events events{};
};

static void onProcess(void *data) { static_cast<Sound *>(data)->process(); }
static void onState(void *data, pw_stream_state, pw_stream_state state, const char *error)
{
    // PipeWire restarted or the stream broke (EPIPE shows up as UNCONNECTED with an error)
    if (state == PW_STREAM_STATE_ERROR || (state == PW_STREAM_STATE_UNCONNECTED && error))
        static_cast<Sound *>(data)->streamFailed();
}

Sound::Sound(QObject *parent) : QObject(parent)
{
    synthesise();

    pw_init(nullptr, nullptr);
    m_loop = pw_thread_loop_new("y700-osk-sound", nullptr);
    if (!m_loop) { qWarning() << "sound: no PipeWire loop"; return; }

    m_hook = new Hook;
    m_hook->events.version = PW_VERSION_STREAM_EVENTS;
    m_hook->events.process = onProcess;
    m_hook->events.state_changed = onState;

    if (!connectStream()) qWarning() << "sound: no PipeWire stream (will retry)";
    pw_thread_loop_start(m_loop);
}

bool Sound::connectStream()
{
    pw_properties *props = pw_properties_new(
        PW_KEY_MEDIA_TYPE, "Audio",
        PW_KEY_MEDIA_CATEGORY, "Playback",
        PW_KEY_MEDIA_NAME, "key clicks",
        PW_KEY_APP_NAME, "Y700 屏幕键盘",
        PW_KEY_NODE_NAME, "y700-osk-clicks",
        // no node.latency: the click stream joins whatever quantum the graph runs at and never changes
        // it (256/48000 pulls a running graph, e.g. a video at 1024, down to 256 on every activation and
        // back up 10 s after the last key). Cost: alone on the speaker path the graph runs at the default
        // quantum (1024), so a click reaches the speaker ~24 ms later on average than at 256.
        nullptr);
    m_stream = pw_stream_new_simple(pw_thread_loop_get_loop(m_loop), "y700-osk-clicks", props, &m_hook->events, this);
    if (!m_stream) return false;

    uint8_t buffer[1024];
    spa_pod_builder b = SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
    spa_audio_info_raw info{};
    info.format = SPA_AUDIO_FORMAT_F32;
    info.channels = 1;
    info.rate = RATE;
    info.position[0] = SPA_AUDIO_CHANNEL_MONO;
    const spa_pod *params[1] = { spa_format_audio_raw_build(&b, SPA_PARAM_EnumFormat, &info) };

    const auto flags = pw_stream_flags(PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_MAP_BUFFERS
                                       | PW_STREAM_FLAG_RT_PROCESS | PW_STREAM_FLAG_INACTIVE);
    if (pw_stream_connect(m_stream, PW_DIRECTION_OUTPUT, PW_ID_ANY, flags, params, 1) < 0) {
        pw_stream_destroy(m_stream); m_stream = nullptr; return false;
    }
    return true;
}

void Sound::streamFailed()
{
    if (!m_rebuildQueued.exchange(true)) QMetaObject::invokeMethod(this, &Sound::rebuild, Qt::QueuedConnection);
}

void Sound::rebuild()
{
    m_rebuildQueued = false;
    pw_thread_loop_lock(m_loop);
    if (m_stream) { pw_stream_destroy(m_stream); m_stream = nullptr; }
    const bool ok = connectStream();
    if (ok && m_active) pw_stream_set_active(m_stream, true);
    pw_thread_loop_unlock(m_loop);
    if (!ok) { qWarning() << "sound: PipeWire not back yet, retrying"; QTimer::singleShot(2000, this, [this] { streamFailed(); }); }
}

Sound::~Sound()
{
    if (m_loop) pw_thread_loop_stop(m_loop);
    if (m_stream) pw_stream_destroy(m_stream);
    if (m_loop) pw_thread_loop_destroy(m_loop);
    delete m_hook;
}

void Sound::synthesise()
{
    struct T { double f, db; } tones[] = { {2093, -14.7}, {1568, -14.6}, {1760, -16.9}, {1109, -14.8} };
    for (int k = 0; k < 4; ++k) {
        m_bank[Standard][k] = sineBurst(tones[k].f, tones[k].db, 6, false);
        m_bank[Soft][k] = sineBurst(tones[k].f / 2, tones[k].db - 2, 8, true);
    }
    const double band[4] = { 4200, 2600, 4200, 4200 }, thump[4] = { 210, 150, 210, 170 };
    for (int k = 0; k < 4; ++k) m_bank[Mechanical][k] = mechClick(band[k], thump[k], 0x1234567u + k * 977u);
    for (int s = 0; s < StyleCount; ++s) {
        m_bank[s][Tool] = mallet(1174.7, 0.009, -12.8, -17);
        m_bank[s][Expand] = mallet(784, 0.0115, -10.4, -15);
    }
}

void Sound::setActive(bool on)
{
    if (on == m_active) return;
    m_active = on;
    if (!m_stream) return;
    pw_thread_loop_lock(m_loop);
    pw_stream_set_active(m_stream, on);
    pw_thread_loop_unlock(m_loop);
}

void Sound::setVolume(int level) { m_volume = std::clamp(level, 0, 10); }
void Sound::setStyle(int style) { m_style = std::clamp(style, 0, int(StyleCount) - 1); }

void Sound::play(int kind)
{
    if (!m_active || kind < 0 || kind >= KindCount) return;
    const int vol = m_volume.load();
    if (vol <= 0) return;
    auto rnd = [this] { m_seed ^= m_seed << 13; m_seed ^= m_seed >> 17; m_seed ^= m_seed << 5; return float(m_seed) / 4294967295.f; };
    Req r;
    r.kind = uint8_t(kind);
    r.gain = vol / 10.f * (0.8f + rnd() * 0.4f);     // ±20 % like vivo
    r.rate = 0.991f + rnd() * 0.018f;                  // ±0.9 % pitch
    const uint32_t h = m_head.load(std::memory_order_relaxed);
    if (h - m_tail.load(std::memory_order_acquire) >= RING) return;   // full: drop
    m_ring[h % RING] = r;
    m_head.store(h + 1, std::memory_order_release);
}

void Sound::process()
{
    pw_buffer *pb = pw_stream_dequeue_buffer(m_stream);
    if (!pb) return;
    spa_buffer *buf = pb->buffer;
    auto *dst = static_cast<float *>(buf->datas[0].data);
    if (!dst) { pw_stream_queue_buffer(m_stream, pb); return; }
    uint32_t n = buf->datas[0].maxsize / sizeof(float);
    if (pb->requested) n = std::min<uint32_t>(n, uint32_t(pb->requested));

    const int style = m_style.load();
    uint32_t t = m_tail.load(std::memory_order_relaxed);
    const uint32_t h = m_head.load(std::memory_order_acquire);
    for (; t != h; ++t) {
        const Req &r = m_ring[t % RING];
        Voice *slot = &m_voices[0];
        for (auto &v : m_voices) { if (!v.buf) { slot = &v; break; } if (v.pos > slot->pos) slot = &v; }
        slot->buf = &m_bank[style][r.kind];
        slot->pos = 0; slot->gain = r.gain; slot->rate = r.rate;
    }
    m_tail.store(t, std::memory_order_release);

    std::memset(dst, 0, n * sizeof(float));
    for (auto &v : m_voices) {
        if (!v.buf) continue;
        const auto &s = *v.buf;
        const size_t len = s.size();
        for (uint32_t i = 0; i < n; ++i) {
            const size_t i0 = size_t(v.pos);
            if (i0 + 1 >= len) { v.buf = nullptr; break; }
            const float fr = float(v.pos - double(i0));
            dst[i] += v.gain * (s[i0] + (s[i0 + 1] - s[i0]) * fr);
            v.pos += v.rate;
        }
    }
    for (uint32_t i = 0; i < n; ++i) dst[i] = std::clamp(dst[i], -1.f, 1.f);

    buf->datas[0].chunk->offset = 0;
    buf->datas[0].chunk->stride = sizeof(float);
    buf->datas[0].chunk->size = n * sizeof(float);
    pw_stream_queue_buffer(m_stream, pb);
}
