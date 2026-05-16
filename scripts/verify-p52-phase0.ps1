# Phase 0: Verify ThinkPad P52 EC registers on the real machine.
# Run in an elevated PowerShell on the P52 (Admin required for EC port I/O).
#
# Usage:
#   .\scripts\verify-p52-phase0.ps1
#   .\scripts\verify-p52-phase0.ps1 -StopLenovoServices
#   .\scripts\verify-p52-phase0.ps1 -AllowWriteTests   # optional mux probing (writes EC)
#   .\scripts\verify-p52-phase0.ps1 -MonitorSeconds 120

#requires -RunAsAdministrator

param(
    [string]$EcProbePath = "",
    [string]$ReportDir = "",
    [switch]$StopLenovoServices,
    [switch]$AllowWriteTests,
    [int]$MonitorSeconds = 60,
    [int]$MonitorInterval = 2
)

$ErrorActionPreference = "Stop"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ([string]::IsNullOrWhiteSpace($EcProbePath)) {
    $candidates = @(
        "$RepoRoot\Core\NbfcProbe\bin\Release\ec-probe.exe",
        "$RepoRoot\Core\NbfcProbe\bin\ReleaseWindows\ec-probe.exe"
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { $EcProbePath = $c; break }
    }
}

if (-not (Test-Path $EcProbePath)) {
    throw "ec-probe.exe not found. Build first: .\scripts\build.ps1"
}

$ProbeDir = Split-Path -Parent $EcProbePath
$PluginsDir = Join-Path $ProbeDir "Plugins"
if (-not (Test-Path (Join-Path $PluginsDir "StagWare.Plugins.ECThinkPad.dll"))) {
    Write-Warning "StagWare.Plugins.ECThinkPad.dll missing in $PluginsDir - run .\scripts\build.ps1"
}

if ([string]::IsNullOrWhiteSpace($ReportDir)) {
    $ReportDir = Join-Path $RepoRoot ("reports\p52-phase0-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
}
New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null

$ThinkPadPlugin = "StagWare.Plugins.ECThinkPad"
$script:ProbePrefix = @("--plugin", $ThinkPadPlugin)

function Invoke-EcProbe {
  param([string[]]$CommandArgs)
  if (-not $CommandArgs) { throw "Invoke-EcProbe: no arguments" }
  $all = $script:ProbePrefix + $CommandArgs
  $out = & $EcProbePath @all 2>&1
  $code = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 0 }
  $text = ($out | ForEach-Object { "$_" }) -join [Environment]::NewLine
  if ($text -match 'usage:\s*ec-probe' -or $text -match 'Extra positional arguments') {
    $code = 1
  }
  return [PSCustomObject]@{ ExitCode = $code; Output = $text }
}

function Read-EcByte([int]$Register) {
  $r = Invoke-EcProbe @("read", "$Register")
  if ($r.ExitCode -ne 0) { return $null }
  if ($r.Output -match '^\s*(\d+)') { return [int]$Matches[1] }
  return $null
}

function Write-EcByte([int]$Register, [int]$Value) {
  Invoke-EcProbe @("write", "$Register", "$Value", "-v") | Out-Null
}

# --- Lenovo services ---
$lenovoServices = @(
    "LenovoFanTableService",
    "IBMPMSVC",
    "Lenovo Intelligent Cooling",
    "LenovoICM"
)

$serviceLog = @()
foreach ($name in $lenovoServices) {
    try {
        $sc = Get-Service -Name $name -ErrorAction Stop
        $serviceLog += [PSCustomObject]@{ Service = $name; Status = $sc.Status.ToString() }
    }
    catch {
        $serviceLog += [PSCustomObject]@{ Service = $name; Status = "not installed" }
    }
}
$serviceLog | Export-Csv (Join-Path $ReportDir "lenovo-services.csv") -NoTypeInformation

if ($StopLenovoServices) {
    Write-Host "Stopping Lenovo fan/thermal services..." -ForegroundColor Cyan
    foreach ($name in $lenovoServices) {
        try {
            $sc = Get-Service -Name $name -ErrorAction Stop
            if ($sc.Status -eq 'Running') {
                Stop-Service -Name $name -Force
                Write-Host "  stopped: $name"
            }
        }
        catch { }
    }
    Start-Sleep -Seconds 2
}

# --- Full dump ---
Write-Host "EC dump (ThinkPad plugin)..." -ForegroundColor Cyan
$dump = Invoke-EcProbe @("dump")
$dump.Output | Out-File (Join-Path $ReportDir "ec-dump.txt") -Encoding UTF8
Write-Host $dump.Output

# --- Key registers (TPFanCtrl2 reference) ---
$keyRegs = [ordered]@{
    "0x2F Fan control"       = 0x2F
    "0x31 Fan switch"      = 0x31
    "0x84 Fan speed lo"    = 0x84
    "0x85 Fan speed hi"    = 0x85
    "0x78 Temp0"           = 0x78
    "0x79 Temp1"           = 0x79
    "0x7A Temp2"           = 0x7A
    "0x7B Temp3"           = 0x7B
    "0x7C Temp4"           = 0x7C
    "0x7D Temp5"           = 0x7D
    "0x7E Temp6"           = 0x7E
    "0x7F Temp7"           = 0x7F
    "0xC0 Temp8"           = 0xC0
    "0xC1 Temp9"           = 0xC1
    "0xC2 Temp10"          = 0xC2
    "0xC3 Temp11"          = 0xC3
}

$snapshot = foreach ($label in $keyRegs.Keys) {
    $reg = $keyRegs[$label]
    $val = Read-EcByte $reg
    [PSCustomObject]@{
        Label = $label
        Register = "0x{0:X2}" -f $reg
        Decimal = $val
        Hex = if ($null -eq $val) { "" } else { "0x{0:X2}" -f $val }
        BiosMode = if ($val -eq 128) { "yes (0x80)" } else { "" }
    }
}
$snapshot | Format-Table -AutoSize
$snapshot | Export-Csv (Join-Path $ReportDir "key-registers.csv") -NoTypeInformation

$fanCtrl = Read-EcByte 0x2F
if ($fanCtrl -eq 128) {
    Write-Host ""
    Write-Host "NOTE: Register 0x2F = 0x80 -> BIOS controls the fan. Lenovo service may be active." -ForegroundColor Yellow
    Write-Host "      Use -StopLenovoServices and ensure no other fan tool is running." -ForegroundColor Yellow
}

# --- Fan switch candidates ---
$switchCandidates = @(1, 2, 0x40, 0x41, 0x80, 0x81)
$muxResults = @()

if ($AllowWriteTests) {
    Write-Host ""
    Write-Host "Fan multiplex test (writes 0x31, reads 0x2F and RPM)..." -ForegroundColor Cyan
    Write-Host "Fans may spin briefly. Press Ctrl+C to abort." -ForegroundColor Yellow

    foreach ($sel in $switchCandidates) {
        Write-EcByte 0x31 $sel
        Start-Sleep -Milliseconds 150
        $fc = Read-EcByte 0x2F
        $rpmLo = Read-EcByte 0x84
        $rpmHi = Read-EcByte 0x85
        $rpm = if ($null -ne $rpmLo -and $null -ne $rpmHi) { ($rpmHi -shl 8) -bor $rpmLo } else { $null }

        $muxResults += [PSCustomObject]@{
            SwitchValueDec = $sel
            SwitchValueHex = "0x{0:X2}" -f $sel
            FanControl_2F = $fc
            FanControlHex = if ($null -eq $fc) { "" } else { "0x{0:X2}" -f $fc }
            Rpm = $rpm
        }
        Write-Host ("  switch 0x31 <= 0x{0:X2}  ->  0x2F={1}  RPM={2}" -f $sel, $muxResults[-1].FanControlHex, $rpm)
    }

    $muxResults | Export-Csv (Join-Path $ReportDir "fan-switch-test.csv") -NoTypeInformation

    $validRpm = $muxResults | Where-Object { $null -ne $_.Rpm -and $_.Rpm -gt 0 -and $_.Rpm -lt 30000 }
    $fan1 = $validRpm | Where-Object { $_.SwitchValueDec -eq 0x40 } | Select-Object -First 1
    $fan2 = $validRpm | Where-Object { $_.SwitchValueDec -eq 0x41 } | Select-Object -First 1
    if ($fan1 -and $fan2) {
        Write-Host ""
        Write-Host "Suggested FanSwitchValue: fan1=64 (0x40) RPM=$($fan1.Rpm), fan2=65 (0x41) RPM=$($fan2.Rpm)" -ForegroundColor Green
    }
    elseif ($validRpm.Count -ge 2) {
        $sorted = $validRpm | Sort-Object Rpm -Descending
        Write-Host ""
        Write-Host "Suggested FanSwitchValue (by RPM): fan1=$($sorted[0].SwitchValueDec), fan2=$($sorted[-1].SwitchValueDec)" -ForegroundColor Yellow
    }
}
else {
    Write-Host ""
    Write-Host "Skipping write tests (use -AllowWriteTests to probe fan switch values 1, 2, 0x40, 0x41)." -ForegroundColor DarkGray
}

# --- Monitor changing registers ---
if ($MonitorSeconds -gt 0) {
    Write-Host ""
    Write-Host "Monitoring EC for ${MonitorSeconds}s (interval ${MonitorInterval}s)..." -ForegroundColor Cyan
    Write-Host "Stress the CPU/GPU or change fan mode in Vantage/BIOS to see which registers move." -ForegroundColor DarkGray

    if ($AllowWriteTests) {
        Write-Host "Pausing 5s after mux writes before monitor (WinRing0 driver recovery)..." -ForegroundColor DarkGray
        Start-Sleep -Seconds 5
    }

    $reportCsv = Join-Path $ReportDir "ec-monitor.csv"
    $monArgs = $script:ProbePrefix + @(
        "monitor", "-t", "$MonitorSeconds", "-i", "$MonitorInterval",
        "-r", $reportCsv, "-c"
    )
    Write-Host "Running: $EcProbePath $($monArgs -join ' ')" -ForegroundColor DarkGray
    # Do not capture stdout: ec-probe monitor uses Console.Clear (fails on redirected handles).
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & $EcProbePath @monArgs
        if (-not (Test-Path $reportCsv)) {
            Write-Warning "EC monitor did not create $reportCsv"
        }
    }
    catch {
        Write-Warning "EC monitor failed: $_"
    }
    finally {
        $ErrorActionPreference = $prevEap
    }
}

# --- Summary / config hints ---
$summary = @"
Phase 0 report: $(Get-Date -Format o)
Machine: $env:COMPUTERNAME
ec-probe: $EcProbePath
Plugin: $ThinkPadPlugin

Expected for Lenovo ThinkPad P52 (verify on this machine):
  FanControl register     : 0x2F  (current: $(if ($null -eq $fanCtrl) { '?' } else { "0x{0:X2}" -f $fanCtrl }))
  FanSwitch register      : 0x31
  FanSpeed register (lo)  : 0x84 (+1 for hi byte)
  Fan1 switch value       : 64 (0x40) if mux test matched P50 pair
  Fan2 switch value       : 65 (0x41) if mux test matched P50 pair
  EcPluginId in XML       : StagWare.Plugins.ECThinkPad

Files in: $ReportDir
  key-registers.csv
  ec-dump.txt
  lenovo-services.csv
  fan-switch-test.csv (if -AllowWriteTests)
  ec-monitor.csv (if monitoring ran)

Update Configs\Lenovo ThinkPad P52.xml with verified FanSwitchValue entries.
"@

$summary | Out-File (Join-Path $ReportDir "SUMMARY.txt") -Encoding UTF8
Write-Host ""
Write-Host $summary -ForegroundColor Green
Write-Host "Report folder: $ReportDir" -ForegroundColor Cyan
