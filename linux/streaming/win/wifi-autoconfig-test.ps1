# wifi-autoconfig-test.ps1: are the PC's 62 s Wi-Fi stalls Windows' own background scans? (ADMIN; asks for UAC itself)
#
# Why (2026-10-20, README "120 fps 掉帧还没调完美" 根因二): wifi-noscan.ps1 turned the MT7927 driver's roaming and
# power saving off, and wifi-spikes.ps1 still showed stall clusters 62 s apart (runs/streaming/wifi-spikes/). The WLAN
# event log names no caller, and a dozen programs load wlanapi.dll. The usual source of "a ping spike every minute" on
# Windows is WLAN AutoConfig's background scan; this is the A/B for it:
#   netsh wlan set autoconfig enabled=no interface=WLAN   -> the link stays up, Windows stops scanning (and would not
#                                                            reconnect by itself if the link dropped meanwhile)
#   wifi-spikes.ps1 -Seconds 150
#   netsh wlan set autoconfig enabled=yes interface=WLAN  -> always, in finally (closing the window with X skips it:
#                                                            then run this again, it switches it back on at the end)
# The result is shown and also saved to %ProgramData%\y700\wifi-autoconfig-test.txt. Nothing stays changed.
$ErrorActionPreference = 'Stop'
$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    exit
}
# a click in the window starts QuickEdit selection and freezes the script at its next output (10-20: the autoconfig
# test sat frozen with Wi-Fi autoconfig off, title "选择 管理员: ..."); switch QuickEdit off for this console
Add-Type -Namespace Y700 -Name Con -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern System.IntPtr GetStdHandle(int h);
[DllImport("kernel32.dll")] public static extern bool GetConsoleMode(System.IntPtr h, out uint m);
[DllImport("kernel32.dll")] public static extern bool SetConsoleMode(System.IntPtr h, uint m);
'@
$h = [Y700.Con]::GetStdHandle(-10); $m = 0
if ([Y700.Con]::GetConsoleMode($h, [ref]$m)) { [void][Y700.Con]::SetConsoleMode($h, ($m -band (-bnot 0x40)) -bor 0x80) }
$Name = 'WLAN'
$Dir = Join-Path $env:ProgramData 'y700'
$Out = Join-Path $Dir 'wifi-autoconfig-test.txt'
New-Item -ItemType Directory -Force $Dir | Out-Null
try {
    '临时关掉 Windows 的 Wi-Fi 自动配置（连接保持，后台不再扫描）。测试期间别关这个窗口，结束会自动打开。'
    netsh wlan set autoconfig enabled=no interface=$Name
    Start-Sleep 3
    '复测 150 秒（每秒 ping 网关 20 次；没有"stall clusters"就说明是 Windows 自己的后台扫描）：'
    "autoconfig off, $(Get-Date -Format s)" | Set-Content -Encoding utf8 $Out
    & (Join-Path $PSScriptRoot 'wifi-spikes.ps1') -Seconds 150 | Tee-Object -FilePath $Out -Append
} catch {
    "出错：$_"
} finally {
    netsh wlan set autoconfig enabled=yes interface=$Name
    '自动配置已恢复：'
    netsh wlan show settings | Select-String $Name
}
"结果也存在 $Out"
Read-Host '按回车关闭'
