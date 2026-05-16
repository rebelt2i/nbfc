# NBFC build script for Cursor / VS Code / CLI
# Requires: Visual Studio 2022 Build Tools + .NET Framework 4.8 targeting pack

param(
    [ValidateSet("DebugWindows", "ReleaseWindows", "DebugLinux", "ReleaseLinux")]
    [string]$Configuration = "ReleaseWindows",
    [switch]$Restore,
    [switch]$Installer,
    [switch]$Tests
)

$ErrorActionPreference = "Stop"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

function Find-WixTargets {
    $candidates = @(
        "${env:ProgramFiles(x86)}\WiX Toolset v3.14\build\Wix.targets",
        "${env:ProgramFiles(x86)}\WiX Toolset v3.11\build\Wix.targets",
        # winget: binaries under "WiX Toolset v3.14", MSBuild targets under MSBuild\Microsoft\WiX
        "${env:ProgramFiles(x86)}\MSBuild\Microsoft\WiX\v3.x\Wix.targets"
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { return $c }
    }
    foreach ($root in @("${env:ProgramFiles(x86)}", "${env:ProgramFiles}")) {
        if (-not (Test-Path $root)) { continue }
        $hit = Get-ChildItem -Path $root -Filter "Wix.targets" -Recurse -ErrorAction SilentlyContinue |
            Where-Object {
                $_.FullName -match '\\WiX Toolset v3\.[0-9]+\\build\\Wix\.targets$' -or
                $_.FullName -match '\\MSBuild\\Microsoft\\WiX\\v3\.x\\Wix\.targets$'
            } |
            Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

$MSBuild = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin\MSBuild.exe"
if (-not (Test-Path $MSBuild)) {
    $MSBuild = "${env:ProgramFiles}\Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin\MSBuild.exe"
}
if (-not (Test-Path $MSBuild)) {
    throw "MSBuild not found. Install Visual Studio 2022 Build Tools with .NET desktop development workload."
}

$NuGet = Join-Path $RepoRoot "tools\nuget.exe"
if (-not (Test-Path $NuGet)) {
    New-Item -ItemType Directory -Force -Path (Join-Path $RepoRoot "tools") | Out-Null
    Invoke-WebRequest -Uri "https://dist.nuget.org/win-x86-commandline/latest/nuget.exe" -OutFile $NuGet -UseBasicParsing
}

if ($Restore -or -not (Test-Path "$RepoRoot\packages\NLog.4.5.10")) {
    Write-Host "Restoring NuGet packages..." -ForegroundColor Cyan
    & $NuGet restore "$RepoRoot\NoteBookFanControl.sln" -ConfigFile "$RepoRoot\nuget.config" -NonInteractive
    if ($LASTEXITCODE -ne 0) { throw "NuGet restore failed." }
}

Write-Host "Building NBFC ($Configuration)..." -ForegroundColor Cyan

$wixProps = @()
$wixTargets = $null
if ($Installer) {
    $wixTargets = Find-WixTargets
    if ($wixTargets) {
        $wixBuild = Split-Path -Parent $wixTargets
        $wixProps = @(
            "/p:WixTargetsPath=$wixTargets",
            "/p:WixCATargetsPath=$(Join-Path $wixBuild 'Wix.CA.targets')"
        )
        Write-Host "WiX targets: $wixTargets" -ForegroundColor Cyan
    }
}

# Solution build maps ReleaseWindows -> Release|x86 for .wixproj projects.
& $MSBuild "$RepoRoot\NoteBookFanControl.sln" `
    /p:Configuration=$Configuration `
    /t:Build `
    /m `
    /v:minimal `
    /nologo `
    @wixProps

$expectedOutputs = @(
    "$RepoRoot\Core\NbfcCli\bin\$Configuration\nbfc.exe",
    "$RepoRoot\Core\NbfcService\bin\$Configuration\NbfcService.exe",
    "$RepoRoot\Windows\NbfcClient\bin\Release\NoteBookFanControl.exe"
)

$missing = @($expectedOutputs | Where-Object { -not (Test-Path $_) })
if ($missing.Count -gt 0) {
    foreach ($m in $missing) { Write-Host "Missing: $m" -ForegroundColor Red }
    throw "Build failed: expected outputs not found."
}

if ($Tests) {
    Write-Host "Building tests..." -ForegroundColor Cyan
    & $MSBuild "$RepoRoot\Tests\StagWare.FanControl.Tests\StagWare.FanControl.Tests.csproj" /p:Configuration=Release /t:Build /v:minimal /nologo
    if ($LASTEXITCODE -ne 0) { throw "Build failed: StagWare.FanControl.Tests" }
    & $MSBuild "$RepoRoot\Tests\StagWare.FanControl.Configurations.Tests\StagWare.FanControl.Configurations.Tests.csproj" /p:Configuration=Release /t:Build /v:minimal /nologo
    if ($LASTEXITCODE -ne 0) { throw "Build failed: StagWare.FanControl.Configurations.Tests" }
}

if ($Installer) {
    $msi = Get-ChildItem "$RepoRoot\Windows\Setup\NbfcSetup\bin" -Filter "*.msi" -Recurse -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($msi) {
        Write-Host "  MSI: $($msi.FullName)" -ForegroundColor Green
    }
    elseif (-not $wixTargets) {
        Write-Warning @"
WiX Toolset 3.14 not found on disk. MSI installer skipped.

Install (elevated PowerShell):
  DISM /Online /Enable-Feature /FeatureName:NetFx3 /All
  winget install WiXToolset.WiXToolset --accept-package-agreements

Then: .\scripts\build.ps1 -Installer
"@
    }
    else {
        Write-Warning "NbfcSetup.msi was not produced (NbfcBootstrapper may have failed; MSI is optional)."
    }
}

Write-Host "Copying plugin assemblies..." -ForegroundColor Cyan
$pluginDlls = @(
    "StagWare.Plugins.ECWindows.dll",
    "StagWare.Plugins.ECThinkPad.dll",
    "StagWare.Plugins.CpuTemperatureMonitor.dll",
    "StagWare.Hardware.dll",
    "StagWare.Hardware.LPC.dll",
    "OpenHardwareMonitorLib.dll"
)
$pluginSourceRoots = @(
    "$RepoRoot\Core\Plugins",
    "$RepoRoot\Core\Plugins\OpenHardwareMonitor\Bin\Release"
)
$serviceOut = "$RepoRoot\Core\NbfcService\bin\$Configuration"
$configsOut = Join-Path $serviceOut "Configs"
New-Item -ItemType Directory -Force -Path $configsOut | Out-Null
Copy-Item "$RepoRoot\Configs\*.xml" $configsOut -Force
Write-Host "Copied configs to $configsOut" -ForegroundColor Cyan

$deployTargets = @(
    "$serviceOut\Plugins",
    "$RepoRoot\Core\NbfcCli\bin\$Configuration\Plugins",
    "$RepoRoot\Core\NbfcProbe\bin\Release\Plugins"
)
foreach ($target in $deployTargets) {
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    foreach ($dll in $pluginDlls) {
        $found = Get-ChildItem -Path $pluginSourceRoots -Recurse -Filter $dll -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($found) {
            Copy-Item $found.FullName (Join-Path $target $dll) -Force
        }
    }
}

Write-Host ""
Write-Host "Build succeeded ($Configuration)" -ForegroundColor Green
Write-Host "  CLI:     Core\NbfcCli\bin\$Configuration\nbfc.exe"
Write-Host "  Service: Core\NbfcService\bin\$Configuration\NbfcService.exe"
Write-Host "  Client:  Windows\NbfcClient\bin\Release\NoteBookFanControl.exe"
Write-Host "  Probe:   Core\NbfcProbe\bin\Release\ec-probe.exe"
Write-Host "  Configs: Core\NbfcService\bin\$Configuration\Configs\"
Write-Host "  Editor:  Windows\ConfigEditor\bin\Release\ConfigEditor.exe"
