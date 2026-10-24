# wifi-spikes.ps1 [-Seconds 210] [-Target 192.168.0.1] [-Threshold 12]
# Does this PC's own Wi-Fi link stall periodically?  Pings the gateway 20 times a second and prints every reply at or
# above Threshold ms (and every timeout) with its time, then the spacing between the stall clusters.
#
# Why (2026-10-20): the 66.7 ms frames in the 120 fps stream (0.1 % low ~31 fps, about one per minute) came from this
# PC, not the tablet: at the moment of each stall the tablet's RTT to the gateway stayed at 3-5 ms while the PC's ping
# to the gateway jumped to 15-50 ms. Idle, with nothing streaming, the PC showed a ~1.5 s window of 24-76 ms replies
# plus a timeout every ~62 s -- the WLAN card leaving its channel to scan. Run this after changing a Wi-Fi setting:
# no clusters in 3.5 minutes = fixed. Plain ICMP, no admin needed.
param([int]$Seconds = 210, [string]$Target = '192.168.0.1', [int]$Threshold = 12)
$p = New-Object System.Net.NetworkInformation.Ping
$sw = [Diagnostics.Stopwatch]::StartNew()
$n = 0; $hits = @()
while ($sw.Elapsed.TotalSeconds -lt $Seconds) {
    $r = $p.Send($Target, 500); $n++
    if ($r.Status -ne 'Success' -or $r.RoundtripTime -ge $Threshold) {
        $t = $sw.Elapsed.TotalSeconds
        $hits += $t
        '{0,7:N2} s  {1}' -f $t, $(if ($r.Status -eq 'Success') { "$($r.RoundtripTime) ms" } else { $r.Status })
    }
    Start-Sleep -Milliseconds 50
}
# clusters: hits less than 3 s apart belong together
$starts = @(); $last = -10
foreach ($t in $hits) { if ($t - $last -gt 3) { $starts += $t }; $last = $t }
$gaps = for ($i = 1; $i -lt $starts.Count; $i++) { '{0:N1}' -f ($starts[$i] - $starts[$i - 1]) }
"pings $n in $Seconds s, $($hits.Count) slow/lost, $($starts.Count) stall clusters" +
    $(if ($gaps) { ", spacing $($gaps -join ' / ') s" } else { '' })
