# Builds dist\KeyDrive-<version>.zip with extension/lua/joypad-assist/KeyDrive (and apps/lua/KeyDriveConfig
# once it exists), ready to drag into Content Manager. Run: powershell -ExecutionPolicy Bypass -File build-keydrive.ps1
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$parts = @('extension/lua/joypad-assist/KeyDrive', 'apps/lua/KeyDriveConfig')
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
