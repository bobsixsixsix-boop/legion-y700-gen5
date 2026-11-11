// What the status bar shows on its right: battery (UPower DisplayDevice), Wi-Fi (NetworkManager primary connection
// and its access point's strength), Bluetooth (BlueZ adapter powered / a device connected), a keyboard's and a mouse's
// own battery (UPower, Bluetooth / USB ones that report it: the Magic Keyboard, the Magic Mouse). All from the system bus,
// signal-driven: any PropertiesChanged of those services schedules one re-read 300 ms later, nothing polls (the
// status bar is mapped all the time and the tablet is power-sensitive).
#pragma once
#include <QObject>
#include <QTimer>

class Status : public QObject
{
    Q_OBJECT
    Q_PROPERTY(int battery READ battery NOTIFY changed)       // 0..100, -1 unknown
    Q_PROPERTY(bool charging READ charging NOTIFY changed)    // charging or full on the charger
    Q_PROPERTY(int wifi READ wifi NOTIFY changed)             // -1 not on Wi-Fi, 0..4 bars
    Q_PROPERTY(bool wired READ wired NOTIFY changed)          // primary connection is not Wi-Fi (USB Ethernet, ...)
    Q_PROPERTY(int bt READ bt NOTIFY changed)                 // 0 off, 1 on, 2 a device connected
    Q_PROPERTY(int kbdBattery READ kbdBattery NOTIFY changed) // 0..100, -1 no keyboard with a battery connected
    Q_PROPERTY(bool kbdCharging READ kbdCharging NOTIFY changed)
    Q_PROPERTY(int mouseBattery READ mouseBattery NOTIFY changed) // 0..100, -1 no mouse with a battery connected
    Q_PROPERTY(bool mouseCharging READ mouseCharging NOTIFY changed)
public:
    explicit Status(QObject *parent = nullptr);
    int battery() const { return m_battery; }
    bool charging() const { return m_charging; }
    int wifi() const { return m_wifi; }
    bool wired() const { return m_wired; }
    int bt() const { return m_bt; }
    int kbdBattery() const { return m_kbdBattery; }
    bool kbdCharging() const { return m_kbdCharging; }
    int mouseBattery() const { return m_mouseBattery; }
    bool mouseCharging() const { return m_mouseCharging; }

Q_SIGNALS:
    void changed();

private Q_SLOTS:
    void kick() { m_debounce.start(); }
    void kickBattery() { readBattery(); }
    void kickPeripherals() { m_periDebounce.start(); }

private:
    void readAll();
    void readBattery();
    void readNetwork();
    void readBluetooth();
    void readPeripherals();

    int m_battery = -1, m_wifi = -1, m_bt = 0, m_kbdBattery = -1, m_mouseBattery = -1;
    bool m_charging = false, m_wired = false, m_kbdCharging = false, m_mouseCharging = false;
    QTimer m_debounce, m_periDebounce;
};
