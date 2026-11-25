param([Parameter(Mandatory)][string]$JobDirectory)

$ErrorActionPreference = 'Stop'
$job = (Resolve-Path -LiteralPath $JobDirectory).Path
$payload = Join-Path $job 'payload'
$log = ''
$result = @{ status = 'failed'; message = 'Import did not complete.' }

function Read-SceneVersion([string]$File) {
    $inputFile = [IO.File]::OpenRead($File)
    $reader = [IO.BinaryReader]::new($inputFile)
    try {
        if ([BitConverter]::ToString($reader.ReadBytes(8)) -ne '89-50-4E-47-0D-0A-1A-0A') {
            throw 'Invalid PNG signature.'
        }
        $end = $false
        $first = $true
        while ($inputFile.Length - $inputFile.Position -ge 12) {
            $bytes = $reader.ReadBytes(4)
            [array]::Reverse($bytes)
            $size = [BitConverter]::ToUInt32($bytes, 0)
            $kind = [Text.Encoding]::ASCII.GetString($reader.ReadBytes(4))
            if ($first -and ($kind -ne 'IHDR' -or $size -ne 13)) { throw 'The PNG header is invalid.' }
            $first = $false
            if ([long]$size + 4 -gt $inputFile.Length - $inputFile.Position) { throw 'The PNG is truncated.' }
            $inputFile.Position += [long]$size + 4
            if ($kind -eq 'IEND' -and $size -eq 0) { $end = $true; break }
        }
        if (!$end -or $inputFile.Length - $inputFile.Position -lt 16) { throw 'The PNG has no CharaStudio scene data.' }
        $size = $reader.ReadByte()
        if ($size -lt 5 -or $size -gt 32) { throw 'The PNG is not a CharaStudio scene.' }
        $version = [Text.Encoding]::ASCII.GetString($reader.ReadBytes($size))
        if ($version -notmatch '^\d+\.\d+\.\d+(\.\d+)?$') { throw 'Unrecognized CharaStudio scene format.' }
        return $version
    } finally { $reader.Dispose() }
}

function Find-Current([string]$Directory) {
    $pointer = Join-Path $Directory 'current.json'
    if (!(Test-Path -LiteralPath $pointer -PathType Leaf)) { return $null }
    $revision = (Get-Content -LiteralPath $pointer -Raw -Encoding UTF8 | ConvertFrom-Json).revision
    if ($revision -notmatch '^rev-[a-f0-9]{32}$') { throw 'The saved scene index is damaged.' }
    $path = Join-Path $Directory "$revision\scene.json"
    if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
}

function Confirm-ActorFiles($Actor, [int]$Frames) {
    foreach ($filename in @($Actor.model, $Actor.motion, $Actor.visuals)) {
        if (!$filename -or [IO.Path]::GetFileName($filename) -ne $filename -or
            !(Test-Path -LiteralPath (Join-Path $payload $filename) -PathType Leaf)) {
            throw 'CharaStudio did not save all character assets.'
        }
    }
    $card = [IO.BinaryReader]::new([IO.File]::OpenRead((Join-Path $payload $Actor.model)))
    $track = [IO.BinaryReader]::new([IO.File]::OpenRead((Join-Path $payload $Actor.motion)))
    try {
        $format = $card.ReadUInt32()
        $bones = $card.ReadUInt32()
        $magic = $track.ReadUInt32()
        $count = $track.ReadUInt32()
        $trackBones = $track.ReadUInt32()
        $tracks = $track.ReadUInt32()
        if ($format -ne 0x3853434B -or $bones -lt 1 -or $bones -gt 4096 -or $magic -ne 0x3154534b -or
            $count -ne $Frames -or $trackBones -ne $bones -or $tracks -lt 1 -or $tracks -gt $bones -or
            $track.BaseStream.Length -ne 16L + $tracks * (4L + $Frames * 40L)) {
            throw 'CharaStudio returned incompatible skeleton or animation data.'
        }
    } finally { $card.Dispose(); $track.Dispose() }
}

try {
    [IO.File]::WriteAllText((Join-Path $job 'phase.txt'), 'checking')
    $request = Get-Content -LiteralPath (Join-Path $job 'request.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $source = (Get-Item -LiteralPath $request.source).FullName
    if ([IO.Path]::GetExtension($source) -ne '.png') { throw 'Choose a CharaStudio PNG.' }
    $sourceVersion = Read-SceneVersion $source
    $hash = (Get-FileHash -LiteralPath $source).Hash
    $root = (Get-Item -LiteralPath $request.library).FullName
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $id = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($source.ToUpperInvariant()))).Replace('-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
    $directory = Join-Path $root $id
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $lock = [IO.File]::Open((Join-Path $directory 'import.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    $prior = Find-Current $directory
    $existing = if ($prior) { Get-Content -LiteralPath $prior -Raw -Encoding UTF8 | ConvertFrom-Json }
    $currentImportVersion = 3
    $workspaceOnly = [bool]($request.workspaceOnly -or
        ($existing -and !$request.force -and $existing.importVersion -lt $currentImportVersion -and $existing.sha256 -eq $hash))
    if ($workspaceOnly -and (!$existing -or $existing.sha256 -ne $hash)) {
        throw 'The source PNG changed. Use Reimport Scene to rebuild both characters and Workspace.'
    }
    if ($prior -and !$request.force) {
        if (!$workspaceOnly -and $existing.sha256 -eq $hash -and $existing.importVersion -eq $currentImportVersion) {
            $result = @{status='existing'; manifest=$prior; warnings=@($existing.warnings); message='This scene is already imported.'}
            return
        }
    }
    if (!(Test-Path -LiteralPath (Join-Path $request.gameRoot 'CharaStudio.exe') -PathType Leaf)) {
        throw 'CharaStudio.exe was not found. Set the Koikatsu Sunshine installation in F1.'
    }
    try { $captureLock = [IO.File]::Open((Join-Path $root '.capture.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
    catch [IO.IOException] { throw 'Another scene capture is already running for this library.' }
    $disk = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($root))
    if ($disk.IsReady -and $disk.AvailableFreeSpace -lt 1GB) { throw 'The scene library has less than 1 GiB of free disk space.' }
    $arguments = @{
        GameRoot=$request.gameRoot; Scene=$source; OutputDirectory=$payload
        Rate=30; TimeoutSeconds=1200; JobDirectory=$job
    }
    if ($workspaceOnly) {
        $arguments.WorkspaceOnly = $true
        $arguments.Rate = if ($existing.duration -ge 120) { 8 } else { 30 }
    }
    if ($request.references) {
        $arguments.ReferenceDirectory = Join-Path $job 'references'
        $arguments.ReferenceStride = if ($workspaceOnly -and $existing.duration -ge 120) { 240 } else { 8 }
    }
    & (Join-Path $PSScriptRoot 'import_kks_scene.ps1') @arguments | Out-Null
    if (Test-Path -LiteralPath (Join-Path $job 'cancel')) { throw [OperationCanceledException]::new() }
    $manifestPath = Join-Path $payload 'scene.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($manifest.sha256 -ne $hash) { throw 'The source PNG changed during capture. Import it again.' }
    $workspace = Get-Content -LiteralPath (Join-Path $payload 'workspace.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($workspace.version -ne 1 -or $workspace.frames -lt 1 -or !$workspace.PSObject.Properties['entries']) {
        throw 'Workspace capture is incomplete.'
    }
    if ($workspaceOnly) {
        if ([Math]::Abs([double]$existing.duration - [double]$manifest.duration) -gt 0.02) {
            throw 'Source playback duration changed. Reimport the full scene to align objects and actors.'
        }
        Get-ChildItem -LiteralPath (Split-Path -Parent $prior) -File | Where-Object {
            $_.Name -ne 'scene.json' -and $_.Name -ne 'workspace.json' -and $_.Name -notmatch '^prop-\d+\.'
        } | ForEach-Object {
            $target = Join-Path $payload $_.Name
            if (!(Test-Path -LiteralPath $target)) { Copy-Item -LiteralPath $_.FullName -Destination $target }
        }
        $manifest = $existing
    }
    if ($manifest.version -ne 1 -or $manifest.frames -lt 1) {
        throw 'CharaStudio returned an incomplete scene.'
    }
    foreach ($actor in $manifest.actors) { Confirm-ActorFiles $actor $manifest.frames }
    $log = [IO.File]::ReadAllText((Join-Path $job 'log-path.txt'))
    $missing = @(Select-String -LiteralPath $log -Pattern 'Missing mod detected!\s*\[([^\]]+)\]' |
        ForEach-Object { $_.Matches[0].Groups[1].Value } | Sort-Object -Unique)
    $warnings = @()
    if ($missing.Count) { $warnings += 'Missing mods: ' + ($missing -join ', ') }
    if (@($manifest.unboundTracks).Count) { $warnings += 'Unbound Timeline tracks: ' + ($manifest.unboundTracks -join ', ') }
    if (Select-String -LiteralPath $log -Pattern '\[Error\s+:NodesConstraints\].*Could not load' -Quiet) {
        $warnings += 'CharaStudio reported a NodesConstraints load error. Some source links may be missing.'
    }
    if ($manifest.map -ge 0) { $warnings += 'The Studio map needs a separate export.' }
    $warnings += @($workspace.warnings | Where-Object { $_ })
    $unsupported = @($workspace.entries | Where-Object { $_.issue -and $_.type -eq 'OCIItem' })
    if ($unsupported.Count) { $warnings += "$($unsupported.Count) Workspace items have no supported mesh or require effects. See Scene Objects." }
    $manifest | Add-Member -NotePropertyMembers @{
        id=$id; title=[IO.Path]::GetFileNameWithoutExtension($source); sourcePath=$source
        sourceVersion=$sourceVersion; importVersion=$currentImportVersion; actorCount=@($manifest.actors).Count
        status='ready'; missingMods=$missing; warnings=$warnings
        workspaceDetached=(!$workspaceOnly -or [bool]$existing.workspaceDetached)
        contactReview=(@($manifest.actors).Count -gt 1)
    } -Force
    $manifest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    if ($prior) {
        foreach ($name in 'staging.json','visual-tuning.json') {
            $sidecar = Join-Path (Split-Path -Parent $prior) $name
            if ((Test-Path -LiteralPath $sidecar -PathType Leaf) -and !(Test-Path -LiteralPath (Join-Path $payload $name))) {
                Copy-Item -LiteralPath $sidecar -Destination $payload
            }
        }
        $stagingPath = Join-Path $payload 'staging.json'
        if (Test-Path -LiteralPath $stagingPath -PathType Leaf) {
            $staging = Get-Content -LiteralPath $stagingPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $scenery = [IO.Path]::GetFileName([string]$staging.scenery)
            if ($scenery -and [IO.Path]::GetExtension($scenery) -eq '.glb') {
                $asset = Join-Path (Split-Path -Parent $prior) $scenery
                if ((Test-Path -LiteralPath $asset -PathType Leaf) -and !(Test-Path -LiteralPath (Join-Path $payload $scenery))) {
                    Copy-Item -LiteralPath $asset -Destination $payload
                }
            }
        }
    }
    $revision = 'rev-' + [Guid]::NewGuid().ToString('N')
    $destination = Join-Path $directory $revision
    [IO.Directory]::Move($payload, $destination)
    $pointer = Join-Path $directory 'current.json'
    $temporary = Join-Path $directory "$revision.json"
    [IO.File]::WriteAllText($temporary, (@{revision=$revision; source=$manifest.source} | ConvertTo-Json -Compress))
    if (Test-Path -LiteralPath $pointer) {
        $backup = Join-Path $directory "$revision.previous.json"
        [IO.File]::Replace($temporary, $pointer, $backup)
        try { [IO.File]::Delete($backup) } catch { Write-Warning "Could not remove backup index: $backup" }
    } else { [IO.File]::Move($temporary, $pointer) }
    $result = @{status='ready'; manifest=(Join-Path $destination 'scene.json'); warnings=$warnings; message='Scene imported.'}
    # Keep the live revision and the last working revision for readers in another game instance.
    $previousRevision = if ($prior) { Split-Path -Leaf (Split-Path -Parent $prior) } else { '' }
    Get-ChildItem -LiteralPath $directory -Directory | Where-Object {
        $_.Name -match '^rev-[a-f0-9]{32}$' -and $_.Name -ne $revision -and $_.Name -ne $previousRevision -and
        !($_.Attributes -band [IO.FileAttributes]::ReparsePoint)
    } | ForEach-Object {
        $oldRevision = (Resolve-Path -LiteralPath $_.FullName).Path
        if ([IO.Path]::GetDirectoryName($oldRevision) -eq $directory) {
            try { [IO.Directory]::Delete($oldRevision, $true) } catch { Write-Warning "Could not remove old scene revision: $oldRevision" }
        }
    }
} catch {
    $result.message = $_.Exception.Message
    if ($_.Exception -is [OperationCanceledException]) { $result = @{status='cancelled'; message='Import cancelled.'} }
    if (Test-Path -LiteralPath (Join-Path $job 'log-path.txt')) {
        $log = [IO.File]::ReadAllText((Join-Path $job 'log-path.txt'))
        if (Test-Path -LiteralPath $log) {
            $detail = Get-Content -LiteralPath $log -Encoding UTF8 -Tail 250 |
                Where-Object { $_ -match '\[Error\s+:Godot Studio scene capture\]' } | Select-Object -Last 1
            if ($detail) { $result.message = "$($result.message) $detail" }
        }
    }
} finally {
    if ($captureLock) { $captureLock.Dispose() }
    if ($lock) { $lock.Dispose() }
    if ([IO.Directory]::Exists($payload)) {
        try { [IO.Directory]::Delete($payload, $true) } catch { Write-Warning "Could not remove incomplete scene files: $payload" }
    }
    $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $job 'result.json') -Encoding UTF8
}
