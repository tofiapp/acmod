# Builds dist\KeyDrive-<version>.zip with extension/lua/joypad-assist/KeyDrive, apps/lua/KeyDriveConfig and
# apps/lua/KeyDriveKeyboardTest, ready to drag into Content Manager.
#   powershell -ExecutionPolicy Bypass -File build-keydrive.ps1
#   powershell -ExecutionPolicy Bypass -File build-keydrive.ps1 -Install -AcPath "C:\Program Files (x86)\Steam\steamapps\common\assettocorsa"
# -Install also copies the folders straight into that AC install (the path is remembered in .keydrive-ac-path, so
# later runs need only -Install). Only KeyDrive's own folders are replaced there; an edited settings.ini is kept as
# settings.ini.bak-<time> next to the new one.
param([switch]$Install, [string]$AcPath = '')
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$parts = @('extension/lua/joypad-assist/KeyDrive', 'apps/lua/KeyDriveConfig', 'apps/lua/KeyDriveKeyboardTest')
$core = Join-Path $PSScriptRoot 'extension\lua\joypad-assist\KeyDrive'
$versionLine = Get-Content (Join-Path $core 'manifest.ini') | Where-Object { $_ -match '^VERSION\s*=' } | Select-Object -First 1
$version = ($versionLine -replace '^VERSION\s*=\s*', '').Trim()

$dist = Join-Path $PSScriptRoot 'dist'
New-Item -ItemType Directory -Force -Path $dist | Out-Null
$zip = Join-Path $dist "KeyDrive-$version.zip"
if (Test-Path $zip) { Remove-Item $zip }

# Entries use forward slashes so every tool (Content Manager included) reads the folders correctly.
$archive = [System.IO.Compression.ZipFile]::Open($zip, 'Create')
try {
  foreach ($part in $parts) {
    $dir = Join-Path $PSScriptRoot ($part -replace '/', '\')
    if (-not (Test-Path $dir)) { continue }
    $root = (Resolve-Path $dir).Path
    Get-ChildItem $root -Recurse -File | Where-Object { $_.Name -notin @('Thumbs.db', '.DS_Store') } | ForEach-Object {
      $relative = $_.FullName.Substring($root.Length + 1) -replace '\\', '/'
      [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $_.FullName, "$part/$relative") | Out-Null
    }
  }
} finally {
  $archive.Dispose()
}
Write-Host "Built $zip"

if ($Install) {
  $remember = Join-Path $PSScriptRoot '.keydrive-ac-path'
  if (-not $AcPath) {
    if (Test-Path $remember) { $AcPath = (Get-Content $remember -Raw).Trim() }
    else { throw 'No AC path given and none remembered: use -Install -AcPath "<AC folder>"' }
  }
  if (-not (Test-Path (Join-Path $AcPath 'acs.exe'))) { throw "Not an Assetto Corsa folder (acs.exe missing): $AcPath" }
  Set-Content -Path $remember -Value $AcPath
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  foreach ($part in $parts) {
    $src = Join-Path $PSScriptRoot ($part -replace '/', '\')
    if (-not (Test-Path $src)) { continue }
    $dst = Join-Path $AcPath ($part -replace '/', '\')
    $oldSettings = Join-Path $dst 'settings.ini'
    $newSettings = Join-Path $src 'settings.ini'
    $backup = $null
    if ((Test-Path $oldSettings) -and (Test-Path $newSettings) -and
        ((Get-FileHash $oldSettings).Hash -ne (Get-FileHash $newSettings).Hash)) {
      $backup = Join-Path $env:TEMP "keydrive-settings-$stamp.ini"
      Copy-Item $oldSettings $backup
    }
    if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }
    New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
    Copy-Item $src $dst -Recurse
    if ($backup) {
      Copy-Item $backup (Join-Path $dst "settings.ini.bak-$stamp")
      Write-Host "Your previous settings.ini differs from the new defaults: kept as settings.ini.bak-$stamp"
    }
    Write-Host "Installed $part -> $dst"
  }
}
