[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$GameRoot,
    [Parameter(Mandatory)][string]$Scene,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [ValidateRange(5,120)][int]$Rate = 60,
    [string]$ReferenceDirectory,
    [ValidateRange(1,10000)][int]$ReferenceStride = 1,
    [int]$TimeoutSeconds = 240,
    [string]$JobDirectory,
    [switch]$WorkspaceOnly
)
$ErrorActionPreference = 'Stop'
function Set-CaptureStatus([string]$Step) {
    if ($JobDirectory) { [IO.File]::WriteAllText((Join-Path $JobDirectory 'phase.txt'), $Step) }
}
function Confirm-NotCancelled {
    if ($JobDirectory -and (Test-Path -LiteralPath (Join-Path $JobDirectory 'cancel'))) {
        throw [OperationCanceledException]::new('Import cancelled.')
    }
}
Set-CaptureStatus 'preparing'
$game = (Resolve-Path -LiteralPath $GameRoot).Path
$source = (Resolve-Path -LiteralPath $Scene).Path
$output = [IO.Path]::GetFullPath($OutputDirectory)
$references = if ($ReferenceDirectory) { [IO.Path]::GetFullPath($ReferenceDirectory) } else { '' }
foreach ($folder in @($output, $references) | Where-Object { $_ }) {
    if ($folder -eq $game -or $folder.StartsWith($game.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Choose output directories outside the game installation.'
    }
    [IO.Directory]::CreateDirectory($folder) | Out-Null
}
$stage = Join-Path ([IO.Path]::GetTempPath()) ('Myproject-KKS-Scene-' + [Guid]::NewGuid().ToString('N'))
$previous = $env:MYPROJECT_KKS_SCENE_PLAN
$process = $null
try {
    [IO.Directory]::CreateDirectory("$stage\BepInEx") | Out-Null
    [IO.Directory]::CreateDirectory("$stage\UserData\studio\scene") | Out-Null
    if (Test-Path -LiteralPath "$game\UserData\config") {
        Copy-Item -LiteralPath "$game\UserData\config" -Destination "$stage\UserData" -Recurse
    }
    foreach ($name in 'CharaStudio.exe','UnityPlayer.dll','UnityCrashHandler64.exe','winhttp.dll','doorstop_config.ini','CharaStudio_Data','MonoBleedingEdge') {
        Copy-Item -LiteralPath "$game\$name" -Destination $stage -Recurse
    }
    foreach ($name in 'core','plugins','config','patchers') {
        if (Test-Path -LiteralPath "$game\BepInEx\$name") {
            Copy-Item -LiteralPath "$game\BepInEx\$name" -Destination "$stage\BepInEx" -Recurse
        }
    }
    $cache = Join-Path $game 'BepInEx\cache'
    if (Test-Path -LiteralPath $cache) {
        [IO.Directory]::CreateDirectory("$stage\BepInEx\cache") | Out-Null
        Get-ChildItem -LiteralPath $cache -Filter 'sideloader_zipmod_cache.bin*' -File |
            Copy-Item -Destination "$stage\BepInEx\cache"
    }
    foreach ($name in 'abdata','DefaultData','mods') {
        if (Test-Path -LiteralPath "$game\$name") {
            New-Item -ItemType Junction -Path "$stage\$name" -Target "$game\$name" | Out-Null
        }
    }
    $plugins = "$stage\BepInEx\plugins"
    $managed = "$stage\CharaStudio_Data\Managed"
    $compiler = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    $refs = @("$stage\BepInEx\core\BepInEx.dll","$plugins\KKSAPI.dll","$managed\Assembly-CSharp.dll","$managed\UnityEngine.dll",
        "$plugins\KKS_BepisPlugins\KKS_ExtensibleSaveFormat.dll")
    $refs += ('CoreModule','AnimationModule','AssetBundleModule','ImageConversionModule','JSONSerializeModule','ScreenCaptureModule','UIModule','ParticleSystemModule' | ForEach-Object { "$managed\UnityEngine.$_.dll" })
    $compilerArgs = @('/nologo','/target:library',"/out:$plugins\KksStudioCapture.dll")
    $compilerArgs += ($refs | ForEach-Object { "/reference:$_" })
    $cardCapture = "$PSScriptRoot\KksSceneCardCapture.cs"
    if (!(Test-Path -LiteralPath $cardCapture -PathType Leaf)) { $cardCapture = "$PSScriptRoot\KksCardCapture.cs" }
    $compilerArgs += $cardCapture, "$PSScriptRoot\KksStudioCapture.cs", "$PSScriptRoot\KksStudioVisualCapture.cs", "$PSScriptRoot\KksWorkspaceCapture.cs", "$PSScriptRoot\KksWorkspaceMaterial.cs"
    $compilerOutput = & $compiler @compilerArgs
    if ($LASTEXITCODE -ne 0) { throw ('Could not compile the scene capture plugin. ' + ($compilerOutput -join ' ')) }
    Confirm-NotCancelled

    $localScene = Join-Path "$stage\UserData\studio\scene" ([IO.Path]::GetFileName($source))
    Copy-Item -LiteralPath $source -Destination $localScene
    $capture = "$stage\export"
    [IO.Directory]::CreateDirectory($capture) | Out-Null
    $plan = "$stage\scene-plan.txt"
    $mode = if ($WorkspaceOnly) { 'workspace' } else { 'full' }
    Set-Content -LiteralPath $plan -Encoding UTF8 -Value @($localScene, $capture, "$Rate", $references, (Get-FileHash -LiteralPath $localScene).Hash, "$ReferenceStride", $JobDirectory, $mode)
    $log = if ($JobDirectory) { Join-Path $JobDirectory 'studio.log' } else { "$stage\capture.log" }
    Write-Output "CharaStudio log: $log"
    if ($JobDirectory) { [IO.File]::WriteAllText((Join-Path $JobDirectory 'log-path.txt'), $log) }
    Set-CaptureStatus 'launching'
    $env:MYPROJECT_KKS_SCENE_PLAN = $plan
    $launchArgs = @('-force-d3d11','-screen-width','960','-screen-height','540','-logFile',('"{0}"' -f $log))
    $process = Start-Process -FilePath "$stage\CharaStudio.exe" -WorkingDirectory $stage -WindowStyle Hidden -PassThru -ArgumentList $launchArgs
    $success = "$stage\scene-ok.txt"
    $capturedManifest = "$capture\scene.json"
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while (!$process.WaitForExit(500) -and !(Test-Path -LiteralPath $success) -and [DateTime]::UtcNow -lt $deadline) {
        Confirm-NotCancelled
    }
    # The manifest is written last, after the capture streams have closed.
    if (!(Test-Path -LiteralPath $capturedManifest -PathType Leaf)) {
        if ($process.HasExited) { throw "Scene capture failed (CharaStudio exit code $($process.ExitCode)). See $log" }
        Stop-Process -Id $process.Id
        throw "Scene capture timed out. See $log"
    }
    # The success marker is written after all streams close. Some Studio plugins delay shutdown.
    if (!$process.WaitForExit(5000)) {
        Stop-Process -Id $process.Id
        $process.WaitForExit()
    }
    Confirm-NotCancelled
    Set-CaptureStatus 'saving'
    Get-ChildItem -LiteralPath $capture -File | Where-Object Name -ne 'scene.json' | ForEach-Object {
        Move-Item -LiteralPath $_.FullName -Destination $output -Force
    }
    Move-Item -LiteralPath "$capture\scene.json" -Destination "$output\scene.json" -Force
    Remove-Item -LiteralPath $localScene
    Get-Item -LiteralPath "$output\scene.json"
} finally {
    if ($process -and !$process.HasExited) {
        Stop-Process -Id $process.Id -ErrorAction SilentlyContinue
        $null = $process.WaitForExit(5000)
    }
    $env:MYPROJECT_KKS_SCENE_PLAN = $previous
    $preserveFailedCapture = $ReferenceDirectory -and $capturedManifest -and
        !(Test-Path -LiteralPath (Join-Path $output 'scene.json'))
    if ($JobDirectory -and !$preserveFailedCapture -and (Test-Path -LiteralPath $stage)) {
        $resolved = (Resolve-Path -LiteralPath $stage).Path
        $temporary = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
        if ([IO.Path]::GetDirectoryName($resolved) -eq $temporary -and
            [IO.Path]::GetFileName($resolved) -match '^Myproject-KKS-Scene-[a-f0-9]{32}$') {
            try {
                foreach ($name in 'abdata','DefaultData','mods') {
                    $link = Join-Path $resolved $name
                    if ([IO.Directory]::Exists($link)) { [IO.Directory]::Delete($link, $false) }
                }
                [IO.Directory]::Delete($resolved, $true)
            } catch { Write-Warning "Temporary CharaStudio copy could not be removed: $resolved" }
        }
    }
}
