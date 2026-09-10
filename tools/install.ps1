param(
    [Parameter(Mandatory = $true)][string]$Ashita
)

$repo = Split-Path -Parent $PSScriptRoot
$target = Join-Path $Ashita "addons\pafo"

if (Test-Path $target) {
    Write-Host "already exists: $target"
    exit 0
}

cmd /c mklink /J "$target" "$repo" | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "mklink failed"
    exit 1
}
Write-Host "linked $target -> $repo"
