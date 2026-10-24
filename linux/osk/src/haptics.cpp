#include "haptics.h"

#include <QDebug>
#include <QDir>
#include <QFile>
#include <QFileInfo>

#include <fcntl.h>
#include <linux/input.h>
#include <sys/ioctl.h>
#include <unistd.h>

#include <algorithm>

Haptics::Haptics(QObject *parent) : QObject(parent)
{
    const QDir sys(QStringLiteral("/sys/class/input"));
    for (const QString &e : sys.entryList({ QStringLiteral("event*") }, QDir::Dirs | QDir::System)) {
        QFile nf(sys.filePath(e + QStringLiteral("/device/name")));
        if (!nf.open(QIODevice::ReadOnly) || nf.readAll().trimmed() != "aw86927-haptics") continue;
        const QString bus = QFileInfo(sys.filePath(e + QStringLiteral("/device/device"))).canonicalFilePath().section(QLatin1Char('/'), -1);
        const int slot = bus.endsWith(QLatin1String("5a")) ? 0 : bus.endsWith(QLatin1String("5b")) ? 1 : -1;
        if (slot < 0 || m_fd[slot] >= 0) continue;
        const QByteArray dev = QByteArray("/dev/input/") + e.toLatin1();
        m_fd[slot] = ::open(dev.constData(), O_RDWR | O_NONBLOCK | O_CLOEXEC);
        if (m_fd[slot] < 0) qWarning() << "haptics: cannot open" << dev;
    }
    if (!available()) qWarning() << "haptics: no aw86927 motors";
    m_thread = std::thread([this] { worker(); });
}

Haptics::~Haptics()
{
    { std::lock_guard<std::mutex> l(m_mx); m_quit = true; }
    m_cv.notify_all();
    if (m_thread.joinable()) m_thread.join();
    for (int d = 0; d < 2; ++d) {
        if (m_fd[d] < 0) continue;
        for (auto &kv : m_effects[d]) ioctl(m_fd[d], EVIOCRMFF, kv.second);
        ::close(m_fd[d]);
    }
}

void Haptics::pulse(char side, int ms, int magnitude)
{
    if (!available() || ms <= 0 || magnitude <= 0) return;
    // slot of the motor on the screen's left
    int left = m_leftAddr.endsWith(QLatin1String("5a")) ? 0 : 1;
    if (m_swap) left = 1 - left;
    const int right = 1 - left;
    ms = std::clamp(ms, 4, 60);
    magnitude = std::clamp(magnitude, 1, 0xFFFF);
    {
        std::lock_guard<std::mutex> l(m_mx);
        if (m_jobs.size() > 8) m_jobs.clear();     // never let a backlog buzz on after typing stops
        if (side == 'L' || side == 'B') m_jobs.push_back({ left, ms, magnitude });
        if (side == 'R' || side == 'B') m_jobs.push_back({ right, ms, magnitude });
    }
    m_cv.notify_one();
}

void Haptics::worker()
{
    for (;;) {
        Job j;
        {
            std::unique_lock<std::mutex> l(m_mx);
            m_cv.wait(l, [this] { return m_quit || !m_jobs.empty(); });
            if (m_quit) return;
            j = m_jobs.front();
            m_jobs.pop_front();
        }
        play(j.dev, j.ms, j.mag);
    }
}

int Haptics::effectFor(int dev, int ms, int mag)
{
    auto key = std::make_pair(ms, mag);
    auto it = m_effects[dev].find(key);
    if (it != m_effects[dev].end()) return it->second;
    if (m_effects[dev].size() >= 12) {             // keep well under the driver's slot count
        for (auto &kv : m_effects[dev]) ioctl(m_fd[dev], EVIOCRMFF, kv.second);
        m_effects[dev].clear();
    }
    ff_effect e{};
    e.type = FF_RUMBLE;
    e.id = -1;
    e.replay.length = uint16_t(ms);
    e.u.rumble.strong_magnitude = uint16_t(mag);
    e.u.rumble.weak_magnitude = uint16_t(mag);
    if (ioctl(m_fd[dev], EVIOCSFF, &e) < 0) return -1;
    m_effects[dev][key] = e.id;
    return e.id;
}

void Haptics::play(int dev, int ms, int mag)
{
    if (dev < 0 || dev > 1 || m_fd[dev] < 0) return;
    const int id = effectFor(dev, ms, mag);
    if (id < 0) return;
    input_event ev{};
    ev.type = EV_FF;
    ev.code = uint16_t(id);
    ev.value = 1;
    if (::write(m_fd[dev], &ev, sizeof ev) < 0) { /* motor busy or gone: drop this tick */ }
}
