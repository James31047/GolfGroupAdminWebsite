# Configures IIS to host GolfGroupAdminWebsite. RUN THIS ON THE WEB SERVER
# (192.168.1.117) IN AN ELEVATED POWERSHELL. It cannot be run remotely - WinRM
# is not configured.
#
# Designed for a server hosting MULTIPLE sites:
#   * Creates a DEDICATED app pool. ASP.NET Core in-process hosting (what our
#     web.config uses) allows only ONE app per app pool, so pools are never shared.
#   * Binds public hostnames with HOST HEADERS, so it coexists with Default Web
#     Site (which holds port 80 as a catch-all). IIS matches the host header first.
#   * Refuses to take a binding another site already owns.
#   * Grants filesystem rights only to THIS pool's identity on THIS folder.
#
# Typical first run (public site + HTTPS):
#   .\setup-iis.ps1 -HostNames golfgroupadmin.com,www.golfgroupadmin.com `
#                   -ConnectionString 'Server=192.168.1.117;Database=GolfGroupAdminWebsiteDB;...' `
#                   -ApplicationUrl 'https://golfgroupadmin.com/' `
#                   -EnableHttps -ContactEmail you@example.com
#
# Other forms:
#   .\setup-iis.ps1                     # LAN only, http://<server>:8083
#   .\setup-iis.ps1 -Remove             # undo (site + pool only; files untouched)
#
# Secrets are stored as app-pool environment variables (applicationHost.config),
# never in a file on the share, so robocopy deploys can never clobber or leak them.
param(
    [string]  $SiteName         = 'GolfGroupAdminWebsite',
    [string]  $AppPoolName      = 'GolfGroupAdminWebsite',
    [string]  $SitePath         = 'H:\Websites\GolfGroupAdminWebsite',

    # Public hostnames to serve on $HttpPort. Empty = LAN-only on $ManagementPort.
    [string[]]$HostNames        = @(),
    [int]     $HttpPort         = 80,
    # Always-present hostname-less binding for direct LAN access / troubleshooting.
    # 8081 = YachtCrossing, 8082 = TotalAirplane, 8083 = this site.
    [int]     $ManagementPort   = 8083,

    [string]  $ConnectionString = '',
    [string]  $ApplicationUrl   = '',
    [string]  $HmacSecretKey    = '',

    # Apply the uSync files shipped with the deploy to this server's database.
    # Defaults to the 'Settings' handler group: document types, data types,
    # templates, languages etc - schema only, NEVER content. Importing content
    # would overwrite production's nodes with whatever dev last exported.
    [switch]  $ImportUSync,
    [string]  $USyncGroup       = 'Settings',

    # HTTPS via win-acme (Let's Encrypt). Requires $HostNames and public port 80.
    [switch]  $EnableHttps,
    [string]  $ContactEmail     = '',
    [string]  $WacsPath         = '',

    [switch]  $Remove
)

$ErrorActionPreference = 'Stop'

function Write-Step($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-Ok($m)   { Write-Host "    $m" -ForegroundColor Green }
function Write-Warn($m) { Write-Host "    $m" -ForegroundColor Yellow }

# ---- Pre-flight -----------------------------------------------------------
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this in an ELEVATED PowerShell (Run as Administrator)."
}
try { Import-Module WebAdministration -ErrorAction Stop }
catch { throw "The IIS PowerShell module is missing. Install IIS with 'IIS Management Scripts and Tools'." }

# ---- Remove path ----------------------------------------------------------
if ($Remove) {
    Write-Step "Removing site '$SiteName' and pool '$AppPoolName' (nothing else is touched)"
    if (Get-Website -Name $SiteName -ErrorAction SilentlyContinue) { Remove-Website -Name $SiteName; Write-Ok "Removed site." }
    else { Write-Warn "Site not present." }
    if (Test-Path "IIS:\AppPools\$AppPoolName") { Remove-WebAppPool -Name $AppPoolName; Write-Ok "Removed app pool." }
    else { Write-Warn "App pool not present." }
    Write-Host "`nDone. Files in $SitePath were left untouched." -ForegroundColor Green
    return
}

# ---- Hosting prerequisites -------------------------------------------------
Write-Step "Checking ASP.NET Core hosting prerequisites"
if (-not (Get-WebGlobalModule | Where-Object { $_.Name -eq 'AspNetCoreModuleV2' })) {
    throw @"
AspNetCoreModuleV2 is not installed. Install the ASP.NET Core 10 HOSTING BUNDLE
(not just the SDK/runtime): https://dotnet.microsoft.com/download/dotnet/10.0
Then: net stop was /y ; net start w3svc   - and re-run this script.
"@
}
Write-Ok "AspNetCoreModuleV2 present."
if (& dotnet --list-runtimes 2>$null | Where-Object { $_ -like 'Microsoft.AspNetCore.App 10.*' }) { Write-Ok "ASP.NET Core 10 runtime found." }
else { Write-Warn "No ASP.NET Core 10.x runtime detected. If the site 500s, install the .NET 10 Hosting Bundle." }

if (-not (Test-Path $SitePath)) { throw "Site path '$SitePath' not found. Deploy first (publish-to-share.ps1)." }
if (-not (Test-Path (Join-Path $SitePath 'web.config'))) { throw "'$SitePath' has no web.config - not a published site." }
Write-Ok "Found published site at $SitePath"

# ---- Work out the binding plan --------------------------------------------
# bindingInformation format is  IP:PORT:HOSTHEADER
$plan = @()
$plan += [pscustomobject]@{ Port = $ManagementPort; HostName = ''; Info = "*:$ManagementPort`:" }
foreach ($h in $HostNames) {
    $h = $h.Trim()
    if ($h) { $plan += [pscustomobject]@{ Port = $HttpPort; HostName = $h; Info = "*:$HttpPort`:$h" } }
}

Write-Step "Checking $($plan.Count) binding(s) against existing sites"
foreach ($b in $plan) {
    foreach ($site in Get-Website) {
        if ($site.Name -eq $SiteName) { continue }
        foreach ($eb in $site.Bindings.Collection) {
            if ($eb.protocol -ne 'http') { continue }
            if ($eb.bindingInformation -eq $b.Info) {
                throw "Binding '$($b.Info)' is already owned by site '$($site.Name)'. Choose a different port or hostname."
            }
            # A hostname-less binding on the same port elsewhere is only safe if OURS has a hostname.
            if ($eb.bindingInformation -eq "*:$($b.Port):" -and -not $b.HostName) {
                throw "Site '$($site.Name)' already binds port $($b.Port) with no host header. Give this site a -HostNames entry, or change -ManagementPort."
            }
        }
    }
    Write-Ok "$($b.Info)  free"
}
Write-Ok "Existing sites (untouched): $((Get-Website | ForEach-Object { $_.Name }) -join ', ')"

# ---- App pool -------------------------------------------------------------
Write-Step "Configuring dedicated app pool '$AppPoolName'"
if (-not (Test-Path "IIS:\AppPools\$AppPoolName")) { New-WebAppPool -Name $AppPoolName | Out-Null; Write-Ok "Created app pool." }
else { Write-Ok "App pool already exists - updating." }

Set-ItemProperty "IIS:\AppPools\$AppPoolName" -Name managedRuntimeVersion -Value ''          # 'No Managed Code'
Set-ItemProperty "IIS:\AppPools\$AppPoolName" -Name managedPipelineMode   -Value 'Integrated'
Set-ItemProperty "IIS:\AppPools\$AppPoolName" -Name processModel.identityType -Value 'ApplicationPoolIdentity'
Set-ItemProperty "IIS:\AppPools\$AppPoolName" -Name processModel.idleTimeout -Value ([TimeSpan]::Zero)
Set-ItemProperty "IIS:\AppPools\$AppPoolName" -Name recycling.periodicRestart.time -Value ([TimeSpan]::Zero)
Set-ItemProperty "IIS:\AppPools\$AppPoolName" -Name startMode -Value 'AlwaysRunning'
# Without a user profile, ASP.NET Core Data Protection uses an EPHEMERAL in-memory
# key ring: every recycle invalidates backoffice logins and antiforgery tokens.
Set-ItemProperty "IIS:\AppPools\$AppPoolName" -Name processModel.loadUserProfile -Value $true
Set-ItemProperty "IIS:\AppPools\$AppPoolName" -Name processModel.setProfileEnvironment -Value $true
Write-Ok "No Managed Code / ApplicationPoolIdentity / AlwaysRunning / LoadUserProfile."

# ---- App pool environment variables ---------------------------------------
Write-Step "Setting environment variables on the app pool"
$envFilter = "system.applicationHost/applicationPools/add[@name='$AppPoolName']/environmentVariables"
function Set-PoolEnv([string]$name, [string]$value) {
    $existing = Get-WebConfiguration -pspath 'MACHINE/WEBROOT/APPHOST' -filter "$envFilter/add[@name='$name']" -ErrorAction SilentlyContinue
    if ($existing) { Set-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST' -filter "$envFilter/add[@name='$name']" -name 'value' -value $value }
    else { Add-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST' -filter $envFilter -name '.' -value @{name=$name; value=$value} }
}
function Remove-PoolEnv([string]$name) {
    $existing = Get-WebConfiguration -pspath 'MACHINE/WEBROOT/APPHOST' -filter "$envFilter/add[@name='$name']" -ErrorAction SilentlyContinue
    if ($existing) {
        Remove-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST' -filter $envFilter -name '.' -AtElement @{name=$name}
    }
}
Set-PoolEnv 'ASPNETCORE_ENVIRONMENT' 'Production'
Write-Ok "ASPNETCORE_ENVIRONMENT=Production"

if ($ConnectionString) {
    if ($ConnectionString -match '<password>|<your-password>') { throw "The -ConnectionString still contains a placeholder. Substitute the real password." }
    if ($ConnectionString -match '(?i)server\s*=\s*(localhost|\.|\(local\))\s*;') {
        Write-Warn "Server=localhost routes over Shared Memory, which has failed on this instance."
        Write-Warn "Prefer the IP (Server=192.168.1.117) unless you know Shared Memory works."
    }
    Set-PoolEnv 'ConnectionStrings__umbracoDbDSN' $ConnectionString
    Set-PoolEnv 'ConnectionStrings__umbracoDbDSN_ProviderName' 'Microsoft.Data.SqlClient'
    Write-Ok "ConnectionStrings__umbracoDbDSN set (value not echoed)."
} else {
    Write-Warn "No -ConnectionString supplied. If none is already stored, Umbraco will not start."
}
if ($ApplicationUrl) { Set-PoolEnv 'Umbraco__CMS__WebRouting__UmbracoApplicationUrl' $ApplicationUrl; Write-Ok "Application URL = $ApplicationUrl" }
else { Write-Warn "No -ApplicationUrl; password-reset/invite emails will have broken links." }
if ($HmacSecretKey) { Set-PoolEnv 'Umbraco__CMS__Imaging__HMACSecretKey' $HmacSecretKey; Write-Ok "Imaging HMAC key set." }

$names = @(Get-WebConfiguration -pspath 'MACHINE/WEBROOT/APPHOST' -filter "$envFilter/add" | ForEach-Object { $_.name })
if ($names) { Write-Ok ("Env vars now on pool: " + ($names -join ', ')) }

# ---- Site + bindings ------------------------------------------------------
Write-Step "Configuring site '$SiteName'"
if (-not (Get-Website -Name $SiteName -ErrorAction SilentlyContinue)) {
    New-Website -Name $SiteName -PhysicalPath $SitePath -ApplicationPool $AppPoolName -Port $ManagementPort | Out-Null
    Write-Ok "Created site."
} else {
    Set-ItemProperty "IIS:\Sites\$SiteName" -Name physicalPath    -Value $SitePath
    Set-ItemProperty "IIS:\Sites\$SiteName" -Name applicationPool -Value $AppPoolName
    Write-Ok "Site exists - updated path and pool."
}

foreach ($b in $plan) {
    $have = (Get-Website -Name $SiteName).Bindings.Collection |
            Where-Object { $_.protocol -eq 'http' -and $_.bindingInformation -eq $b.Info }
    if ($have) { Write-Ok "binding $($b.Info) already present" }
    else {
        if ($b.HostName) { New-WebBinding -Name $SiteName -Protocol http -Port $b.Port -HostHeader $b.HostName }
        else             { New-WebBinding -Name $SiteName -Protocol http -Port $b.Port }
        Write-Ok "added binding $($b.Info)"
    }
}

# ---- Filesystem rights ----------------------------------------------------
Write-Step "Granting filesystem rights to 'IIS AppPool\$AppPoolName'"
$identity = "IIS AppPool\$AppPoolName"
foreach ($sub in 'umbraco\Data','umbraco\Logs','wwwroot\media','logs') {
    $full = Join-Path $SitePath $sub
    if (-not (Test-Path $full)) { New-Item -ItemType Directory -Path $full -Force | Out-Null }
}
& icacls "$SitePath" /grant "${identity}:(OI)(CI)(RX)" /T /C /Q | Out-Null
foreach ($sub in 'umbraco','wwwroot\media','logs') {
    & icacls (Join-Path $SitePath $sub) /grant "${identity}:(OI)(CI)(M)" /T /C /Q | Out-Null
}
Write-Ok "Read+execute on the app; modify on umbraco\, wwwroot\media\, logs\."

# ---- Start ----------------------------------------------------------------
Write-Step "Starting"
if ((Get-WebAppPoolState -Name $AppPoolName).Value -ne 'Started') {
    Start-WebAppPool -Name $AppPoolName
    Write-Ok "App pool started."
} else {
    # Environment variables are read by the worker process at startup, so an
    # already-running pool would keep serving with the OLD values. Recycle so
    # connection string / application URL changes actually take effect.
    Restart-WebAppPool -Name $AppPoolName
    Write-Ok "App pool recycled (so env var changes take effect)."
}
if ((Get-Website -Name $SiteName).State -ne 'Started') { Start-Website -Name $SiteName }
Write-Ok "Site started."

# ---- uSync schema import --------------------------------------------------
if ($ImportUSync) {
    Write-Step "Importing uSync '$USyncGroup' handlers into this server's database"
    if (-not (Test-Path (Join-Path $SitePath 'uSync'))) { throw "No uSync folder in $SitePath - deploy first." }

    $logDir = Join-Path $SitePath 'umbraco\Logs'
    $before = if (Test-Path $logDir) { (Get-ChildItem $logDir -Filter *.json -File | Measure-Object -Property Length -Sum).Sum } else { 0 }

    # The Templates handler saves each imported template's physical .cshtml into
    # Views\, where the pool identity deliberately has read-only access - without
    # a temporary grant any NEW template in the import dies with
    # UnauthorizedAccessException (first hit deploying this site's features page,
    # 2026-07-19). Granted here, revoked after the import.
    $viewsPath = Join-Path $SitePath 'Views'
    & icacls $viewsPath /grant "${identity}:(OI)(CI)(M)" /Q | Out-Null
    Write-Ok "Temporary write access on Views\ granted to $identity."

    # ExportAtStartup MUST be off for this boot: an export running first writes the
    # database's current state over the .config files and destroys what we intend
    # to import.
    Set-PoolEnv 'uSync__Settings__ImportAtStartup' $USyncGroup
    Set-PoolEnv 'uSync__Settings__ExportAtStartup' 'None'
    Restart-WebAppPool -Name $AppPoolName
    Write-Ok "Pool recycled with ImportAtStartup=$USyncGroup"

    # The import runs during boot, and boot only happens on the first request.
    Write-Ok "Warming up the app so the import actually runs..."
    $warm = "http://localhost:$ManagementPort/"
    for ($i = 0; $i -lt 4; $i++) {
        try { Invoke-WebRequest -Uri $warm -UseBasicParsing -TimeoutSec 120 -MaximumRedirection 0 -ErrorAction Stop | Out-Null; break }
        catch { Start-Sleep -Seconds 3 }   # redirects/500s are fine - we only need it to boot
    }
    Start-Sleep -Seconds 5

    # Report what uSync actually did rather than assuming it worked.
    $line = $null
    if (Test-Path $logDir) {
        $lf = Get-ChildItem $logDir -Filter *.json -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($lf) {
            $entry = Get-Content $lf.FullName | ForEach-Object { try { $_ | ConvertFrom-Json } catch {} } |
                     Where-Object { $_.'@mt' -like '*uSync Import*' } | Select-Object -Last 1
            if ($entry) {
                # Serilog stores the message TEMPLATE in @mt with the values as
                # separate properties, so print the template raw and you get
                # literal "{handlerCount}" placeholders. Substitute them back in.
                $line = $entry.'@mt'
                foreach ($prop in $entry.PSObject.Properties) {
                    if ($prop.Name -notlike '@*') {
                        $line = $line -replace ('\{' + [regex]::Escape($prop.Name) + '\}'), [string]$prop.Value
                    }
                }
            }
        }
    }
    if ($line) { Write-Ok "uSync: $line" } else { Write-Warn "No 'uSync Import' line found in the log - check $logDir" }

    # Leave the flag set and EVERY future recycle would re-import, silently
    # reverting backoffice edits. Remove it and recycle back to normal.
    Remove-PoolEnv 'uSync__Settings__ImportAtStartup'
    Remove-PoolEnv 'uSync__Settings__ExportAtStartup'
    Restart-WebAppPool -Name $AppPoolName
    Write-Ok "Import flags removed; pool recycled back to normal operation."

    & icacls $viewsPath /remove:g $identity /Q | Out-Null
    Write-Ok "Views\ write access revoked (inherited read-only remains)."
}

# ---- HTTPS via win-acme ---------------------------------------------------
if ($EnableHttps) {
    Write-Step "HTTPS (Let's Encrypt via win-acme)"
    if (-not $HostNames)   { throw "-EnableHttps needs -HostNames (the cert is issued for those names)." }
    if (-not $ContactEmail){ throw "-EnableHttps needs -ContactEmail (Let's Encrypt expiry notices)." }

    $wacs = $WacsPath
    if (-not $wacs) {
        $wacs = @(
            "$env:ProgramFiles\win-acme\wacs.exe",
            "${env:ProgramFiles(x86)}\win-acme\wacs.exe",
            "C:\win-acme\wacs.exe",
            "C:\tools\win-acme\wacs.exe"
        ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    }

    if (-not $wacs) {
        Write-Warn "win-acme (wacs.exe) not found. Download it, unzip to C:\win-acme, then re-run"
        Write-Warn "this script with -EnableHttps (or pass -WacsPath)."
        Write-Warn "  https://github.com/win-acme/win-acme/releases   (pluggable, x64, .zip)"
        Write-Warn ""
        Write-Warn "Equivalent manual command once installed:"
        Write-Warn "  C:\win-acme\wacs.exe --accepttos --emailaddress $ContactEmail ``"
        Write-Warn "     --source manual --host $($HostNames -join ',') ``"
        Write-Warn "     --installation iis --installationsiteid $((Get-Website -Name $SiteName).Id) --closeonfinish"
    } else {
        $siteId = (Get-Website -Name $SiteName).Id
        Write-Ok "Using $wacs (site id $siteId)"
        Write-Ok "Requesting a certificate for: $($HostNames -join ', ')"
        Write-Warn "Let's Encrypt must reach http://<host>/.well-known/acme-challenge/ on port 80."
        & $wacs --accepttos --emailaddress $ContactEmail `
                --source manual --host ($HostNames -join ',') `
                --installation iis --installationsiteid $siteId --closeonfinish
        $wacsExit = $LASTEXITCODE

        # Verify the OUTCOME, not just the exit code: -EnableHttps must not report
        # success unless an https binding actually exists.
        $https = @((Get-Website -Name $SiteName).Bindings.Collection | Where-Object { $_.protocol -eq 'https' })
        if (-not $https) {
            throw @"
HTTPS was requested but no https binding exists after win-acme (exit code $wacsExit).
The certificate was NOT issued. Diagnose by running win-acme interactively:
    $wacs
Most common cause on ASP.NET Core / Umbraco: the http-01 challenge is a file with
NO extension under /.well-known/acme-challenge/, which the static-file middleware
will not serve, so Let's Encrypt gets a 404. In the interactive menu choose a
validation method that writes its own web.config for that folder, or use DNS validation.
win-acme logs: look in '$(Split-Path $wacs)\Log' as well as C:\ProgramData\win-acme.
"@
        }
        Write-Ok "Certificate issued and bound. win-acme registered a renewal scheduled task."
        foreach ($h in $https) { Write-Ok "https binding: $($h.bindingInformation)" }
    }
}

# ---- Summary --------------------------------------------------------------
Write-Step "Result"
foreach ($b in (Get-Website -Name $SiteName).Bindings.Collection) {
    Write-Ok "$($b.protocol)  $($b.bindingInformation)"
}
if ($HostNames) { Write-Host "`nPublic: http://$($HostNames[0])/    Backoffice: http://$($HostNames[0])/umbraco" -ForegroundColor Green }
Write-Host "LAN:    http://$($env:COMPUTERNAME):$ManagementPort/" -ForegroundColor Green
