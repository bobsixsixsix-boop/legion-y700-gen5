// Key click sounds, synthesised at start-up from the parameters measured on vivo's JoviIme
// (no vivo audio files are used) and played through one low-latency PipeWire stream.
//
// The stream only runs from a key press until 10 s after the last one or until the keyboard hides
// (Osk::click / Osk::hideDone drive setActive): showing the keyboard alone does not wake the speaker
// path, and it can suspend while nobody types. Mixing happens in the PipeWire RT thread; play() only
// pushes a small request into a lock-free ring and never blocks the UI thread.
#pragma once
#include <QObject>
#include <atomic>
#include <array>
#include <vector>

struct pw_thread_loop;
struct pw_stream;

class Sound : public QObject
{
    Q_OBJECT
public:
    enum Kind { Char = 0, Space, Delete, Enter, Tool, Expand, KindCount };
    enum Style { Standard = 0, Soft, Mechanical, StyleCount };

    explicit Sound(QObject *parent = nullptr);
    ~Sound() override;

    bool available() const { return m_loop != nullptr; }   // the stream itself may be rebuilding
    void setActive(bool on);          // run the stream while the owner types (not merely while it is visible)
    void setVolume(int level);        // 0..10, linear like vivo
    void setStyle(int style);         // Standard / Soft / Mechanical
    void play(int kind);              // safe from any thread

    // RT side (public only so the C callbacks can reach it)
    void process();
    void streamFailed();          // any thread: rebuild the stream on the GUI thread

private:
    void synthesise();
    bool connectStream();         // with the loop lock held (or before the loop runs)
    void rebuild();
    std::atomic<bool> m_rebuildQueued{false};

    struct Req { uint8_t kind; float gain; float rate; };
    static constexpr int RING = 64;
    std::array<Req, RING> m_ring{};
    std::atomic<uint32_t> m_head{0}, m_tail{0};

    struct Voice { const std::vector<float> *buf = nullptr; double pos = 0; float gain = 0; float rate = 1; };
    static constexpr int VOICES = 12;
    std::array<Voice, VOICES> m_voices{};

    std::array<std::array<std::vector<float>, KindCount>, StyleCount> m_bank;
    std::atomic<int> m_volume{5};
    std::atomic<int> m_style{Standard};
    bool m_active = false;
    uint32_t m_seed = 0x9e3779b9u;

    pw_thread_loop *m_loop = nullptr;
    pw_stream *m_stream = nullptr;
    struct Hook; Hook *m_hook = nullptr;
};
