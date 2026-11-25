param(
    [Parameter(Mandatory)][string]$GameRoot,
    [Parameter(Mandatory)][string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$game = (Resolve-Path -LiteralPath $GameRoot).Path
$stage = Join-Path ([IO.Path]::GetTempPath()) ("KksMotion-" + [Guid]::NewGuid().ToString("N"))
$output = [IO.Path]::GetFullPath($OutputDirectory)
if ($output.StartsWith($game, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Choose an output directory outside the game installation.'
}
New-Item -ItemType Directory -Force -Path "$stage\BepInEx\plugins", $output | Out-Null
foreach ($name in 'CharaStudio.exe','UnityPlayer.dll','UnityCrashHandler64.exe','winhttp.dll','doorstop_config.ini','CharaStudio_Data','MonoBleedingEdge') {
    Copy-Item -LiteralPath "$game\$name" -Destination $stage -Recurse
}
Copy-Item -LiteralPath "$game\BepInEx\core" -Destination "$stage\BepInEx" -Recurse
foreach ($name in 'abdata','DefaultData') {
    New-Item -ItemType Junction -Path "$stage\$name" -Target "$game\$name" | Out-Null
}

$managed = "$stage\CharaStudio_Data\Managed"
$compiler = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
$compilerArgs = @('/nologo', '/target:library', "/out:$stage\BepInEx\plugins\KksMotionCapture.dll",
    "/reference:$stage\BepInEx\core\BepInEx.dll", "/reference:$managed\UnityEngine.dll")
$compilerArgs += ('CoreModule','AnimationModule','AssetBundleModule','JSONSerializeModule' | ForEach-Object {
    "/reference:$managed\UnityEngine.$_.dll"
})
$compilerArgs += Join-Path $PSScriptRoot 'KksMotionCapture.cs'
& $compiler @compilerArgs
if ($LASTEXITCODE -ne 0) { throw 'Could not compile the motion capture plugin.' }

Add-Type -AssemblyName System.IO.Compression.FileSystem
$mods = "$game\mods\Sideloader Modpack - Animations"
$mod = Get-ChildItem -LiteralPath $mods -Recurse -Filter '*Mixamo*.zipmod' -File | Select-Object -First 1
if (!$mod) { throw 'The Mixamo animations zipmod is missing.' }
$danceBundle = 'abdata/studio/anime/mixamo_dance_part1.unity3d'
$archive = [IO.Compression.ZipFile]::OpenRead($mod.FullName)
try {
    $entry = $archive.GetEntry($danceBundle)
    if (!$entry) { throw "Missing animation bundle: $danceBundle" }
    [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, "$stage\dance.unity3d")
} finally {
    $archive.Dispose()
}

$plan = "$stage\plan.txt"
Set-Content -LiteralPath $plan -Encoding UTF8 -Value @(
    "$game\abdata\chara\oo_base.unity3d",
    "$stage\dance.unity3d", 'Arms Hip Hop', "$($mod.Name) / $danceBundle", "$output\Dance.json",
    "$game\abdata\action\animator\00.unity3d", 'mc_m_walk_00_00_01', 'abdata/action/animator/00.unity3d', "$output\Walk.json",
    "$game\abdata\studio\anime\70.unity3d", 'Stand_42_00', 'abdata/studio/anime/70.unity3d', "$output\Idle.json"
)
$previousPlan = $env:MYPROJECT_KKS_CAPTURE_PLAN
$env:MYPROJECT_KKS_CAPTURE_PLAN = $plan
try {
    $captureLog = "$stage\capture.log"
    $launchArgs = @('-batchmode','-nographics','-logFile',('"{0}"' -f $captureLog))
    $process = Start-Process -FilePath "$stage\CharaStudio.exe" -WorkingDirectory $stage -WindowStyle Hidden -PassThru -ArgumentList $launchArgs
    if (!$process.WaitForExit(45000)) {
        Stop-Process -Id $process.Id
        throw "Capture timed out. See $captureLog"
    }
    if ($process.ExitCode -ne 0) { throw "Capture failed. See $captureLog" }
    Get-Item -LiteralPath "$output\Dance.json","$output\Walk.json","$output\Idle.json"
} finally {
    $env:MYPROJECT_KKS_CAPTURE_PLAN = $previousPlan
}
