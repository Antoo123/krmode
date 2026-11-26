[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$GameRoot,
    [Parameter(Mandatory)][string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$game = (Resolve-Path -LiteralPath $GameRoot).Path
$output = [IO.Path]::GetFullPath($OutputDirectory)
if ($output -eq $game -or $output.StartsWith($game.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Choose an output directory outside the game installation.'
}
if ((Test-Path -LiteralPath $output) -and @(Get-ChildItem -LiteralPath $output -Force).Count) {
    throw 'Choose an empty output directory for the hand capture.'
}
[IO.Directory]::CreateDirectory($output) | Out-Null
$stage = Join-Path ([IO.Path]::GetTempPath()) ('Myproject-KKS-Hands-' + [Guid]::NewGuid().ToString('N'))
$plugins = Join-Path $stage 'BepInEx\plugins'
[IO.Directory]::CreateDirectory($plugins) | Out-Null
foreach ($name in 'CharaStudio.exe','UnityPlayer.dll','UnityCrashHandler64.exe','winhttp.dll','doorstop_config.ini','CharaStudio_Data','MonoBleedingEdge') {
    Copy-Item -LiteralPath "$game\$name" -Destination $stage -Recurse
}
Copy-Item -LiteralPath "$game\BepInEx\core" -Destination "$stage\BepInEx" -Recurse
Copy-Item -LiteralPath "$game\BepInEx\plugins\KKSAPI.dll" -Destination $plugins
foreach ($name in 'abdata','DefaultData') {
    New-Item -ItemType Junction -Path "$stage\$name" -Target "$game\$name" | Out-Null
}
$managed = "$stage\CharaStudio_Data\Managed"
$references = @("$stage\BepInEx\core\BepInEx.dll","$plugins\KKSAPI.dll","$managed\Assembly-CSharp.dll","$managed\UnityEngine.dll")
$references += ('CoreModule','AnimationModule','AssetBundleModule','ImageConversionModule' | ForEach-Object { "$managed\UnityEngine.$_.dll" })
$arguments = @('/nologo','/target:library',"/out:$plugins\KksHandCapture.dll")
$arguments += ($references | ForEach-Object { "/reference:$_" })
$arguments += "$PSScriptRoot\KksCardCapture.cs","$PSScriptRoot\KksHandCapture.cs"
& "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" @arguments
if ($LASTEXITCODE -ne 0) { throw 'Could not compile the hand capture plugin.' }
$previous = $env:MYPROJECT_KKS_HAND_OUTPUT
$log = "$stage\hands.log"
Write-Output "CharaStudio log: $log"
try {
    $env:MYPROJECT_KKS_HAND_OUTPUT = $output
    $launch = @('-batchmode','-force-d3d11','-logFile',('"{0}"' -f $log))
    $process = Start-Process -FilePath "$stage\CharaStudio.exe" -WorkingDirectory $stage -WindowStyle Hidden -PassThru -ArgumentList $launch
    if (!$process.WaitForExit(100000)) {
        Stop-Process -Id $process.Id
        throw "Hand capture timed out. See $log"
    }
    if (!(Test-Path -LiteralPath "$output\capture.ok")) {
        if (Test-Path -LiteralPath "$output\capture-error.txt") { Get-Content -LiteralPath "$output\capture-error.txt" }
        Get-Content -LiteralPath $log -Tail 25
        throw "Hand capture failed. See $log"
    }
    Get-ChildItem -LiteralPath $output -Filter '*.kcs'
} finally {
    $env:MYPROJECT_KKS_HAND_OUTPUT = $previous
}
