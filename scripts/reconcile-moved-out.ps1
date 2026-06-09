<#
.SYNOPSIS
  Removes "fossil" rows from NS_Units_Cache — units whose resident has moved out
  but whose row is frozen on "Current" because the Power Automate sync only pulls
  ACTIVE leases and never deletes rows that drop out of the source report.

.DESCRIPTION
  The sync stamps every row it touches with "Last Synced" on each run. A unit that
  is no longer in the source (resident moved out) keeps its OLD Last Synced date.
  So: any row whose Last Synced is older than the most recent run = departed.

  Default is a DRY RUN — it only reports what it would do. Re-run with -Apply to
  actually act, and add -MarkVacant if you'd rather flag them Vacant (which the app
  now hides) instead of deleting them outright.

  Hand-rolled device-code OAuth + Microsoft Graph, same pattern as the other
  NewShire provisioning scripts. Idempotent and safe to re-run.

.PARAMETER Apply
  Actually delete (or, with -MarkVacant, flag) the stale rows. Without it, dry run.

.PARAMETER MarkVacant
  Instead of deleting, set Lease Status = "Vacant" on stale rows (non-destructive;
  the app's isInactiveStatus() filter then hides them).

.PARAMETER GraceDays
  Treat a row as stale only if its Last Synced is older than (latest run date minus
  this many days). Default 0 = anything not in the most recent run. Bump to 1-2 if
  you want a safety buffer against a partial sync run.

.NOTES
  Required Graph scopes: Sites.ReadWrite.All. Sign in as bturner@newshirepm.com.
  Tested on PowerShell 7.x.  ALWAYS run the dry run first and eyeball the list.
#>
[CmdletBinding()]
param(
    [string]$SiteId   = "vanrockre.sharepoint.com,a02c1cd8-9f1f-4827-8286-7b6b7ce74232,01202419-6625-4499-b0d5-8ceb1cffdba3",
    [string]$TenantId = "33575d04-ca7b-4396-8011-9eaea4030b46",
    [string]$ClientId = "14d82eec-204b-4c2f-b7e8-296a70dab67e",   # public Graph CLI client (device-flow)
    [string]$ListName = "NS_Units_Cache",
    [switch]$Apply,
    [switch]$MarkVacant,
    [int]$GraceDays = 0
)

$ErrorActionPreference = 'Stop'
$InformationPreference  = 'Continue'

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-OK   ($msg) { Write-Host "    [OK]    $msg" -ForegroundColor Green }
function Write-Skip ($msg) { Write-Host "    [SKIP]  $msg" -ForegroundColor DarkYellow }
function Write-Warn ($msg) { Write-Host "    [WARN]  $msg" -ForegroundColor Magenta }

# ─────────────────────────────────────────────────────────────
# DEVICE CODE AUTH
# ─────────────────────────────────────────────────────────────
Write-Step "Requesting device code"
$scope = "https://graph.microsoft.com/Sites.ReadWrite.All offline_access"
$dcResp = Invoke-RestMethod -Method POST `
    -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/devicecode" `
    -Body @{ client_id = $ClientId; scope = $scope } `
    -ContentType 'application/x-www-form-urlencoded'

Write-Host ""
Write-Host "  ACTION REQUIRED — open https://login.microsoft.com/device" -ForegroundColor Yellow
Write-Host "  Enter code:  $($dcResp.user_code)" -ForegroundColor Yellow
Write-Host "  Sign in as bturner@newshirepm.com" -ForegroundColor Yellow
Write-Host ""
Write-Host "Polling for token..." -ForegroundColor DarkGray

$token = $null
$expiresAt = (Get-Date).AddSeconds([int]$dcResp.expires_in - 5)
$pollInterval = [Math]::Max([int]$dcResp.interval, 5)
while ((Get-Date) -lt $expiresAt) {
    Start-Sleep -Seconds $pollInterval
    try {
        $tokenResp = Invoke-RestMethod -Method POST `
            -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
            -Body @{ grant_type='urn:ietf:params:oauth:grant-type:device_code'; client_id=$ClientId; device_code=$dcResp.device_code } `
            -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop
        $token = $tokenResp.access_token; break
    } catch {
        $e=$null; try { $e=($_.ErrorDetails.Message | ConvertFrom-Json) } catch {}
        if ($e -and $e.error -eq 'authorization_pending') { Write-Host "." -NoNewline -ForegroundColor DarkGray; continue }
        if ($e -and $e.error -eq 'slow_down') { $pollInterval += 5; continue }
        if ($e -and $e.error -eq 'expired_token') { Write-Host ""; Write-Error "Device code expired. Re-run."; exit 1 }
        Write-Host ""; Write-Error "Token poll failed: $($e.error_description ?? $_.Exception.Message)"; exit 1
    }
}
Write-Host ""
if (-not $token) { Write-Error "Auth did not complete in time."; exit 1 }
Write-OK "Authenticated"
$headers = @{ Authorization = "Bearer $token" }

function Invoke-Graph {
    param([ValidateSet('GET','POST','PATCH','DELETE')][string]$Method,[string]$Path,[object]$Body)
    $uri = "https://graph.microsoft.com/v1.0$Path"
    if ($Body) { return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers -Body ($Body|ConvertTo-Json -Depth 20 -Compress) -ContentType 'application/json' }
    return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers
}

# ─────────────────────────────────────────────────────────────
# LOCATE LIST + MAP COLUMN INTERNAL NAMES
# ─────────────────────────────────────────────────────────────
Write-Step "Locating list '$ListName'"
$listsResp = Invoke-Graph GET "/sites/$SiteId/lists?`$select=id,displayName,name"
$list = $listsResp.value | Where-Object { $_.displayName -eq $ListName -or $_.name -eq $ListName } | Select-Object -First 1
if (-not $list) { Write-Error "List '$ListName' not found."; exit 1 }
Write-OK "Found '$ListName'  (id=$($list.id))"

$cols = (Invoke-Graph GET "/sites/$SiteId/lists/$($list.id)/columns?`$select=name,displayName").value
function ColName([string[]]$displayCandidates,[string]$nameLike) {
    foreach ($c in $cols) { if ($displayCandidates -contains $c.displayName) { return $c.name } }
    foreach ($c in $cols) { if ($c.name -like "*$nameLike*") { return $c.name } }
    return $null
}
$F_sync   = ColName @('Last Synced','LastSynced') 'Sync'
$F_status = ColName @('Lease Status','LeaseStatus') 'Status'
$F_unit   = ColName @('Unit Number','UnitNumber') 'UnitNumber'
$F_prop   = ColName @('Property Name','PropertyName') 'PropertyName'
$F_res    = ColName @('Resident Name','ResidentName') 'Resident'
if (-not $F_sync) { Write-Error "Could not find a 'Last Synced' column on the list — cannot reconcile by sync date."; exit 1 }
Write-OK "Sync column = '$F_sync'; Status column = '$F_status'"

# ─────────────────────────────────────────────────────────────
# READ ALL ITEMS
# ─────────────────────────────────────────────────────────────
Write-Step "Reading items"
$items = @()
$url = "/sites/$SiteId/lists/$($list.id)/items?`$expand=fields&`$top=999"
while ($url) {
    $resp = Invoke-Graph GET $url
    $items += $resp.value
    $next = $resp.'@odata.nextLink'
    $url = if ($next) { $next -replace 'https://graph.microsoft.com/v1.0','' } else { $null }
}
Write-OK "Read $($items.Count) rows"

function ParseDate($v) {
    if (-not $v) { return $null }
    try { return [datetime]$v } catch {
        try { return [datetime]::Parse($v,[Globalization.CultureInfo]::InvariantCulture) } catch { return $null }
    }
}

# Latest run = newest Last Synced date present
$dates = $items | ForEach-Object { ParseDate $_.fields.$F_sync } | Where-Object { $_ } | ForEach-Object { $_.Date }
if (-not $dates) { Write-Error "No parseable Last Synced values — aborting."; exit 1 }
$latest = ($dates | Measure-Object -Maximum).Maximum
$cutoff = $latest.AddDays(-$GraceDays)
Write-OK ("Latest sync run = {0:yyyy-MM-dd}; flagging rows last synced before {1:yyyy-MM-dd}" -f $latest, $cutoff)

# Stale = synced before cutoff, or never synced (blank)
$stale = $items | Where-Object {
    $d = ParseDate $_.fields.$F_sync
    (-not $d) -or ($d.Date -lt $cutoff)
}

Write-Host ""
Write-Step "$($stale.Count) stale row(s) (resident moved out, sync stopped touching them):"
$stale |
    Sort-Object { $_.fields.$F_prop }, { $_.fields.$F_unit } |
    ForEach-Object {
        $d = ParseDate $_.fields.$F_sync
        "{0,-28} {1,-8} {2,-26} last synced {3}" -f `
            ($_.fields.$F_prop), ($_.fields.$F_unit), ($_.fields.$F_res), $(if($d){$d.ToString('yyyy-MM-dd')}else{'(never)'})
    } | Write-Host

if (-not $Apply) {
    Write-Host ""
    Write-Warn "DRY RUN — nothing changed. Re-run with -Apply to remove them"
    Write-Warn "  (or  -Apply -MarkVacant  to flag them Vacant instead of deleting)."
    exit 0
}

# ─────────────────────────────────────────────────────────────
# APPLY
# ─────────────────────────────────────────────────────────────
Write-Host ""
$action = if ($MarkVacant) { "Marking Vacant" } else { "Deleting" }
Write-Step "$action $($stale.Count) row(s)"
$done = 0; $fail = 0
foreach ($it in $stale) {
    try {
        if ($MarkVacant) {
            if (-not $F_status) { throw "No Lease Status column found to mark Vacant" }
            Invoke-Graph PATCH "/sites/$SiteId/lists/$($list.id)/items/$($it.id)/fields" @{ $F_status = 'Vacant' } | Out-Null
        } else {
            Invoke-Graph DELETE "/sites/$SiteId/lists/$($list.id)/items/$($it.id)" | Out-Null
        }
        $done++
    } catch { $fail++; Write-Warn "Row $($it.id) ($($it.fields.$F_unit)): $($_.Exception.Message)" }
}
Write-OK "$action complete: $done succeeded, $fail failed"
Write-Host ""
Write-Warn "This corrects the cache once. To stop fossils recurring, fix the Power Automate"
Write-Warn "flow to reconcile (delete rows not seen this run) — or schedule this script after it."
