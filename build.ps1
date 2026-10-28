# Builds one ZIP per app, dist\<App>-<version>.zip, each holding only apps/lua/<App>/...,
# ready to drag into Content Manager.
#   powershell -ExecutionPolicy Bypass -File build.ps1               both apps
#   powershell -ExecutionPolicy Bypass -File build.ps1 MirrorDelta   one app (MirrorDelta or LedControl)
# Each app's tests run first; a failing test stops the build.
param([string[]]$Apps = @('MirrorDelta', 'LedControl'))
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Build-App([string]$name) {
  $app = Join-Path $PSScriptRoot "apps\lua\$name"
  $manifest = Join-Path $app 'manifest.ini'
  if (-not (Test-Path $manifest)) { throw "Unknown app: $name" }
  # no ZIP from red tests (needs Python with the "lupa" package: pip install lupa)
  $runner = if ($name -eq 'LedControl') { 'tests\ledcontrol\run_tests.py' } else { 'tests\run_tests.py' }
  $python = Get-Command python -ErrorAction SilentlyContinue
  if (-not $python) { throw "Python not found: the tests of $name must pass before a ZIP is built (pip install lupa)." }
  & $python.Source (Join-Path $PSScriptRoot $runner)
  if ($LASTEXITCODE -ne 0) { throw "Tests of $name failed: no ZIP built." }
  $versionLine = Get-Content $manifest | Where-Object { $_ -match '^VERSION\s*=' } | Select-Object -First 1
  $version = ($versionLine -replace '^VERSION\s*=\s*', '').Trim()

  $dist = Join-Path $PSScriptRoot 'dist'
  New-Item -ItemType Directory -Force -Path $dist | Out-Null
  $zip = Join-Path $dist "$name-$version.zip"
  if (Test-Path $zip) { Remove-Item $zip }

  # Entries use forward slashes so every tool (Content Manager included) reads the folders correctly.
  $root = (Resolve-Path $app).Path
  $archive = [System.IO.Compression.ZipFile]::Open($zip, 'Create')
  try {
    Get-ChildItem $root -Recurse -File | Where-Object { $_.Name -notin @('Thumbs.db', '.DS_Store') } | ForEach-Object {
      $relative = $_.FullName.Substring($root.Length + 1) -replace '\\', '/'
      [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $_.FullName, "apps/lua/$name/$relative") | Out-Null
    }
  } finally {
    $archive.Dispose()
  }
  Write-Host "Built $zip"
}

foreach ($name in $Apps) { Build-App $name }
