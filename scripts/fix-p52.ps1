# Apply ThinkPad P52 fork config and verify NBFC fork installation on this machine.
# Run in an elevated PowerShell on the P52.
#
# Usage:
#   .\scripts\fix-p52.ps1
#   .\scripts\fix-p52.ps1 -InstallMsi
#   .\scripts\fix-p52.ps1 -SyncBinaries    # copy ec-probe + plugins from repo build
#   .\scripts\fix-p52.ps1 -ResetSettings   # clear saved 1-fan service settings
#   .\scripts\fix-p52.ps1 -SkipCopy

#requires -RunAsAdministrator

param(
    [string]$ConfigName = "Lenovo ThinkPad P52",
    [switch]$InstallMsi,
    [switch]$SyncBinaries,
    [switch]$ResetSettings,
    [switch]$SkipCopy,
    [switch]$RunEcWriteTest
)

$ErrorActionPreference = "Stop"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$SourceConfig = Join-Path $RepoRoot "Configs\$ConfigName.xml"
$MsiPath = Join-Path $RepoRoot "Windows\Setup\NbfcSetup\bin\Release\NbfcSetup.msi"
$ServiceName = "NoteBook FanControl Service"
$SettingsFile = Join-Path $env:ProgramData "NbfcService\NbfcServiceSettings.xml"

function Write-Step([string]$Message) {
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Resolve-P52ConfigName([string]$InstallRoot, [string]$PreferredName) {
    $configsDir = Join-Path $InstallRoot "Configs"
    $preferredFile = Join-Path $configsDir "$PreferredName.xml"
    if (Test-Path $preferredFile) {
        return $PreferredName
    }

    $match = Get-ChildItem -Path $configsDir -Filter "*P52*.xml" -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($match) {
        return [System.IO.Path]::GetFileNameWithoutExtension($match.Name)
    }

    return $PreferredName
}

function Get-NbfcInstallRoot {
    $cmd = Get-Command nbfc -ErrorAction SilentlyContinue
    if (-not $cmd) { return $null }
    return Split-Path $cmd.Source
}

function Get-RepoDeployPaths {
    $serviceRoot = $null
    foreach ($rel in @(
            "Core\NbfcService\bin\ReleaseWindows",
            "Core\NbfcService\bin\Release"
        )) {
        $path = Join-Path $RepoRoot $rel
        if (Test-Path (Join-Path $path "NbfcService.exe")) {
            $serviceRoot = $path
            break
        }
    }

    $cliExe = $null
    foreach ($rel in @(
            "Core\NbfcCli\bin\ReleaseWindows\nbfc.exe",
            "Core\NbfcCli\bin\Release\nbfc.exe"
        )) {
        $path = Join-Path $RepoRoot $rel
        if (Test-Path $path) { $cliExe = $path; break }
    }

    $probeExe = $null
    foreach ($rel in @(
            "Core\NbfcProbe\bin\Release\ec-probe.exe",
            "Core\NbfcProbe\bin\ReleaseWindows\ec-probe.exe"
        )) {
        $path = Join-Path $RepoRoot $rel
        if (Test-Path $path) { $probeExe = $path; break }
    }

    return @{
        ServiceRoot = $serviceRoot
        CliExe = $cliExe
        ProbeExe = $probeExe
    }
}

function Test-ForkInstall([string]$Root) {
    return @{
        EcProbe = Test-Path (Join-Path $Root "ec-probe.exe")
        EcThinkPad = Test-Path (Join-Path $Root "Plugins\StagWare.Plugins.ECThinkPad.dll")
    }
}

function Invoke-External {
    param(
        [Parameter(Mandatory = $true)][string]$ExePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    # Native tools may write "usage:" to stderr; do not treat that as a terminating error.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $out = & $ExePath @Arguments 2>&1
    }
    finally {
        $ErrorActionPreference = $prev
    }

    return ($out | ForEach-Object { "$_" }) -join [Environment]::NewLine
}

function Test-EcProbePluginSupport([string]$EcProbePath) {
    if (-not (Test-Path $EcProbePath)) { return $false }
    $text = Invoke-External -ExePath $EcProbePath -Arguments @(
        "--plugin", "StagWare.Plugins.ECThinkPad", "read", "0"
    )
    if ($text -match "usage:\s*ec-probe") { return $false }
    if ($text -match "Methode nicht gefunden|Method not found|FanControlPluginLoader") { return $false }
    return $true
}

function Stop-NbfcServiceForMaintenance {
    $nbfc = Get-Command nbfc -ErrorAction SilentlyContinue
    if ($nbfc) {
        Invoke-Nbfc -NbfcArguments @("stop") | Out-Null
        Start-Sleep -Seconds 2
    }

    $svc = Get-Service $ServiceName -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq "Running") {
        Write-Host "Stopping Windows service: $ServiceName"
        Stop-Service $ServiceName -Force
        Start-Sleep -Seconds 3
    }
}

function Start-NbfcServiceAfterMaintenance {
    $svc = Get-Service $ServiceName -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne "Running") {
        Write-Host "Starting Windows service: $ServiceName"
        Start-Service $ServiceName
        Start-Sleep -Seconds 3
    }
}

function Write-NbfcServiceSettings {
    param([Parameter(Mandatory = $true)][string]$SelectedConfig)

    $dir = Split-Path $SettingsFile -Parent
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }

    $escaped = [System.Security.SecurityElement]::Escape($SelectedConfig)
    @"
<?xml version="1.0" encoding="utf-8"?>
<ServiceSettings xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
  <SettingsVersion>0</SettingsVersion>
  <SelectedConfigId>$escaped</SelectedConfigId>
  <Autostart>false</Autostart>
  <ReadOnly>false</ReadOnly>
</ServiceSettings>
"@ | Set-Content -Path $SettingsFile -Encoding UTF8

    Write-Host "Wrote settings: $SettingsFile"
    Write-Host "  SelectedConfigId = $SelectedConfig"
}

function Reset-NbfcServiceSettings {
    param([Parameter(Mandatory = $true)][string]$SelectedConfig)

    Write-Step "Reset NBFC service settings"
    if (Test-Path $SettingsFile) {
        $backup = "$SettingsFile.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item $SettingsFile $backup -Force
        Write-Host "Backed up to: $backup"
    }

    Stop-NbfcServiceForMaintenance
    Write-NbfcServiceSettings -SelectedConfig $SelectedConfig
    Start-NbfcServiceAfterMaintenance
}

function Copy-FileIfExists([string]$Source, [string]$Destination) {
    if (-not (Test-Path $Source)) {
        Write-Warning "Skip (missing): $Source"
        return $false
    }

    $destDir = Split-Path $Destination -Parent
    if (-not (Test-Path $destDir)) {
        New-Item -ItemType Directory -Force -Path $destDir | Out-Null
    }

    Copy-Item -Path $Source -Destination $Destination -Force
    Write-Host "OK: $Destination"
    return $true
}

function Sync-ForkBinaries([string]$InstallRoot) {
    $deploy = Get-RepoDeployPaths
    if (-not $deploy.ServiceRoot) {
        throw "Repo build output not found. Run: .\scripts\build.ps1"
    }

    Write-Step "Sync full fork build into install folder"
    Write-Host "From: $($deploy.ServiceRoot)"
    Stop-NbfcServiceForMaintenance

    try {
        # Core DLLs/EXEs must match (ec-probe alone is not enough).
        Get-ChildItem -Path $deploy.ServiceRoot -File | ForEach-Object {
            Copy-FileIfExists $_.FullName (Join-Path $InstallRoot $_.Name) | Out-Null
        }

        if ($deploy.CliExe) {
            Copy-FileIfExists $deploy.CliExe (Join-Path $InstallRoot "nbfc.exe") | Out-Null
            $cliConfig = [System.IO.Path]::ChangeExtension($deploy.CliExe, ".config")
            Copy-FileIfExists $cliConfig (Join-Path $InstallRoot "nbfc.exe.config") | Out-Null
        }

        if ($deploy.ProbeExe) {
            Copy-FileIfExists $deploy.ProbeExe (Join-Path $InstallRoot "ec-probe.exe") | Out-Null
        }

        $clientExe = Join-Path $RepoRoot "Windows\NbfcClient\bin\Release\NoteBookFanControl.exe"
        if (Test-Path $clientExe) {
            Copy-FileIfExists $clientExe (Join-Path $InstallRoot "NoteBookFanControl.exe") | Out-Null
        }

        $repoPlugins = Join-Path $deploy.ServiceRoot "Plugins"
        $destPlugins = Join-Path $InstallRoot "Plugins"
        if (Test-Path $repoPlugins) {
            if (-not (Test-Path $destPlugins)) {
                New-Item -ItemType Directory -Force -Path $destPlugins | Out-Null
            }
            Get-ChildItem -Path $repoPlugins -Filter "*.dll" | ForEach-Object {
                Copy-FileIfExists $_.FullName (Join-Path $destPlugins $_.Name) | Out-Null
            }
        }
    }
    finally {
        Start-NbfcServiceAfterMaintenance
    }
}

function Install-ForkMsi {
    if (-not (Test-Path $MsiPath)) {
        throw "MSI not found: $MsiPath`nBuild first: .\scripts\build.ps1 -Installer"
    }
    Write-Step "Installing fork MSI"
    Write-Host $MsiPath
    $p = Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `"$MsiPath`"" -Wait -PassThru
    if ($p.ExitCode -ne 0) {
        throw "msiexec exited with code $($p.ExitCode)"
    }
    Write-Host "MSI finished. Re-open PowerShell if 'nbfc' is not found."
}

function Invoke-Nbfc {
    param([Parameter(Mandatory = $true)][string[]]$NbfcArguments)

    $nbfc = (Get-Command nbfc -ErrorAction Stop).Source
    $argLine = $NbfcArguments -join " "
    Write-Host "nbfc $argLine"

    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $out = & $nbfc @NbfcArguments 2>&1
    $ErrorActionPreference = $prevEap

    $text = ($out | ForEach-Object { "$_" }) -join [Environment]::NewLine
    if ($text) { Write-Host $text }

    $unavailable = $text -match "service is unavailable"
    $usageOnly = ($text -match "usage:\s*nbfc") -and ($text -notmatch "Service enabled")
    return (-not $unavailable -and -not $usageOnly)
}

function Wait-NbfcService {
    param([int]$TimeoutSeconds = 30)

    for ($i = 0; $i -lt $TimeoutSeconds; $i++) {
        if (Invoke-Nbfc -NbfcArguments @("status", "--service")) {
            return $true
        }
        Start-Sleep -Seconds 1
    }
    return $false
}

function Invoke-EcProbeRead {
    param(
        [Parameter(Mandatory = $true)][string]$EcProbePath,
        [int]$Register = 47
    )

    $args = @("--plugin", "StagWare.Plugins.ECThinkPad", "read", "$Register")
    Write-Host ("ec-probe " + ($args -join " "))
    $text = Invoke-External -ExePath $EcProbePath -Arguments $args
    if ($text -match "usage:\s*ec-probe") {
        throw "ec-probe does not support --plugin (binary too old). Run: .\scripts\fix-p52.ps1 -SyncBinaries"
    }
    Write-Host $text
    return $text
}

Write-Step "ThinkPad P52 setup (NBFC fork)"
Write-Host "Repo: $RepoRoot"

if (-not (Test-Path $SourceConfig)) {
    throw "Source config not found: $SourceConfig"
}

$root = Get-NbfcInstallRoot
if (-not $root) {
    if ($InstallMsi -or ((Read-Host "Install fork MSI now? [y/N]") -match '^[yY]')) {
        Install-ForkMsi
        $root = Get-NbfcInstallRoot
    }
    if (-not $root) {
        throw "nbfc not in PATH. Install: msiexec /i `"$MsiPath`""
    }
}

Write-Step "Installed NBFC"
Write-Host "nbfc.exe : $(Join-Path $root 'nbfc.exe')"
Write-Host "Folder   : $root"

$resolvedConfigName = Resolve-P52ConfigName $root $ConfigName
if ($resolvedConfigName -ne $ConfigName) {
    Write-Host "Config id (resolved): $resolvedConfigName"
    $ConfigName = $resolvedConfigName
    $SourceConfig = Join-Path $RepoRoot "Configs\Lenovo ThinkPad P52.xml"
}

$fork = Test-ForkInstall $root
Write-Host ("ec-probe.exe                         : {0}" -f $fork.EcProbe)
Write-Host ("Plugins\StagWare.Plugins.ECThinkPad.dll : {0}" -f $fork.EcThinkPad)

$ecProbe = Join-Path $root "ec-probe.exe"

if ($SyncBinaries) {
    Sync-ForkBinaries $root
    $ecProbe = Join-Path $root "ec-probe.exe"
}

$probeSupportsPlugin = Test-EcProbePluginSupport $ecProbe
Write-Host ("ec-probe supports --plugin           : {0}" -f $probeSupportsPlugin)

if (-not $probeSupportsPlugin) {
    Write-Warning "Fork binaries out of date (DLL mismatch or old ec-probe). Syncing full build from repo."
    Sync-ForkBinaries $root
    $ecProbe = Join-Path $root "ec-probe.exe"
    $probeSupportsPlugin = Test-EcProbePluginSupport $ecProbe
    Write-Host ("ec-probe supports --plugin (after sync): {0}" -f $probeSupportsPlugin)
}

if (-not ($fork.EcProbe -and $fork.EcThinkPad -and $probeSupportsPlugin)) {
    throw "Fork install incomplete. Rebuild (.\scripts\build.ps1 -Installer) and reinstall MSI, or use -SyncBinaries."
}

if (-not $SkipCopy) {
    Write-Step "Copy P52 config"
    $destDir = Join-Path $root "Configs"
    $destConfig = Join-Path $destDir "$ConfigName.xml"
    if (-not (Test-Path $destDir)) {
        New-Item -ItemType Directory -Force -Path $destDir | Out-Null
    }
    Copy-Item -Path $SourceConfig -Destination $destConfig -Force
    Write-Host "Copied to: $destConfig"
    Select-String -Path $destConfig -Pattern "<FanDisplayName>" | ForEach-Object {
        Write-Host ("  " + $_.Line.Trim())
    }
    $tempRegs = Select-String -Path $destConfig -Pattern "<TemperatureRegister>" -AllMatches
    if ($tempRegs) {
        Write-Host "  TemperatureRegister entries:"
        $tempRegs | ForEach-Object { Write-Host ("    " + $_.Line.Trim()) }
    }
    else {
        Write-Warning "  P52 config has no TemperatureRegister - rebuild and re-copy config."
    }
}

$svc = Get-Service $ServiceName -ErrorAction SilentlyContinue
if (-not $svc) {
    throw "Windows service '$ServiceName' not found."
}

if ($ResetSettings) {
    Reset-NbfcServiceSettings -SelectedConfig $ConfigName
}
else {
    if ($svc.Status -ne "Running") {
        Start-Service $ServiceName
        Start-Sleep -Seconds 3
    }
}

Write-Step "Apply config via NBFC service"

if (-not (Wait-NbfcService -TimeoutSeconds 45)) {
    Write-Warning "NBFC WCF not responding. Restarting Windows service."
    Restart-Service $ServiceName -Force
    Start-Sleep -Seconds 5
    if (-not (Wait-NbfcService -TimeoutSeconds 45)) {
        throw "NBFC service does not respond to nbfc CLI."
    }
}

Invoke-Nbfc -NbfcArguments @("stop") | Out-Null
Start-Sleep -Seconds 2

$configApplied = Invoke-Nbfc -NbfcArguments @("config", "--set", $ConfigName)
if (-not $configApplied) {
    Write-Warning "nbfc config --set failed. Writing settings file and restarting service."
    Reset-NbfcServiceSettings -SelectedConfig $ConfigName
    Wait-NbfcService -TimeoutSeconds 45 | Out-Null
    $configApplied = Invoke-Nbfc -NbfcArguments @("config", "--set", $ConfigName)
}

if (-not $configApplied) {
    throw "Could not apply config '$ConfigName'."
}

$startOk = Invoke-Nbfc -NbfcArguments @("start", "--enabled")
if (-not $startOk) {
    Write-Warning "nbfc start returned an error. Restarting Windows service and retrying."
    Restart-Service $ServiceName -Force
    Start-Sleep -Seconds 5
    Wait-NbfcService -TimeoutSeconds 45 | Out-Null
    $startOk = Invoke-Nbfc -NbfcArguments @("start", "--enabled")
}

Start-Sleep -Seconds 3

Write-Step "Status"
Invoke-Nbfc -NbfcArguments @("status", "--all") | Out-Null

$settingsText = Get-Content $SettingsFile -Raw -ErrorAction SilentlyContinue
if ($settingsText -match "<SelectedConfigId>([^<]+)</SelectedConfigId>") {
    Write-Host "Settings SelectedConfigId: $($Matches[1])"
}
Write-Host "Config file on disk: $(Join-Path $root "Configs\$ConfigName.xml") (exists: $(Test-Path (Join-Path $root "Configs\$ConfigName.xml")))"
nbfc config --list 2>&1 | Select-String -Pattern "P52"

if (-not $startOk) {
    $logFile = Join-Path $env:ProgramData "NbfcService\NbfcServiceLog.txt"
    if (Test-Path $logFile) {
        Write-Host ""
        Write-Host "Last service log lines ($logFile):" -ForegroundColor Yellow
        Get-Content $logFile -Tail 15 | ForEach-Object { Write-Host $_ }
    }
    Write-Warning @"
Fan control did not start. After rebuilding, sync again:
  .\scripts\build.ps1
  .\scripts\fix-p52.ps1 -SyncBinaries -ResetSettings -RunEcWriteTest
"@
}

Write-Step "EC register 0x2F (fan control)"
try {
    $ecText = Invoke-EcProbeRead -EcProbePath $ecProbe -Register 47
    $ecVal = $null
    if ($ecText -match "^\s*(\d+)") { $ecVal = [int]$Matches[1] }
    elseif ($ecText -match "0x([0-9A-Fa-f]+)") { $ecVal = [Convert]::ToInt32($Matches[1], 16) }

    if ($null -ne $ecVal) {
        if ($ecVal -band 0x80) {
            Write-Host "0x80 bit set = BIOS control (expected when NBFC is stopped)." -ForegroundColor Yellow
        }
        else {
            Write-Host ("Manual level {0} (0x{0:X2}) - EC accepts external control." -f ($ecVal -band 0x7F)) -ForegroundColor Green
        }
    }
}
catch {
    Write-Warning $_.Exception.Message
}

if ($RunEcWriteTest) {
    Write-Step "EC write test (manual fan level)"
    $testScript = Join-Path $RepoRoot "scripts\test-p52-ec-write.ps1"
    if (-not (Test-Path $testScript)) {
        Write-Warning "Missing: $testScript"
    }
    else {
        & $testScript -StopLenovoServices
    }
}

Write-Step "Done"
Write-Host @"

Expected:
  - status --all shows CPU Fan and GPU Fan (two blocks)
  - ec-probe read 47 not 128 after fan control is working

If you see 'Method not found' / 'Methode nicht gefunden' for FanControlPluginLoader:
  .\scripts\build.ps1
  .\scripts\fix-p52.ps1 -SyncBinaries -ResetSettings

Critical EC write test (must PASS before fans can work):
  .\scripts\test-p52-ec-write.ps1 -StopLenovoServices

Phase 0 full report:
  .\scripts\verify-p52-phase0.ps1 -StopLenovoServices -AllowWriteTests
"@
