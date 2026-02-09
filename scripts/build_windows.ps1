# ──────────────────────────────────────────────────────────────────────────
# build_windows.ps1 — Windows production build pipeline (placeholder)
#
# Steps:
#   1. Bundle Python services via PyInstaller
#   2. Build Flutter Windows app (flutter build windows --release)
#   3. Copy bundled Python alongside the .exe
#   4. Code sign with signtool (optional)
#   5. Create installer (Inno Setup or WiX)
#
# The resulting installation is fully self-contained — NO system Python
# required. Users never see Python, pip, or a terminal.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File scripts\build_windows.ps1 [-SkipServices] [-Sign] [-Installer]
#
# Prerequisites:
#   - Python 3.12+ with venv at services\.venv\
#   - Flutter SDK in PATH
#   - PyInstaller (pip install pyinstaller)
#   - Inno Setup 6 for installer creation (optional)
#   - Windows SDK signtool for code signing (optional)
# ──────────────────────────────────────────────────────────────────────────

param(
    [switch]$SkipServices,
    [switch]$SkipFlutter,
    [switch]$Sign,
    [switch]$Installer,
    [switch]$Help
)

$ErrorActionPreference = "Stop"

$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$ServicesDir  = Join-Path $ProjectRoot "services"
$FlutterDir   = Join-Path $ProjectRoot "studiomc_app"
$VenvDir      = Join-Path $ServicesDir ".venv"

if ($Help) {
    Write-Host "Usage: powershell -File scripts\build_windows.ps1 [-SkipServices] [-SkipFlutter] [-Sign] [-Installer]"
    exit 0
}

Write-Host "╔══════════════════════════════════════════════════════╗"
Write-Host "║  Studiomc — Windows Production Build                ║"
Write-Host "╚══════════════════════════════════════════════════════╝"
Write-Host ""

# ── Preflight ─────────────────────────────────────────────────────────────

if ($env:OS -ne "Windows_NT") {
    Write-Host "✗ This script must be run on Windows."
    exit 1
}

Write-Host "  Platform:  Windows $([System.Environment]::OSVersion.Version)"
Write-Host ""

$TotalSteps = 5
$Step = 0

# ── Step 1: Bundle Python services ────────────────────────────────────────

$Step++
Write-Host "═══ Step $Step/$TotalSteps`: Bundle Python services ═══"

if (-not $SkipServices) {
    # Verify venv exists
    if (-not (Test-Path $VenvDir)) {
        Write-Host "✗ Virtual environment not found at $VenvDir"
        Write-Host "  Create it with:"
        Write-Host "    cd services"
        Write-Host "    python -m venv .venv"
        Write-Host "    .venv\Scripts\activate"
        Write-Host "    pip install -r requirements.txt"
        exit 1
    }

    # Activate venv
    $ActivateScript = Join-Path $VenvDir "Scripts\Activate.ps1"
    . $ActivateScript
    Write-Host "✓ Activated venv"

    # Ensure PyInstaller
    $PyInstallerCheck = & python -m PyInstaller --version 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "→ Installing PyInstaller…"
        & pip install pyinstaller
    }
    Write-Host "✓ PyInstaller available"

    # Clean previous build
    $DistDir  = Join-Path $ServicesDir "dist\studiomc_services"
    $BuildDir = Join-Path $ServicesDir "build\studiomc_services"
    if (Test-Path $DistDir)  { Remove-Item -Recurse -Force $DistDir }
    if (Test-Path $BuildDir) { Remove-Item -Recurse -Force $BuildDir }

    # Run PyInstaller
    Write-Host "→ Running PyInstaller…"
    Push-Location $ServicesDir
    & python -m PyInstaller studiomc_services.spec --clean --noconfirm
    Pop-Location

    if (-not (Test-Path (Join-Path $DistDir "studiomc_services.exe"))) {
        Write-Host "✗ Build failed — studiomc_services.exe not found"
        exit 1
    }
    Write-Host "✓ Services bundle built"
} else {
    Write-Host "⊘ Skipping (-SkipServices)"
}

$BundleSrc = Join-Path $ServicesDir "dist\studiomc_services"
if (-not (Test-Path $BundleSrc)) {
    Write-Host "✗ Services bundle not found at $BundleSrc"
    exit 1
}
Write-Host ""

# ── Step 2: Build Flutter Windows app ────────────────────────────────────

$Step++
Write-Host "═══ Step $Step/$TotalSteps`: Flutter Windows release build ═══"

if (-not $SkipFlutter) {
    Push-Location $FlutterDir
    & flutter build windows --release
    Pop-Location
    Write-Host "✓ Flutter build complete"
} else {
    Write-Host "⊘ Skipping (-SkipFlutter)"
}
Write-Host ""

# ── Step 3: Embed services alongside the .exe ────────────────────────────

$Step++
Write-Host "═══ Step $Step/$TotalSteps`: Embed Python bundle ═══"

$RunnerDir    = Join-Path $FlutterDir "build\windows\x64\runner\Release"
$ServicesDest = Join-Path $RunnerDir "studiomc_services"

if (-not (Test-Path $RunnerDir)) {
    Write-Host "✗ Flutter release build not found at $RunnerDir"
    exit 1
}

if (Test-Path $ServicesDest) { Remove-Item -Recurse -Force $ServicesDest }
Copy-Item -Recurse $BundleSrc $ServicesDest
Write-Host "✓ Services embedded into $ServicesDest"
Write-Host ""

# ── Step 4: Code signing ─────────────────────────────────────────────────

$Step++
Write-Host "═══ Step $Step/$TotalSteps`: Code signing ═══"

if ($Sign) {
    # TODO: Implement Windows code signing
    #
    # Requirements:
    #   - Windows SDK with signtool.exe in PATH
    #   - Code signing certificate (.pfx or from Windows certificate store)
    #   - Set environment variables:
    #       WINDOWS_SIGN_CERT_PATH   — path to .pfx file
    #       WINDOWS_SIGN_CERT_PASS   — certificate password
    #       WINDOWS_SIGN_TIMESTAMP   — timestamp server URL
    #
    # Implementation outline:
    #   $SignTool = "signtool.exe"
    #   $CertPath = $env:WINDOWS_SIGN_CERT_PATH
    #   $CertPass = $env:WINDOWS_SIGN_CERT_PASS
    #   $TimestampUrl = $env:WINDOWS_SIGN_TIMESTAMP ?? "http://timestamp.digicert.com"
    #
    #   # Sign the main .exe
    #   & $SignTool sign /f $CertPath /p $CertPass /tr $TimestampUrl /td sha256 /fd sha256 `
    #       (Join-Path $RunnerDir "studiomc_app.exe")
    #
    #   # Sign the services executable
    #   & $SignTool sign /f $CertPath /p $CertPass /tr $TimestampUrl /td sha256 /fd sha256 `
    #       (Join-Path $ServicesDest "studiomc_services.exe")
    #
    #   # Sign all DLLs
    #   Get-ChildItem -Recurse -Filter "*.dll" $RunnerDir | ForEach-Object {
    #       & $SignTool sign /f $CertPath /p $CertPass /tr $TimestampUrl /td sha256 /fd sha256 $_.FullName
    #   }

    Write-Host "⚠ Code signing is not yet implemented."
    Write-Host "  TODO: Add signtool integration with certificate configuration."
} else {
    Write-Host "⊘ Skipping (pass -Sign to enable)"
}
Write-Host ""

# ── Step 5: Create installer ─────────────────────────────────────────────

$Step++
Write-Host "═══ Step $Step/$TotalSteps`: Create installer ═══"

if ($Installer) {
    # TODO: Implement installer creation
    #
    # Option A: Inno Setup (recommended — free, widely used)
    #   - Install Inno Setup 6: https://jrsoftware.org/isinfo.php
    #   - The .iss script is at scripts/release/windows_setup.iss
    #
    #   $InnoSetup = "C:\Program Files (x86)\Inno Setup 6\ISCC.exe"
    #   if (Test-Path $InnoSetup) {
    #       $IssFile = Join-Path $ProjectRoot "scripts\release\windows_setup.iss"
    #       & $InnoSetup $IssFile
    #       Write-Host "✓ Installer created"
    #   } else {
    #       Write-Host "✗ Inno Setup not found at $InnoSetup"
    #   }
    #
    # Option B: WiX Toolset (MSI installer)
    #   - Install WiX: https://wixtoolset.org/
    #   - Create a .wxs manifest
    #   - Build with: wix build -o dist\Studiomc-Setup.msi studiomc.wxs
    #
    # Option C: MSIX (Windows Store compatible)
    #   - Flutter has built-in MSIX support via the msix package
    #   - Add msix config to pubspec.yaml
    #   - Build with: flutter pub run msix:create

    Write-Host "⚠ Installer creation is not yet implemented."
    Write-Host "  TODO: Integrate Inno Setup (.iss at scripts/release/windows_setup.iss)"
    Write-Host "  Manual: 'C:\Program Files (x86)\Inno Setup 6\ISCC.exe' scripts\release\windows_setup.iss"
} else {
    Write-Host "⊘ Skipping (pass -Installer to enable)"
}
Write-Host ""

# ── Summary ───────────────────────────────────────────────────────────────

Write-Host "╔══════════════════════════════════════════════════════╗"
Write-Host "║  ✓ Windows production build complete                ║"
Write-Host "╠══════════════════════════════════════════════════════╣"
Write-Host "║  Runner:   $RunnerDir"
Write-Host "║  Services: $ServicesDest"
Write-Host "╚══════════════════════════════════════════════════════╝"
Write-Host ""
Write-Host "To test locally:"
Write-Host "  & '$RunnerDir\studiomc_app.exe'"
