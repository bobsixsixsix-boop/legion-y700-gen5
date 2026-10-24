// The two aw86927 linear motors (mainline driver: FF_RUMBLE only, 235 Hz fixed). Devices are
// found by name ("aw86927-haptics") and told apart by their i2c address (3-005a / 3-005b), not by
// event number. Which address sits on the left depends on how the tablet is held, so the caller
// passes the screen side and setSwap() flips the mapping (landscape vs inverted landscape).
//
// Effects are uploaded once per (length, magnitude) and replayed with a single write() on a
// worker thread, so a key press never waits on the input layer.
#pragma once
#include <QObject>
#include <condition_variable>
#include <deque>
#include <map>
#include <mutex>
#include <thread>

class Haptics : public QObject
{
    Q_OBJECT
public:
    explicit Haptics(QObject *parent = nullptr);
    ~Haptics() override;

    bool available() const { return m_fd[0] >= 0 || m_fd[1] >= 0; }
    // side: 'L', 'R' or 'B' (both); ms: 4..60; magnitude: 0..0xFFFF
    void pulse(char side, int ms, int magnitude);
    void setSwap(bool swap) { m_swap = swap; }
    void setLeftAddress(const QString &addr) { m_leftAddr = addr; }

private:
    void worker();
    int effectFor(int dev, int ms, int mag);
    void play(int dev, int ms, int mag);

    int m_fd[2] = { -1, -1 };          // [0] = 3-005a, [1] = 3-005b
    std::map<std::pair<int, int>, int> m_effects[2];
    QString m_leftAddr = QStringLiteral("3-005b");
    bool m_swap = false;

    struct Job { int dev, ms, mag; };
    std::deque<Job> m_jobs;
    std::mutex m_mx;
    std::condition_variable m_cv;
    bool m_quit = false;
    std::thread m_thread;
};
