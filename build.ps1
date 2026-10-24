# Builds the BeamMP resource folder:
#   dist/Resources/Client/RadioSync.zip        client mod (Lua + UI app)
#   dist/Resources/Server/RadioSync/           server plugin (+ music/ folder for songs)
# and release/RadioSync-BeamMP-Resources.zip containing all of the above.
# Zip entries use forward slashes (Compress-Archive in PS 5.1 writes backslashes, which BeamNG can't read).

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$dist = Join-Path $root 'dist\Resources'
$release = Join-Path $root 'release'
$clientSrc = Join-Path $root 'Client'
$serverSrc = Join-Path $root 'Server\RadioSync'

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function New-Zip($zipPath, $files, $baseDir, $prefix, $level) {
  if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
  $zip = [System.IO.Compression.ZipFile]::Open($zipPath, 'Create')
  try {
    foreach ($f in $files) {
      $entry = $prefix + $f.FullName.Substring($baseDir.Length + 1).Replace('\', '/')
      [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $f.FullName, $entry, $level) | Out-Null
    }
  } finally {
    $zip.Dispose()
  }
}

$optimal = [System.IO.Compression.CompressionLevel]::Optimal
$store = [System.IO.Compression.CompressionLevel]::NoCompression

if (Test-Path (Join-Path $root 'dist')) { Remove-Item (Join-Path $root 'dist') -Recurse -Force }
New-Item -ItemType Directory -Force (Join-Path $dist 'Client'), (Join-Path $dist 'Server'), $release | Out-Null

# Client mod (+ the server plugin, which the client runs itself in offline mode)
$clientZip = Join-Path $dist 'Client\RadioSync.zip'
New-Zip $clientZip (Get-ChildItem $clientSrc -Recurse -File) $clientSrc '' $optimal
$zip = [System.IO.Compression.ZipFile]::Open($clientZip, 'Update')
try {
  [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, (Join-Path $serverSrc 'main.lua'),
    'lua/ge/extensions/radioSync/server.lua', $optimal) | Out-Null
} finally {
  $zip.Dispose()
}

# Server plugin
Copy-Item $serverSrc (Join-Path $dist 'Server') -Recurse

# Release bundle
$distRoot = Join-Path $root 'dist'
New-Zip (Join-Path $release 'RadioSync-BeamMP-Resources.zip') (Get-ChildItem $distRoot -Recurse -File) $distRoot '' $store
Copy-Item (Join-Path $dist 'Client\*.zip') $release -Force
New-Zip (Join-Path $release 'RadioSync-Server.zip') (Get-ChildItem $serverSrc -Recurse -File) (Split-Path $serverSrc) '' $optimal

Write-Host "Built $dist"
