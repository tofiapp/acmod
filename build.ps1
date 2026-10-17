# Builds dist\MirrorDelta-<version>.zip with the apps/lua/MirrorDelta structure,
# ready to drag into Content Manager. Run: powershell -ExecutionPolicy Bypass -File build.ps1
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$app = Join-Path $PSScriptRoot 'apps\lua\MirrorDelta'
$versionLine = Get-Content (Join-Path $app 'manifest.ini') | Where-Object { $_ -match '^VERSION\s*=' } | Select-Object -First 1
$version = ($versionLine -replace '^VERSION\s*=\s*', '').Trim()

$dist = Join-Path $PSScriptRoot 'dist'
New-Item -ItemType Directory -Force -Path $dist | Out-Null
$zip = Join-Path $dist "MirrorDelta-$version.zip"
if (Test-Path $zip) { Remove-Item $zip }

# Entries use forward slashes so every tool (Content Manager included) reads the folders correctly.
$root = (Resolve-Path $app).Path
$archive = [System.IO.Compression.ZipFile]::Open($zip, 'Create')
try {
  Get-ChildItem $root -Recurse -File | Where-Object { $_.Name -notin @('Thumbs.db', '.DS_Store') } | ForEach-Object {
    $relative = $_.FullName.Substring($root.Length + 1) -replace '\\', '/'
    [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $_.FullName, "apps/lua/MirrorDelta/$relative") | Out-Null
  }
} finally {
  $archive.Dispose()
}
Write-Host "Built $zip"
