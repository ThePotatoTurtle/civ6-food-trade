[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ModsPath,
    [switch]$DevOnly,
    [switch]$IncludeDev
)

$ErrorActionPreference = 'Stop'
if (Get-Process -Name 'CivilizationVI', 'CivilizationVI_DX12' -ErrorAction SilentlyContinue) {
    throw 'Quit Civilization VI to the desktop before installing Food Trade.'
}
if ($DevOnly -and $IncludeDev) {
    throw 'Use either -DevOnly or -IncludeDev.'
}
$projectRoot = Split-Path -Parent $PSScriptRoot
$projectRoot = [System.IO.Path]::GetFullPath($projectRoot).TrimEnd('\')
$modsTarget = [System.IO.Path]::GetFullPath($ModsPath)
$modsTarget = $modsTarget.TrimEnd('\')
if (-not (Test-Path -LiteralPath $modsTarget -PathType Container)) {
    throw "ModsPath must be an existing confirmed Mods directory: $modsTarget"
}
if ($modsTarget -eq $projectRoot -or
    $modsTarget.StartsWith($projectRoot + '\', [System.StringComparison]::OrdinalIgnoreCase) -or
    $projectRoot.StartsWith($modsTarget + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'ModsPath overlaps the project source. Choose the confirmed Civilization VI Mods directory.'
}
$names = @('FDT')
if ($DevOnly) { $names = @('FDT_Dev') }
elseif ($IncludeDev) { $names = @('FDT', 'FDT_Dev') }
# Validate every selected source and existing destination before removing anything.
foreach ($name in $names) {
    $sourcePath = Join-Path $projectRoot $name
    $manifestPath = Join-Path $sourcePath ($name + '.modinfo')
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Source manifest missing: $manifestPath"
    }
    [xml]$sourceManifest = Get-Content -LiteralPath $manifestPath -Raw
    foreach ($file in $sourceManifest.Mod.Files.File) {
        $sourceFile = [System.IO.Path]::GetFullPath((Join-Path $sourcePath ([string]$file)))
        if (-not $sourceFile.StartsWith($sourcePath + '\', [System.StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-Path -LiteralPath $sourceFile -PathType Leaf)) {
            throw "Missing or unsafe source file: $sourceFile"
        }
    }
    $targetPath = [System.IO.Path]::GetFullPath((Join-Path $modsTarget $name))
    if ((Split-Path -Parent $targetPath) -ne $modsTarget.TrimEnd('\')) {
        throw "Unsafe install path: $targetPath"
    }
    if (Test-Path -LiteralPath $targetPath) {
        if ((Get-Item -LiteralPath $targetPath).Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            throw "Refusing to replace a linked target directory: $targetPath"
        }
        $targetManifestPath = Join-Path $targetPath ($name + '.modinfo')
        if (-not (Test-Path -LiteralPath $targetManifestPath -PathType Leaf)) {
            throw "Existing target has no matching Food Trade manifest: $targetPath"
        }
        [xml]$targetManifest = Get-Content -LiteralPath $targetManifestPath -Raw
        if ($targetManifest.Mod.id -ne $sourceManifest.Mod.id) {
            throw "Existing target belongs to a different mod: $targetPath"
        }
    }
}
foreach ($name in $names) {
    $sourcePath = Join-Path $projectRoot $name
    $targetPath = [System.IO.Path]::GetFullPath((Join-Path $modsTarget $name))
    if (Test-Path -LiteralPath $targetPath) {
        # Deliberately replace only our fixed-name mod folder to remove stale files.
        Remove-Item -LiteralPath $targetPath -Recurse -Force
    }
    Copy-Item -LiteralPath $sourcePath -Destination $targetPath -Recurse
    Write-Output "Installed $name to $targetPath"
}
