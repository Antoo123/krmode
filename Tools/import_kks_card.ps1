[CmdletBinding(DefaultParameterSetName='Single')]
param(
    [Parameter(Mandatory)][string]$GameRoot,
    [Parameter(Mandatory,ParameterSetName='Single')][string]$Card,
    [ValidateSet(0, 1, 255)][int]$Sex = 255,
    [Parameter(Mandatory,ParameterSetName='Single')][string]$Output,
    [Parameter(Mandatory,ParameterSetName='Batch')][string]$BatchPlan,
    [int]$Coordinate = -1,
    [string]$Outfit = '',
    [ValidatePattern('^[^\r\n]+$')][string]$BodyGuid,
    [ValidatePattern('^[^\r\n]+$')][string]$PenisGuid,
    [ValidatePattern('^[^\r\n]+$')][string]$BallsGuid,
    [int]$TimeoutSeconds = 180
)

$ErrorActionPreference = 'Stop'
$game = (Resolve-Path -LiteralPath $GameRoot).Path
$cardPath = if ($Card) { (Resolve-Path -LiteralPath $Card).Path } else { '' }
$outfitPath = if ($Outfit) { (Resolve-Path -LiteralPath $Outfit).Path } else { '' }
$outputPath = if ($Output) { [IO.Path]::GetFullPath($Output) } else { '' }
$rows = if ($BatchPlan) { [IO.File]::ReadAllLines((Resolve-Path -LiteralPath $BatchPlan).Path) } else { @($cardPath, "$Sex", "$Coordinate", $outputPath, $outfitPath) }
if (!$rows.Count -or $rows.Count % 5) { throw 'Malformed card import plan.' }
$outputDirectories = for ($i = 3; $i -lt $rows.Count; $i += 5) {
    $rows[$i] = [IO.Path]::GetFullPath($rows[$i])
    if ($rows[$i].StartsWith($game.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Choose an output file outside the game installation.'
    }
    [IO.Path]::GetDirectoryName($rows[$i])
}
$hasher = [Security.Cryptography.SHA256]::Create()
try {
    $key = [BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($game))).Replace('-', '').Substring(0, 16)
} finally {
    $hasher.Dispose()
}
$stage = Join-Path ([IO.Path]::GetTempPath()) ("Myproject-KKS-Card-" + $key)
$mutex = [Threading.Mutex]::new($false, "MyprojectKksCard" + $key)
$locked = $false
try {
    try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (!$locked) { throw 'The card importer is already processing another card.' }
    $plugins = "$stage\BepInEx\plugins"
    New-Item -ItemType Directory -Force -Path $plugins | Out-Null
    foreach ($directory in ($outputDirectories | Select-Object -Unique)) {
        [IO.Directory]::CreateDirectory($directory) | Out-Null
    }
    foreach ($name in 'CharaStudio.exe','UnityPlayer.dll','UnityCrashHandler64.exe','winhttp.dll','doorstop_config.ini','CharaStudio_Data','MonoBleedingEdge') {
        if (!(Test-Path -LiteralPath "$stage\$name")) {
            Copy-Item -LiteralPath "$game\$name" -Destination $stage -Recurse
        }
    }
    foreach ($name in 'core','config') {
        if (!(Test-Path -LiteralPath "$stage\BepInEx\$name")) {
            Copy-Item -LiteralPath "$game\BepInEx\$name" -Destination "$stage\BepInEx" -Recurse
        }
    }
    $uncensorConfig = 'com.deathweasel.bepinex.uncensorselector.cfg'
    $settings = Join-Path "$game\BepInEx\config" $uncensorConfig
    if (Test-Path -LiteralPath $settings) {
        Copy-Item -LiteralPath $settings -Destination "$stage\BepInEx\config\$uncensorConfig" -Force
    }
    foreach ($name in 'abdata','DefaultData','mods') {
        if (!(Test-Path -LiteralPath "$stage\$name") -and (Test-Path -LiteralPath "$game\$name")) {
            New-Item -ItemType Junction -Path "$stage\$name" -Target "$game\$name" | Out-Null
        }
    }
    foreach ($name in 'KKSAPI.dll','KKSAPI.NativeHelper.dll','KKSABMX.dll','MoreAccessories.dll','ModBoneImplantor.dll',
        'ConfigurationManager\ConfigurationManager.dll','XUnity.ResourceRedirector',
        'KKS_Plugins\KKS_MaterialEditor.dll','KKS_Plugins\KKS_UncensorSelector.dll','OverlayMods','KKS_BepisPlugins') {
        $source = "$game\BepInEx\plugins\$name"
        $target = Join-Path $plugins (Split-Path $name -Leaf)
        if ((Test-Path -LiteralPath $source) -and !(Test-Path -LiteralPath $target)) {
            Copy-Item -LiteralPath $source -Destination $plugins -Recurse
        }
    }
    $managed = "$stage\CharaStudio_Data\Managed"
    $compiler = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    $refs = @("$stage\BepInEx\core\BepInEx.dll","$plugins\KKSAPI.dll","$managed\Assembly-CSharp.dll","$managed\UnityEngine.dll")
    $refs += ('CoreModule','AnimationModule','AssetBundleModule','ImageConversionModule' | ForEach-Object { "$managed\UnityEngine.$_.dll" })
    $pluginSource = Join-Path $PSScriptRoot 'KksCardCapture.cs'
    $pluginTarget = Join-Path $plugins 'KksCardCapture.dll'
    $pluginStamp = Join-Path $stage 'card-plugin.sha256'
    $sourceHash = (Get-FileHash -LiteralPath $pluginSource -Algorithm SHA256).Hash
    $compiledHash = if (Test-Path -LiteralPath $pluginStamp) { Get-Content -LiteralPath $pluginStamp } else { '' }
    if (!(Test-Path -LiteralPath $pluginTarget) -or $compiledHash -ne $sourceHash) {
        $compilerArgs = @('/nologo','/target:library',"/out:$pluginTarget")
        $compilerArgs += ($refs | ForEach-Object { "/reference:$_" })
        $compilerArgs += $pluginSource
        & $compiler @compilerArgs
        if ($LASTEXITCODE -ne 0) { throw 'Could not compile the card importer.' }
        Set-Content -LiteralPath $pluginStamp -Value $sourceHash -Encoding Ascii
    }
    $plan = "$stage\card-plan.txt"
    Set-Content -LiteralPath $plan -Encoding UTF8 -Value $rows
    $previousPlan = $env:MYPROJECT_KKS_CARD_PLAN
    $previousResult = $env:MYPROJECT_KKS_CARD_RESULT
    $previousBody = $env:MYPROJECT_KKS_BODY_GUID
    $previousPenis = $env:MYPROJECT_KKS_PENIS_GUID
    $previousBalls = $env:MYPROJECT_KKS_BALLS_GUID
    $result = Join-Path $stage ("result-" + [Guid]::NewGuid().ToString("N") + ".txt")
    $env:MYPROJECT_KKS_CARD_PLAN = $plan
    $env:MYPROJECT_KKS_CARD_RESULT = $result
    $env:MYPROJECT_KKS_BODY_GUID = $BodyGuid
    $env:MYPROJECT_KKS_PENIS_GUID = $PenisGuid
    $env:MYPROJECT_KKS_BALLS_GUID = $BallsGuid
    try {
        $log = "$stage\card.log"
        $launchArgs = @('-batchmode','-force-d3d11','-screen-width','640','-screen-height','480','-logFile',('"{0}"' -f $log))
        $process = Start-Process -FilePath "$stage\CharaStudio.exe" -WorkingDirectory $stage -WindowStyle Hidden -PassThru -ArgumentList $launchArgs
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        while (!$process.HasExited -and !(Test-Path -LiteralPath $result) -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 200
        }
        if (!$process.HasExited -and !$process.WaitForExit(2500)) {
            Stop-Process -Id $process.Id -ErrorAction SilentlyContinue
            if (!$process.WaitForExit(5000)) { throw "The staged Studio process did not shut down. See $log" }
        }
        if (!(Test-Path -LiteralPath $result)) { throw "The importer exited without a result. See $log" }
        $message = Get-Content -LiteralPath $result -Raw
        if ($message -ne 'ok' -or ($outputPath -and !(Test-Path -LiteralPath $outputPath))) { throw "Card import failed: $message. See $log" }
        if ($outputPath) { Get-Item -LiteralPath $outputPath }
    } finally {
        $env:MYPROJECT_KKS_CARD_PLAN = $previousPlan
        $env:MYPROJECT_KKS_CARD_RESULT = $previousResult
        $env:MYPROJECT_KKS_BODY_GUID = $previousBody
        $env:MYPROJECT_KKS_PENIS_GUID = $previousPenis
        $env:MYPROJECT_KKS_BALLS_GUID = $previousBalls
    }
} finally {
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
