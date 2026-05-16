# Phase 0 critical test: can we leave BIOS fan mode (0x2F != 0x80)?
# Run elevated on the P52 after build.ps1.
#
# Usage:
#   .\scripts\test-p52-ec-write.ps1
#   .\scripts\test-p52-ec-write.ps1 -StopLenovoServices
#   .\scripts\test-p52-ec-write.ps1 -FanLevel 4 -MuxFan1 0x40 -MuxFan2 0x41

#requires -RunAsAdministrator

param(
    [switch]$StopLenovoServices,
    [switch]$KeepNbfcRunning,
    [int]$FanLevel = 3,
    [int]$MuxFan1 = 0x40,
    [int]$MuxFan2 = 0x41,
    [int]$FanControlRegister = 0x2F,
    [int]$FanSwitchRegister = 0x31
)

$ErrorActionPreference = "Stop"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$ThinkPadPlugin = "StagWare.Plugins.ECThinkPad"
$NbfcServiceName = "NoteBook FanControl Service"

function Get-EcProbePath {
    foreach ($rel in @(
            "Core\NbfcProbe\bin\Release\ec-probe.exe",
            "Core\NbfcProbe\bin\ReleaseWindows\ec-probe.exe"
        )) {
        $path = Join-Path $RepoRoot $rel
        if (Test-Path $path) { return $path }
    }
    $nbfc = Get-Command nbfc -ErrorAction SilentlyContinue
    if ($nbfc) {
        $installed = Join-Path (Split-Path $nbfc.Source) "ec-probe.exe"
        if (Test-Path $installed) { return $installed }
    }
    throw "ec-probe.exe not found. Run .\scripts\build.ps1"
}

function Invoke-EcProbe {
    param(
        [string[]]$CommandArgs,
        [switch]$AllowFailure
    )
    $all = @("--plugin", $ThinkPadPlugin) + $CommandArgs
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $out = & $script:EcProbePath @all 2>&1
        $exit = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $prev
    }
    $text = ($out | ForEach-Object { "$_" }) -join [Environment]::NewLine
    if ($text -match "usage:\s*ec-probe" -and -not $AllowFailure) {
        throw "ec-probe failed: $text"
    }
    return @{ Text = $text; ExitCode = $exit }
}

function Stop-NbfcForEcAccess {
    if ($KeepNbfcRunning) {
        Write-Host "NBFC service left running (-KeepNbfcRunning)." -ForegroundColor DarkGray
        return
    }

    $svc = Get-Service $NbfcServiceName -ErrorAction SilentlyContinue
    if (-not $svc) { return }

    if ($svc.Status -eq "Running") {
        Write-Host "Stopping NBFC (releases EC mutex)..." -ForegroundColor Cyan
        $nbfc = Get-Command nbfc -ErrorAction SilentlyContinue
        if ($nbfc) {
            & $nbfc.Source stop 2>&1 | Out-Null
        }
        Stop-Service $NbfcServiceName -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }
}

function Stop-LenovoThermalServices {
    Write-Host "Stopping known Lenovo thermal services..." -ForegroundColor Cyan
    foreach ($name in @(
            "LenovoFanTableService", "IBMPMSVC",
            "Lenovo Intelligent Cooling", "LenovoICM",
            "LenovoVantageService", "Lenovo Instant On"
        )) {
        try {
            $svc = Get-Service $name -ErrorAction Stop
            if ($svc.Status -eq "Running") {
                Stop-Service $name -Force
                Write-Host "  stopped: $name"
            }
        }
        catch { }
    }
    Start-Sleep -Seconds 2
}

function Test-EcProbeThinkPadFanTest {
    $args = @(
        "thinkpad-fan-test",
        "--level", $FanLevel,
        "--mux-fan1", $MuxFan1,
        "--mux-fan2", $MuxFan2,
        "--fan-control", $FanControlRegister,
        "--fan-switch", $FanSwitchRegister
    )
    return Invoke-EcProbe -CommandArgs $args -AllowFailure
}

if ($StopLenovoServices) {
    Stop-LenovoThermalServices
}

Stop-NbfcForEcAccess

$script:EcProbePath = Get-EcProbePath
Write-Host "ec-probe: $script:EcProbePath"
Write-Host ""

$probe = Test-EcProbeThinkPadFanTest
if ($probe.Text) {
    Write-Host $probe.Text
}

if ($probe.Text -match "Unknown verb") {
    Write-Warning "ec-probe too old (no thinkpad-fan-test). Rebuild: .\scripts\build.ps1"
    exit 4
}

$before = $null
$after1 = $null
$after2 = $null
if ($probe.Text -match "before=(\d+)") { $before = [int]$Matches[1] }
if ($probe.Text -match "after_fan1=(\d+)") { $after1 = [int]$Matches[1] }
if ($probe.Text -match "after_fan2=(\d+)") { $after2 = [int]$Matches[1] }

Write-Host ""
Write-Host ("Summary: before=0x{0:X2}  fan1=0x{1:X2}  fan2=0x{2:X2}  target level={3}" -f `
    $(if ($null -ne $before) { $before } else { 0 }), `
    $(if ($null -ne $after1) { $after1 } else { 0 }), `
    $(if ($null -ne $after2) { $after2 } else { 0 }), `
    $FanLevel)

# Trust readback after mux; ignore before=0x80 (BIOS idle when NBFC was stopped).
$exitCode = $probe.ExitCode
$afterBiosLocked = $false
if ($probe.Text -match "after_bios_locked=yes") {
    $afterBiosLocked = $true
}
elseif ($probe.Text -match "after_bios_locked=no") {
    $afterBiosLocked = $false
}
elseif ($null -ne $after1 -or $null -ne $after2) {
    $afterBiosLocked = (($after1 -band 0x80) -ne 0) -or (($after2 -band 0x80) -ne 0)
}

$levelOk = ($null -ne $after1) -and ($null -ne $after2) `
    -and (($after1 -band 0x7F) -eq ($FanLevel -band 0x7F)) `
    -and (($after2 -band 0x7F) -eq ($FanLevel -band 0x7F))

if (-not $afterBiosLocked -and $levelOk) {
    $exitCode = 0
}
elseif ($afterBiosLocked) {
    $exitCode = 1
}
elseif (-not $levelOk -and -not $afterBiosLocked) {
    $exitCode = 2
}

if ($null -ne $before -and ($before -band 0x80) -and $exitCode -eq 0) {
    Write-Host "Note: before=0x80 is normal when NBFC was stopped; writes still succeeded." -ForegroundColor DarkGray
}

switch ($exitCode) {
    0 {
        Write-Host "PASS: Manual fan level accepted by EC (readback after mux write)." -ForegroundColor Green
    }
    1 {
        Write-Host "FAIL: EC readback still in BIOS mode (0x80) after write." -ForegroundColor Red
        Write-Host "Try: -StopLenovoServices, disable Lenovo Vantage thermal, reboot." -ForegroundColor Yellow
    }
    2 {
        Write-Host "PARTIAL: Not BIOS-locked, but readback differs from level $FanLevel." -ForegroundColor Yellow
        Write-Host "NBFC may still work if fan RPM changes; check with nbfc set-fan-speed." -ForegroundColor DarkGray
    }
    3 {
        Write-Host "FAIL: Could not acquire EC lock. Stop NBFC and Lenovo services." -ForegroundColor Red
    }
    default {
        Write-Host "FAIL: ec-probe exited with code $($probe.ExitCode)" -ForegroundColor Red
    }
}

exit $exitCode
