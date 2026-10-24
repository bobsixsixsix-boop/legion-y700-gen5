# wifi-noscan.ps1 [-Undo]: stop this PC's Wi-Fi card from leaving its channel every ~62 s (ADMIN; asks for UAC itself).
#
# Why (2026-10-20, README "120 fps 掉帧还没调完美" 根因二): idle, the PC's ping to the gateway showed a ~1.5 s window of
# 24-76 ms replies plus a timeout every 62.3-62.9 s (wifi-spikes.ps1), and every 67 ms frame in the 120 fps stream sat
# on one of them. The MediaTek MT7927 driver had "漫游主动性" (RoamNeedIndicateTh) = 5. 中高 and "省电"
# (LowPowerEnable) = Auto: a roaming threshold that high makes the driver scan for a better AP periodically.
# This sets 漫游主动性 = 1. 已禁用 (registry 0) and 省电 = 已禁用 (0). A desktop PC that never moves does not need to
# roam; the cost is that it will not hop to a closer AP by itself (it still reconnects when the link drops).
# The adapter resets when a property changes: Wi-Fi is gone for a few seconds.
# Afterwards it runs wifi-spikes.ps1 for 150 s and shows the result.
# Backup of the old values: %ProgramData%\y700\wifi-noscan-backup.json; -Undo writes them back.
param([switch]$Undo)
$ErrorActionPreference = 'Stop'
$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($Undo) { $a += '-Undo' }
    Start-Process powershell.exe -Verb RunAs -ArgumentList $a
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
$Keys = @('RoamNeedIndicateTh', 'LowPowerEnable')
$Want = @{ RoamNeedIndicateTh = '0'; LowPowerEnable = '0' }
$Dir = Join-Path $env:ProgramData 'y700'
$Bak = Join-Path $Dir 'wifi-noscan-backup.json'

function Show { Get-NetAdapterAdvancedProperty -Name $Name -RegistryKeyword $Keys |
    ForEach-Object { '  {0} = {1} ({2})' -f $_.DisplayName, $_.DisplayValue, ($_.RegistryValue -join ',') } }

try {
    '当前：'; Show
    if ($Undo) {
        if (-not (Test-Path $Bak)) { throw "没有备份 $Bak，无从恢复" }
        $old = Get-Content $Bak -Raw | ConvertFrom-Json
        foreach ($k in $Keys) { Set-NetAdapterAdvancedProperty -Name $Name -RegistryKeyword $k -RegistryValue $old.$k }
        Remove-Item $Bak
        '已恢复：'; Show
    } else {
        if (-not (Test-Path $Bak)) {
            New-Item -ItemType Directory -Force $Dir | Out-Null
            $cur = @{}
            foreach ($k in $Keys) { $cur[$k] = (Get-NetAdapterAdvancedProperty -Name $Name -RegistryKeyword $k).RegistryValue -join ',' }
            $cur | ConvertTo-Json | Set-Content -Encoding utf8 $Bak
            "原值已备份到 $Bak"
        }
        foreach ($k in $Keys) { Set-NetAdapterAdvancedProperty -Name $Name -RegistryKeyword $k -RegistryValue $Want[$k] }
        '已改为：'; Show
    }
    '等网卡重新连上……'
    for ($i = 0; $i -lt 60 -and (Get-NetAdapter -Name $Name).Status -ne 'Up'; $i++) { Start-Sleep 1 }
    Start-Sleep 5
    if (-not $Undo) {
        '复测 150 秒（每秒 ping 网关 20 次；没有"stall clusters"就是好了）：'
        & (Join-Path $PSScriptRoot 'wifi-spikes.ps1') -Seconds 150
    }
} catch {
    "出错：$_"
}
Read-Host '按回车关闭'
