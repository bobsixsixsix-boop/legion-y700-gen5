# Join Y700-T<Start>..Y700-T<K> in turn (one per tablet AP session of apjoin.sh), each with pcjoin2.ps1 (netsh).
# WinRT ConnectAsync answered NetworkNotAvailable in 0.8 s without sending a frame (10-17 19:35), netsh joins.
param([int]$K = 6, [int]$Start = 1, [int]$WaitAp = 150, [string]$PwFile, [string]$OutDir, [int]$ConnWait = 20)
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
New-Item -ItemType Directory -Force $OutDir | Out-Null
for ($i = $Start; $i -le $K; $i++) {
    & (Join-Path $here 'pcjoin2.ps1') -Ssid "Y700-T$i" -PwFile $PwFile -WaitAp $WaitAp -ConnWait $ConnWait -Out (Join-Path $OutDir "pc$i.txt") | Out-Null
}
Get-ChildItem $OutDir -Filter 'pc*.txt' | Sort-Object Name | ForEach-Object { "== $($_.Name)"; Get-Content $_.FullName }
