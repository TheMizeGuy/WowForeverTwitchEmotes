# Copyright (c) 2026 TheMizeGuy. All rights reserved.
param(
    [Parameter(Mandatory=$true)][string]$AddOnsPath,
    [Parameter(Mandatory=$true)][string]$StageName
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if ($StageName -notmatch '^\.TwitchEmotes-stage-[a-zA-Z0-9-]+$') { throw 'Invalid staging folder' }
$root = (Get-Item -LiteralPath $AddOnsPath).FullName
$stage = Join-Path $root $StageName
$incoming = Join-Path $stage 'TwitchEmotes'
$target = Join-Path $root 'TwitchEmotes'
$previous = Join-Path $stage 'previous'
foreach ($path in @($stage, $incoming, $target)) {
    if ((Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Refusing linked addon folder: $path"
    }
}
$manifest = Get-Content -LiteralPath (Join-Path $stage 'manifest.json') -Raw | ConvertFrom-Json
$manifest = @($manifest)
if ($manifest.Count -lt 5) { throw 'Incomplete install manifest' }
foreach ($item in $manifest) {
    if ($item.path -match '(^[\\/]|(^|[\\/])\.\.([\\/]|$)|:)') { throw 'Invalid manifest path' }
    $file = Join-Path $incoming $item.path
    $info = Get-Item -LiteralPath $file -Force
    if ($info.PSIsContainer -or ($info.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Invalid addon file: $file" }
    if ($info.Length -ne $item.size -or (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $item.sha256) {
        throw "File verification failed: $($item.path)"
    }
}
$count = @(Get-ChildItem -LiteralPath $incoming -Recurse -File -Force).Count
if ($count -ne $manifest.Count) { throw "Unexpected files in staged addon: $count" }
if (!(Test-Path -LiteralPath (Join-Path $incoming 'TwitchEmotes_Camelot.toc'))) { throw 'Missing client manifest' }
if (Test-Path -LiteralPath $target) { Move-Item -LiteralPath $target -Destination $previous }
try {
    Move-Item -LiteralPath $incoming -Destination $target
} catch {
    if (Test-Path -LiteralPath $previous) { Move-Item -LiteralPath $previous -Destination $target }
    throw
}
$installed = @(Get-ChildItem -LiteralPath $target -Recurse -File -Force).Count
if ($installed -ne $manifest.Count) { throw 'Installed file count changed unexpectedly' }
$version = Get-Content -LiteralPath (Join-Path $target 'TwitchEmotes_Camelot.toc') | Select-String '^## Version:'
Remove-Item -LiteralPath $stage -Recurse -Force
Write-Output "Installed $installed verified files. $version"
