<#
.SYNOPSIS
  Adds the two "On Hold" columns to the existing NS_Renewal_Decisions list
  used by the Renewal Manager app, on the NewShire (vanrockre) SharePoint site.

    OnHold      Yes/No   (default No)  - is this approved offer parked?
    HoldReason  Text                   - optional note on why it's held

.DESCRIPTION
  Hand-rolled OAuth2 device-code flow against the Microsoft identity platform,
  then raw Invoke-RestMethod calls against Microsoft Graph. Same approach as
  employee-lifecycle\scripts\provision-lists.ps1.

  Idempotent: re-running is safe; columns that already exist are left alone.

.NOTES
  Required Graph scopes: Sites.Manage.All, Sites.ReadWrite.All
  Sign in as bturner@newshirepm.com. Tested on PowerShell 7.x.
#>
[CmdletBinding()]
param(
    [string]$SiteId   = "vanrockre.sharepoint.com,a02c1cd8-9f1f-4827-8286-7b6b7ce74232,01202419-6625-4499-b0d5-8ceb1cffdba3",
    [string]$TenantId = "33575d04-ca7b-4396-8011-9eaea4030b46",
    # Public "Microsoft Graph Command Line Tools" client id (device-flow enabled, no app registration needed)
    [string]$ClientId = "14d82eec-204b-4c2f-b7e8-296a70dab67e",
    [string]$ListName = "NS_Renewal_Decisions"
)

$ErrorActionPreference = 'Stop'
$InformationPreference  = 'Continue'

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-OK   ($msg) { Write-Host "    [OK]    $msg" -ForegroundColor Green }
function Write-Skip ($msg) { Write-Host "    [SKIP]  $msg" -ForegroundColor DarkYellow }
function Write-New  ($msg) { Write-Host "    [CREATE]$msg" -ForegroundColor Yellow }
function Write-Warn ($msg) { Write-Host "    [WARN]  $msg" -ForegroundColor Magenta }

# ─────────────────────────────────────────────────────────────
# DEVICE CODE AUTH  (hand-rolled, 15-minute polling window)
# ─────────────────────────────────────────────────────────────
Write-Step "Requesting device code"
$scope = "https://graph.microsoft.com/Sites.Manage.All https://graph.microsoft.com/Sites.ReadWrite.All offline_access"
$dcResp = Invoke-RestMethod -Method POST `
    -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/devicecode" `
    -Body @{ client_id = $ClientId; scope = $scope } `
    -ContentType 'application/x-www-form-urlencoded'

Write-Host ""
Write-Host "  ╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Yellow
Write-Host "  ║  ACTION REQUIRED — sign in to authorise column creation      ║" -ForegroundColor Yellow
Write-Host "  ║                                                              ║" -ForegroundColor Yellow
Write-Host "  ║  1. Open:   https://login.microsoft.com/device               ║" -ForegroundColor Yellow
Write-Host "  ║  2. Enter:  $($dcResp.user_code.PadRight(50))║" -ForegroundColor Yellow
Write-Host "  ║  3. Sign in as bturner@newshirepm.com                        ║" -ForegroundColor Yellow
Write-Host "  ╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Yellow
Write-Host ""
Write-Host "Polling for token (device code expires in $([int]($dcResp.expires_in/60)) minutes)..." -ForegroundColor DarkGray

$token = $null
$expiresAt = (Get-Date).AddSeconds([int]$dcResp.expires_in - 5)
$pollInterval = [int]$dcResp.interval
if ($pollInterval -lt 5) { $pollInterval = 5 }

while ((Get-Date) -lt $expiresAt) {
    Start-Sleep -Seconds $pollInterval
    try {
        $tokenResp = Invoke-RestMethod -Method POST `
            -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
            -Body @{
                grant_type  = 'urn:ietf:params:oauth:grant-type:device_code'
                client_id   = $ClientId
                device_code = $dcResp.device_code
            } `
            -ContentType 'application/x-www-form-urlencoded' `
            -ErrorAction Stop
        $token = $tokenResp.access_token
        break
    } catch {
        $err = $null
        try { $err = ($_.ErrorDetails.Message | ConvertFrom-Json) } catch { }
        if ($err -and $err.error -eq 'authorization_pending') { Write-Host "." -NoNewline -ForegroundColor DarkGray; continue }
        if ($err -and $err.error -eq 'slow_down')             { $pollInterval += 5; continue }
        if ($err -and $err.error -eq 'expired_token')         { Write-Host ""; Write-Error "Device code expired before sign-in completed. Re-run the script."; exit 1 }
        if ($err -and $err.error -eq 'authorization_declined'){ Write-Host ""; Write-Error "Authorization declined by user."; exit 1 }
        Write-Host ""
        Write-Error "Token poll failed: $($err.error_description ?? $_.Exception.Message)"
        exit 1
    }
}
Write-Host ""
if (-not $token) { Write-Error "Authentication did not complete within the device-code lifetime."; exit 1 }
Write-OK "Authenticated"

$headers = @{ Authorization = "Bearer $token" }

# ─────────────────────────────────────────────────────────────
# GRAPH HELPER
# ─────────────────────────────────────────────────────────────
function Invoke-Graph {
    param(
        [Parameter(Mandatory)][ValidateSet('GET','POST','PATCH','DELETE')][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [object]$Body
    )
    $uri = "https://graph.microsoft.com/v1.0$Path"
    if ($Body) {
        $json = $Body | ConvertTo-Json -Depth 20 -Compress
        return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers -Body $json -ContentType 'application/json'
    }
    return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers
}

# Column definitions (Graph column resource shape)
$columns = @(
    @{ name = 'OnHold';     boolean = @{ }; defaultValue = @{ value = 'false' } }
    @{ name = 'HoldReason'; text    = @{ } }
)

# ─────────────────────────────────────────────────────────────
# LOCATE THE LIST
# ─────────────────────────────────────────────────────────────
Write-Step "Locating list '$ListName'"
$listsResp = Invoke-Graph -Method GET -Path "/sites/$SiteId/lists?`$select=id,displayName,name"
$list = $listsResp.value | Where-Object { $_.displayName -eq $ListName -or $_.name -eq $ListName } | Select-Object -First 1
if (-not $list) {
    Write-Error "List '$ListName' not found on the site. Existing lists: $($listsResp.value.displayName -join ', ')"
    exit 1
}
Write-OK "Found '$ListName'  (id=$($list.id))"

# ─────────────────────────────────────────────────────────────
# ADD MISSING COLUMNS (idempotent)
# ─────────────────────────────────────────────────────────────
Write-Step "Reconciling columns"
$colResp = Invoke-Graph -Method GET -Path "/sites/$SiteId/lists/$($list.id)/columns?`$select=name,displayName"
$have = @{}
foreach ($c in $colResp.value) {
    $have[$c.name.ToLower()] = $true
    if ($c.displayName) { $have[$c.displayName.ToLower()] = $true }
}

foreach ($col in $columns) {
    if ($have[$col.name.ToLower()]) {
        Write-Skip "$($col.name) already exists"
        continue
    }
    Write-New "  + column $($col.name)"
    try {
        Invoke-Graph -Method POST -Path "/sites/$SiteId/lists/$($list.id)/columns" -Body $col | Out-Null
        Write-OK "Created $($col.name)"
    } catch {
        Write-Warn "Create failed for $($col.name): $($_.Exception.Message)"
        throw
    }
}

Write-Host ""
Write-OK "Done. The On Hold / Release buttons in Pending Send will now work."
