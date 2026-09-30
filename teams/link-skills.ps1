# Link each profile's skills into teams\<profile>\.claude\skills\ and .agents\skills\ (junctions, no admin needed).
# Run from the repo root. Thin wrapper: the logic lives in link-skills.js next to this file.
# Windows blocks unsigned scripts by default, so run it as:
#
#   powershell -ExecutionPolicy Bypass -File teams\link-skills.ps1            link what is on this machine
#   powershell -ExecutionPolicy Bypass -File teams\link-skills.ps1 -Install   also `npx skills add` anything missing
#   powershell -ExecutionPolicy Bypass -File teams\link-skills.ps1 -Confine   also drop ~\.claude\skills\<name> links
#   powershell -ExecutionPolicy Bypass -File teams\link-skills.ps1 -Relock    accept current hashes into teams\skills-lock.json
#
# Or directly: node teams\link-skills.js --install --confine
param([switch]$Install, [switch]$Confine, [switch]$Relock)

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Host "node not found; install Node 18+ (winget install OpenJS.NodeJS.LTS), open a new terminal, and re-run"
    exit 1
}
$js = Join-Path $PSScriptRoot "link-skills.js"
if (-not (Test-Path -LiteralPath $js)) {
    Write-Host "$js missing; re-run Proteus's install.ps1 -Project"
    exit 1
}
$flags = @()
if ($Install) { $flags += "--install" }
if ($Confine) { $flags += "--confine" }
if ($Relock)  { $flags += "--relock" }
& node $js @flags
exit $LASTEXITCODE
