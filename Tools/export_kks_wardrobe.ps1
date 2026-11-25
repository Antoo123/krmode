param(
    [Parameter(Mandatory)][string]$GameRoot,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$FemaleCard,
    [Parameter(Mandatory)][string]$MaleCard,
    [int]$LimitPerSlot = 0,
    [ValidateRange(101, 112)][int]$Category
)

$ErrorActionPreference = 'Stop'
$target = [IO.Path]::GetFullPath($OutputDirectory)
$game = (Resolve-Path -LiteralPath $GameRoot).Path
if ($target.StartsWith($game.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Choose a wardrobe directory outside the game installation.'
}
$env:MYPROJECT_KKS_WARDROBE = $target
$env:MYPROJECT_KKS_WARDROBE_LIMIT = "$LimitPerSlot"
$env:MYPROJECT_KKS_WARDROBE_CATEGORY = if ($PSBoundParameters.ContainsKey('Category')) { "$Category" } else { '' }
$env:MYPROJECT_KKS_COMPARE = ''
$importer = Join-Path $PSScriptRoot 'import_kks_card.ps1'
foreach ($item in @(@($FemaleCard,1), @($MaleCard,0))) {
    $scratch = Join-Path ([IO.Path]::GetTempPath()) ("KksWardrobe-" + [Guid]::NewGuid().ToString("N") + ".kcs")
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File $importer -GameRoot $game -Card $item[0] -Sex $item[1] -Output $scratch -TimeoutSeconds 43200
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
