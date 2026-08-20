param(
    [string]$AdbPath = "adb",
    [string]$Serial = "",
    [string]$PackageName = "com.granivpn.mobile",
    [switch]$RemoveTask,
    [ValidateRange(1, 60)]
    [int]$WaitSeconds = 8,
    [string]$OutputDirectory = ""
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $OutputDirectory = Join-Path $env:TEMP "grani-runtime-probe-$stamp"
}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

$adbPrefix = @()
if (-not [string]::IsNullOrWhiteSpace($Serial)) {
    $adbPrefix = @("-s", $Serial)
}

function Invoke-Adb {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $output = & $AdbPath @adbPrefix @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "adb failed ($LASTEXITCODE): $($Arguments -join ' ')`n$output"
    }
    return @($output)
}

function Save-Snapshot {
    param([Parameter(Mandatory = $true)][string]$Name)

    $snapshotPath = Join-Path $OutputDirectory "$Name.txt"
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("timestamp=$(Get-Date -Format o)")
    $lines.Add("package=$PackageName")
    $lines.Add("serial=$Serial")
    $lines.Add("")
    $lines.Add("=== pidof ===")
    $lines.AddRange([string[]](Invoke-Adb -Arguments @("shell", "pidof", $PackageName)))
    $lines.Add("")
    $lines.Add("=== foreground VPN service ===")
    $serviceDump = Invoke-Adb -Arguments @("shell", "dumpsys", "activity", "services", $PackageName)
    $lines.AddRange([string[]]$serviceDump)
    $lines.Add("")
    $lines.Add("=== connectivity VPN lines ===")
    $connectivity = Invoke-Adb -Arguments @("shell", "dumpsys", "connectivity")
    $vpnLines = $connectivity | Select-String -Pattern "VPN|TRANSPORT_VPN|NetworkAgent" -CaseSensitive:$false
    $lines.AddRange([string[]]$vpnLines)
    $lines.Add("")
    $lines.Add("=== recent GRANI runtime logs ===")
    $logcat = Invoke-Adb -Arguments @("logcat", "-d", "-t", "800")
    $runtimeLogs = $logcat | Select-String -Pattern (
        "GraniVpnService|VpnPlugin|XrayNativeWrapper|Tun2Socks|Hysteria2|Amnezia|" +
        "task_removed|binder|VpnNativeStateEmitter"
    ) -CaseSensitive:$false
    $lines.AddRange([string[]]$runtimeLogs)
    $lines | Set-Content -LiteralPath $snapshotPath -Encoding UTF8
    return @{
        Path = $snapshotPath
        ServiceDump = @($serviceDump)
        Pid = @(Invoke-Adb -Arguments @("shell", "pidof", $PackageName))
    }
}

$devices = Invoke-Adb -Arguments @("devices")
if (-not ($devices | Select-String -Pattern "\sdevice$")) {
    throw "No authorized adb device is available. Start the GRANI emulator or attach a phone."
}

$before = Save-Snapshot -Name "before"
Write-Host "Baseline saved: $($before.Path)"

if (-not $RemoveTask) {
    Write-Host "Read-only probe complete. Re-run with -RemoveTask while VPN is connected to test task removal."
    exit 0
}

$activities = Invoke-Adb -Arguments @("shell", "dumpsys", "activity", "activities")
$taskLine = $activities |
    Select-String -SimpleMatch $PackageName |
    Where-Object { $_.Line -match "Task\{" } |
    Select-Object -First 1

if ($null -eq $taskLine -or $taskLine.Line -notmatch "#(\d+)") {
    throw "Could not resolve the Android task id for $PackageName. Open the app before the probe."
}

$taskId = $Matches[1]
Write-Host "Removing only Android task $taskId; app data and package stay intact."
Invoke-Adb -Arguments @("shell", "am", "task", "remove", $taskId) | Out-Null
Start-Sleep -Seconds $WaitSeconds

$after = Save-Snapshot -Name "after-task-removal"
Write-Host "Post-removal snapshot saved: $($after.Path)"

$serviceAlive = ($after.ServiceDump -join "`n") -match "GraniVpnService"
$processAlive = -not [string]::IsNullOrWhiteSpace(($after.Pid -join ""))
if (-not $serviceAlive -or -not $processAlive) {
    Write-Error "FAIL: foreground VPN runtime did not survive task removal (process=$processAlive service=$serviceAlive)."
    exit 2
}

Write-Host "PASS: GRANI foreground VPN service and process survived actual task removal."
exit 0
