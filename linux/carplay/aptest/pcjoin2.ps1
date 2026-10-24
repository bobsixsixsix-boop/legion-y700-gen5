# Join the tablet's throwaway test AP with netsh (a WLAN profile, WPA2-PSK/AES), check DHCP and ping, go back home.
# The profile XML holds the test-only passphrase: written next to this script, imported, deleted at once.
param([string]$Ssid = 'Y700-TEST', [string]$PwFile, [int]$WaitAp = 60, [string]$HomeProfile = 'HOME_6G', [string]$Out,
      [int]$ConnWait = 20)
# -ConnWait: seconds to wait for State=connected; while the state is 'disconnected' the connect is sent again every 4 s
# (the way a phone keeps trying when the access point goes away and comes back, e.g. after a hostapd restart).
$log = New-Object System.Collections.Generic.List[string]
function L($s) { $line = "{0} {1}" -f (Get-Date -Format HH:mm:ss.fff), $s; $log.Add($line); Write-Output $line }
function St() { $o = netsh wlan show interfaces name=WLAN; (($o | Select-String '^\s+(State|SSID|BSSID|Signal|Channel|Radio type|Authentication)\s+:' |
    ForEach-Object { ($_ -replace '^\s+', '') -replace '\s+:\s+', '=' }) -join ' ') }
$xml = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "p-$Ssid.xml"
try {
    # netsh lists what the last scan found; a WinRT scan refreshes that list (Windows scans rarely while connected).
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    [void][Windows.Devices.WiFi.WiFiAdapter, Windows.Devices.WiFi, ContentType = WindowsRuntime]
    $asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
    $act = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction' } | Select-Object -First 1
    $t = $asTask.MakeGenericMethod([System.Collections.Generic.IReadOnlyList[Windows.Devices.WiFi.WiFiAdapter]]).Invoke($null, @([Windows.Devices.WiFi.WiFiAdapter]::FindAllAdaptersAsync()))
    $t.Wait(-1) | Out-Null; $ad = $t.Result[0]
    $deadline = (Get-Date).AddSeconds($WaitAp); $seen = $false
    while (-not $seen -and (Get-Date) -lt $deadline) {
        try { $act.Invoke($null, @($ad.ScanAsync())).Wait(-1) | Out-Null } catch { }
        $seen = [bool](netsh wlan show networks interface=WLAN | Select-String "^SSID \d+ : $([regex]::Escape($Ssid))$")
        if (-not $seen) { Start-Sleep -Seconds 1 }
    }
    if (-not $seen) { L "AP '$Ssid' not in netsh's list in ${WaitAp}s"; return }
    L "AP '$Ssid' listed"
    $pw = [Security.SecurityElement]::Escape((Get-Content $PwFile -Raw).Trim())
    $p = "<?xml version=`"1.0`"?><WLANProfile xmlns=`"http://www.microsoft.com/networking/WLAN/profile/v1`"><name>$Ssid</name>" +
        "<SSIDConfig><SSID><name>$Ssid</name></SSID></SSIDConfig><connectionType>ESS</connectionType><connectionMode>manual</connectionMode>" +
        "<MSM><security><authEncryption><authentication>WPA2PSK</authentication><encryption>AES</encryption><useOneX>false</useOneX></authEncryption>" +
        "<sharedKey><keyType>passPhrase</keyType><protected>false</protected><keyMaterial>$pw</keyMaterial></sharedKey></security></MSM></WLANProfile>"
    Set-Content -Path $xml -Value $p -Encoding ascii
    $r = netsh wlan add profile filename="$xml" interface=WLAN user=current; Remove-Item $xml -Force
    L ("profile: " + ($r -join ' ').Trim())
    $t0 = Get-Date
    $r = netsh wlan connect name=$Ssid ssid=$Ssid interface=WLAN
    L ("connect: " + ($r -join ' ').Trim())
    $ok = $false
    $again = (Get-Date).AddSeconds(4)
    for ($i = 0; $i -lt 2 * $ConnWait -and -not $ok; $i++) {
        Start-Sleep -Milliseconds 500
        $s = St; $ok = $s -match "State=connected" -and $s -match "SSID=$([regex]::Escape($Ssid)) "
        if (-not $ok -and $s -match "State=disconnected" -and (Get-Date) -gt $again) {
            $r = netsh wlan connect name=$Ssid ssid=$Ssid interface=WLAN
            L ("connect again ({0:N1} s): " -f ((Get-Date) - $t0).TotalSeconds + ($r -join ' ').Trim())
            $again = (Get-Date).AddSeconds(4)
        }
    }
    L ("after {0:N1} s: {1}" -f ((Get-Date) - $t0).TotalSeconds, (St))
    if ($ok) {
        $ip = $null
        for ($i = 0; $i -lt 30 -and -not $ip; $i++) {
            $ip = (Get-NetIPAddress -InterfaceAlias WLAN -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -like '192.168.77.*' }).IPAddress
            if (-not $ip) { Start-Sleep -Milliseconds 500 }
        }
        L "DHCP address: $(if ($ip) { $ip } else { 'none in 15 s' })"
        $pg = ping.exe -n 10 -w 1000 192.168.77.1
        L ("ping 192.168.77.1: {0}/10 replies" -f @($pg | Select-String 'TTL=').Count)
    }
} catch { L "error: $($_.Exception.Message)" }
finally {
    if (Test-Path $xml) { Remove-Item $xml -Force }
    netsh wlan connect name=$HomeProfile interface=WLAN | Out-Null
    $back = $false
    for ($i = 0; $i -lt 60 -and -not $back; $i++) {
        Start-Sleep -Milliseconds 500
        $back = Test-Connection -ComputerName 1.1.1.1 -Count 1 -Quiet -ErrorAction SilentlyContinue
    }
    L "home ($HomeProfile) back: $back"
    netsh wlan delete profile name=$Ssid interface=WLAN 2>&1 | Out-Null
    if ($Out) { $log | Set-Content -Path $Out -Encoding utf8 }
}
