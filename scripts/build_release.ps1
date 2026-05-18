param(
  [switch]$InstallPyInstaller,
  [switch]$SkipExe
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$version = (Get-Content (Join-Path $repoRoot "VERSION") -Raw).Trim()
$distRoot = Join-Path $repoRoot "dist"
$stageRoot = Join-Path $distRoot "CodexUsageWidget-$version"
$toolsDir = Join-Path $stageRoot "tools"
$zipPath = Join-Path $distRoot "CodexUsageWidget-$version.zip"

if (Test-Path $distRoot) {
  Remove-Item -LiteralPath $distRoot -Recurse -Force
}

New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null

& (Join-Path $PSScriptRoot "check.ps1")

if (-not $SkipExe) {
  $pyinstaller = Get-Command pyinstaller -ErrorAction SilentlyContinue
  if ((-not $pyinstaller) -and $InstallPyInstaller) {
    python -m pip install pyinstaller
    $pyinstaller = Get-Command pyinstaller -ErrorAction SilentlyContinue
  }

  if ($pyinstaller) {
    New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null
    pyinstaller --onefile --clean --name codex_usage_fetch --distpath $toolsDir --workpath (Join-Path $distRoot "pyinstaller-work") --specpath $distRoot (Join-Path $repoRoot "codex_usage_fetch.py")
  } else {
    Write-Warning "PyInstaller not found. Building script-only package. Run with -InstallPyInstaller to include codex_usage_fetch.exe."
  }
}

$files = @(
  ".gitignore",
  "CHANGELOG.md",
  "LICENSE",
  "README.md",
  "README.txt",
  "VERSION",
  "capture_screen.ps1",
  "check_widget_proc.ps1",
  "codex_usage_fetch.py",
  "codex_usage_widget.ps1",
  "kill_widget.ps1",
  "run_widget_hidden.vbs"
)

foreach ($file in $files) {
  Copy-Item -LiteralPath (Join-Path $repoRoot $file) -Destination $stageRoot -Force
}

Get-ChildItem -LiteralPath $repoRoot -Filter "*.bat" | ForEach-Object {
  Copy-Item -LiteralPath $_.FullName -Destination $stageRoot -Force
}

Copy-Item -LiteralPath (Join-Path $repoRoot "tests") -Destination (Join-Path $stageRoot "tests") -Recurse -Force
Copy-Item -LiteralPath (Join-Path $repoRoot "scripts") -Destination (Join-Path $stageRoot "scripts") -Recurse -Force

Compress-Archive -Path (Join-Path $stageRoot "*") -DestinationPath $zipPath -Force

Write-Host "Release package created:"
Write-Host $zipPath
