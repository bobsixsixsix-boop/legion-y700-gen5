# wifi-autoconfig-off.ps1 [-Undo]: switch Windows' WLAN AutoConfig off for good, with a SYSTEM task that reconnects
# (ADMIN; asks for UAC itself).
#
# Why (2026-10-20, README "120 fps 掉帧还没调完美" 根因二): wifi-autoconfig-test.ps1 showed the PC's stall clusters
# every 62 s are Windows' own WLAN background scan: with autoconfig off for 150 s, no cluster, no timeout (runs/
# streaming/wifi-spikes/). Decision: disable it permanently (not needed for normal use here, and it disturbs streaming).
# The catch: without autoconfig Windows connects to nothing by itself - not after a drop, not after a reboot (no
# network, no Tailscale, no remote). So this also installs the scheduled task \y700\WiFi-Reconnect (SYSTEM):
#   triggers  at boot (+30 s), WLAN-AutoConfig event 8003 (disconnected), and every 2 minutes
#   action    if adapter WLAN is not Up: autoconfig on for the moment, let Windows connect (the profile is "Connect
#             automatically"; after 30 s also netsh wlan connect name=<profile>), then autoconfig off again;
#             logged to %ProgramData%\y700\wifi-reconnect.log. Checking the adapter state does not scan.
#   Why not just netsh wlan connect: with autoconfig off Windows refuses both connect and disconnect ("Unable to
#   connect. WLAN auto configuration is disabled on adapter", 10-20; the first version of this task relied on it).
# The action is an inline -Command (no script file a non-admin could edit and have SYSTEM run).
# Then it proves the task end to end: autoconfig on, disconnect, autoconfig off (now offline and stuck, as after a
# drop), run the task, time how long until WLAN is Up with autoconfig off again; then wifi-spikes.ps1 for 150 s.
# -Undo: autoconfig back on, task removed.
param([switch]$Undo)
$ErrorActionPreference = 'Stop'
$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($Undo) { $a += '-Undo' }
    Start-Process powershell.exe -Verb RunAs -ArgumentList $a
    exit
}
# native output: the elevated console decoded netsh's UTF-8 as GBK (10-20 transcript); make both sides UTF-8
[Console]::OutputEncoding = [Text.Encoding]::UTF8
# everything this window shows also goes to %ProgramData%\y700\wifi-autoconfig-off.log (readable without admin)
New-Item -ItemType Directory -Force (Join-Path $env:ProgramData 'y700') | Out-Null
Start-Transcript -Append -Path (Join-Path $env:ProgramData 'y700\wifi-autoconfig-off.log') | Out-Null
# a click in the window starts QuickEdit selection and freezes the script at its next output; switch QuickEdit off
Add-Type -Namespace Y700 -Name Con -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern System.IntPtr GetStdHandle(int h);
[DllImport("kernel32.dll")] public static extern bool GetConsoleMode(System.IntPtr h, out uint m);
[DllImport("kernel32.dll")] public static extern bool SetConsoleMode(System.IntPtr h, uint m);
'@
$h = [Y700.Con]::GetStdHandle(-10); $m = 0
if ([Y700.Con]::GetConsoleMode($h, [ref]$m)) { [void][Y700.Con]::SetConsoleMode($h, ($m -band (-bnot 0x40)) -bor 0x80) }

$If = 'WLAN'
$Task = 'WiFi-Reconnect'
$Dir = Join-Path $env:ProgramData 'y700'
$Log = Join-Path $Dir 'wifi-reconnect.log'

# netsh speaks the UI language: English in some shells, Chinese in the elevated console ("WLAN" 接口上的自动配置逻辑已启用),
# so match on the interface name only (10-20: the English-only match was $null there and the first run died on it)
function Autoconfig { (netsh wlan show settings | Select-String -SimpleMatch $If | Where-Object { $_.Line -notmatch 'Hosted|承载|MAC' } | ForEach-Object { $_.Line.Trim() }) -join '; ' }
# the WLAN profile WLAN is connected with: "Profile" / "配置文件", else the SSID; must exist as a saved profile
function CurrentProfile([string[]]$lines) {
    $m = $lines | Select-String '^\s*(Profile|配置文件)\s*:\s*(.+?)\s*$' | Select-Object -First 1
    if (-not $m) { $m = $lines | Select-String '^\s*(SSID)\s*:\s*(.+?)\s*$' | Select-Object -First 1 }
    if ($m) { $m.Matches[0].Groups[2].Value } else { $null }
}
function WaitUp([int]$s) {
    $t = [Diagnostics.Stopwatch]::StartNew()
    while ($t.Elapsed.TotalSeconds -lt $s) { if ((Get-NetAdapter -Name $If).Status -eq 'Up') { return $t.Elapsed.TotalSeconds }; Start-Sleep -Milliseconds 500 }
    return $null
}

function TaskXml([string]$profileName) {
    $cmd = "`$a = Get-NetAdapter -Name '$If' -ErrorAction SilentlyContinue; if (`$a -and `$a.Status -ne 'Up') { " +
           "`$t0 = Get-Date; netsh wlan set autoconfig enabled=yes interface='$If' | Out-Null; `$n = 0; " +
           "while (`$n -lt 60 -and (Get-NetAdapter -Name '$If').Status -ne 'Up') { if (`$n -eq 30) { netsh wlan connect name='$profileName' interface='$If' | Out-Null }; Start-Sleep 1; `$n++ }; " +
           "`$s = (Get-NetAdapter -Name '$If').Status; Start-Sleep 3; netsh wlan set autoconfig enabled=no interface='$If' | Out-Null; " +
           "Add-Content -Encoding utf8 -Path '$Log' -Value ((Get-Date -Format s) + ' was ' + `$a.Status + ', autoconfig on ' + [int]((Get-Date) - `$t0).TotalSeconds + ' s -> ' + `$s) }"
    $cmd = [Security.SecurityElement]::Escape($cmd)
    $sub = [Security.SecurityElement]::Escape('<QueryList><Query Id="0" Path="Microsoft-Windows-WLAN-AutoConfig/Operational"><Select Path="Microsoft-Windows-WLAN-AutoConfig/Operational">*[System[(EventID=8003)]]</Select></Query></QueryList>')
    $start = (Get-Date).ToString('s')
    return @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>y700 (README 根因二): WLAN AutoConfig is off to stop the 62 s background scans; reconnect $If to $profileName when it is not Up. Undo: wifi-autoconfig-off.ps1 -Undo</Description></RegistrationInfo>
  <Triggers>
    <BootTrigger><Delay>PT30S</Delay></BootTrigger>
    <EventTrigger><Subscription>$sub</Subscription><Delay>PT3S</Delay></EventTrigger>
    <TimeTrigger><StartBoundary>$start</StartBoundary><Repetition><Interval>PT2M</Interval></Repetition></TimeTrigger>
  </Triggers>
  <Principals><Principal id="Author"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <StartWhenAvailable>true</StartWhenAvailable>
    <ExecutionTimeLimit>PT3M</ExecutionTimeLimit>
    <Hidden>false</Hidden>
  </Settings>
  <Actions Context="Author"><Exec><Command>powershell.exe</Command><Arguments>-NoProfile -NonInteractive -WindowStyle Hidden -Command "$cmd"</Arguments></Exec></Actions>
</Task>
"@
}

try {
    "当前：$(Autoconfig)"
    if ($Undo) {
        netsh wlan set autoconfig enabled=yes interface=$If
        if (Get-ScheduledTask -TaskPath '\y700\' -TaskName $Task -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskPath '\y700\' -TaskName $Task -Confirm:$false
            "已删除计划任务 \y700\$Task"
        }
        "已恢复：$(Autoconfig)"
    } else {
        $prof = CurrentProfile (netsh wlan show interfaces)
        if (-not $prof) { throw "WLAN 现在没连着任何网络：先连上要用的 Wi-Fi 再运行" }
        netsh wlan show profile name="$prof" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "找不到名为 $prof 的已保存 Wi-Fi 配置文件（netsh wlan show profiles 看看叫什么）" }
        "要重连的配置文件：$prof"
        New-Item -ItemType Directory -Force $Dir | Out-Null
        Register-ScheduledTask -TaskPath '\y700\' -TaskName $Task -Xml (TaskXml $prof) -Force | Out-Null
        "已装计划任务 \y700\$Task（SYSTEM；开机、断线、每 2 分钟检查一次）"
        ''
        '验证重连（模拟掉线，会断网十几秒）：开自动配置 → 断开 → 关自动配置（这时卡在断网），再让计划任务救回来……'
        netsh wlan set autoconfig enabled=yes interface=$If | Out-Null
        netsh wlan disconnect interface=$If | Out-Null
        for ($i = 0; $i -lt 20 -and (Get-NetAdapter -Name $If).Status -eq 'Up'; $i++) { Start-Sleep -Milliseconds 500 }
        netsh wlan set autoconfig enabled=no interface=$If | Out-Null
        $st = (Get-NetAdapter -Name $If).Status
        "  断开后状态：$st；自动配置：$(Autoconfig)"
        if ($st -eq 'Up') { throw "没能断开 Wi-Fi，重连没验证到（自动配置已关，计划任务已装）" }
        Start-ScheduledTask -TaskPath '\y700\' -TaskName $Task
        $up = WaitUp 70
        if ($null -eq $up) {
            netsh wlan set autoconfig enabled=yes interface=$If | Out-Null
            throw "计划任务 70 秒内没把 Wi-Fi 连回来：已把自动配置打开（会自动重连），请保存这个窗口的内容以便排查"
        }
        "  {0:N1} 秒后重新连上 ✔" -f $up
        for ($i = 0; $i -lt 30 -and (Get-ScheduledTask -TaskPath '\y700\' -TaskName $Task).State -eq 'Running'; $i++) { Start-Sleep 1 }
        "  任务结束后自动配置：$(Autoconfig)"
        if (Test-Path $Log) { '  重连日志最后一行：' + (Get-Content $Log -Tail 1) }
        Start-Sleep 5
        ''
        '复测 150 秒（每秒 ping 网关 20 次；没有成簇的慢包就是好了）：'
        & (Join-Path $PSScriptRoot 'wifi-spikes.ps1') -Seconds 150 | Tee-Object -FilePath (Join-Path $Dir 'wifi-autoconfig-off.txt')
    }
} catch {
    "出错：$_"; $_.InvocationInfo.PositionMessage; $_.ScriptStackTrace
}
Stop-Transcript | Out-Null
Read-Host '按回车关闭'
