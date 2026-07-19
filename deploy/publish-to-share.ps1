# Publishes GolfGroupAdminWebsite to the production share served by IIS:
#   T:\Websites\GolfGroupAdminWebsite
#
# Flow: publish locally -> drop app_offline.htm so IIS releases the DLL ->
# mirror files -> remove app_offline.htm. Copies with robocopy /E but PRESERVES
# server-side config/state: appsettings.Production.json, logs\, and umbraco\Data
# (the SQLite/keys/temp Umbraco keeps next to the app) are never deleted or
# overwritten.
#
#   .\deploy\publish-to-share.ps1            # publish + deploy
#   .\deploy\publish-to-share.ps1 -DryRun    # show what robocopy would change, copy nothing
#
# NOTE: the published site runs in the Production environment, where user-secrets
# do NOT load. The DB connection string must be supplied on the server, e.g. set
# the IIS app-pool env var  ConnectionStrings__umbracoDbDSN  (preferred), or place
# an appsettings.Production.json in the target. This script never writes the secret.
param(
    [string]$Target = 'T:\Websites\GolfGroupAdminWebsite',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$RepoRoot   = Split-Path -Parent $PSScriptRoot
$PublishDir = Join-Path $RepoRoot 'artifacts\publish'

if (-not (Test-Path $Target)) { throw "Target '$Target' is not reachable. Is the T: share mapped?" }

Write-Host "Publishing (Release) to $PublishDir ..."
dotnet publish "$RepoRoot\GolfGroupAdminWebsite.csproj" -c Release -o $PublishDir --nologo
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed ($LASTEXITCODE)" }

# Never push these to the server (they hold server-side secrets/state).
Remove-Item (Join-Path $PublishDir 'appsettings.Production.json') -Force -ErrorAction SilentlyContinue

$offline = Join-Path $Target 'app_offline.htm'
$mainDll = Join-Path $Target 'GolfGroupAdminWebsite.dll'

# /E (copy new+changed, recurse) deliberately instead of /MIR.
#
# /MIR implies /PURGE, which deletes anything at the destination that is not in
# the publish output - and that includes live server state: wwwroot\media (the
# editors' uploaded files), umbraco\Logs, and umbraco\Data. Excluding them with
# /XD does NOT reliably stop the purge (lesson learned on YachtCrossing).
#
# Trade-off: files removed from the app are no longer cleaned off the server.
# Stale unreferenced assemblies are harmless; deleting the media library is not.
# For a genuine clean deploy, empty the target manually (preserving the state
# folders below) and re-run.
$roboArgs = @($PublishDir, $Target, '/E', '/R:3', '/W:2', '/NFL', '/NDL', '/NP',
              '/XF', 'app_offline.htm', 'appsettings.Production.json',
              '/XD', (Join-Path $Target 'logs'),
                     (Join-Path $Target 'umbraco\Data'),
                     (Join-Path $Target 'umbraco\Logs'))

if ($DryRun) {
    Write-Host "DRY RUN - robocopy /L (no changes):"
    robocopy @roboArgs '/L' | Out-Host
    return
}

# app_offline makes IIS unload the app so the DLL is released. How long that
# takes varies (Umbraco shuts down slowly), so poll instead of guessing.
function Wait-ForUnlock([string]$Path, [int]$TimeoutSeconds = 45) {
    if (-not (Test-Path $Path)) { return $true }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try { $fs = [IO.File]::Open($Path, 'Open', 'ReadWrite', 'None'); $fs.Close(); return $true }
        catch { Start-Sleep -Milliseconds 500 }
    }
    return $false
}

try {
    Set-Content -Path $offline -Value '<html><body>Deploying, back shortly.</body></html>' -Encoding utf8
    if (-not (Wait-ForUnlock $mainDll)) {
        Write-Warning "GolfGroupAdminWebsite.dll still locked after 45s; copy may need robocopy retries."
    }
    robocopy @roboArgs | Out-Host
    if ($LASTEXITCODE -ge 8) { throw "robocopy reported errors ($LASTEXITCODE)" }

    # Umbraco's build targets exclude wwwroot\media from publish output (media is
    # normally server-side state). On this site the media library originates in
    # dev and is tracked by uSync, so sync it additively from the project folder.
    # /E without /PURGE: never deletes anything uploaded on the server.
    $mediaSrc = Join-Path $RepoRoot 'wwwroot\media'
    if (Test-Path $mediaSrc) {
        robocopy $mediaSrc (Join-Path $Target 'wwwroot\media') /E /R:3 /W:2 /NFL /NDL /NP | Out-Host
        if ($LASTEXITCODE -ge 8) { throw "media robocopy reported errors ($LASTEXITCODE)" }
    }

    # robocopy can report a 'successful' exit code even when the main assembly was
    # skipped because it was locked - which would silently deploy nothing.
    $srcDll = Join-Path $PublishDir 'GolfGroupAdminWebsite.dll'
    if ((Get-FileHash $srcDll).Hash -ne (Get-FileHash $mainDll).Hash) {
        throw "GolfGroupAdminWebsite.dll on the target does not match the publish output - the deploy did NOT take effect."
    }
    Write-Host "Deployed to $Target (GolfGroupAdminWebsite.dll verified)."
} finally {
    Remove-Item $offline -Force -ErrorAction SilentlyContinue
    Write-Host "Removed app_offline.htm - site is back online."
}
