<#
.SYNOPSIS
    Carries the old app's per-entity Notes across into NS_Renewal_Config.

.DESCRIPTION
    The previous Renewal Manager kept a free-text `Notes` field on each row of
    NS_Renewal_Settings (keyed by EntityKey, one row per multi-family property
    or per single-family owner) and showed it as a banner above the review
    table. The rewrite has standing notes again -- per property AND per owner --
    but they live on NS_Renewal_Config.StandingNotes.

    This copies them over. It:
      - reads every NS_Renewal_Settings row that actually has a Notes value
      - decides whether that row describes a PROPERTY (multi-family) or an
        OWNER (single-family), from its PortfolioType
      - writes StandingNotes onto the matching NS_Renewal_Config row, creating
        the row if it doesn't exist yet

    Nothing is deleted and NS_Renewal_Settings is not modified. Re-running is
    safe: an existing StandingNotes value is left alone unless -Overwrite.

.PARAMETER Overwrite
    Replace StandingNotes even where the target row already has some. Off by
    default so a second run can't clobber notes edited in the new app.

.PARAMETER WhatIf
    Show what would be written; change nothing.

.EXAMPLE
    pwsh -File .\scripts\migrate-notes.ps1 -WhatIf
    pwsh -File .\scripts\migrate-notes.ps1
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$SiteUrl  = "https://newshirepmcom.sharepoint.com/sites/NewShirePM",
    [string]$ClientId = "7f310acf-12b1-4ba9-a113-c027614268b9",
    [string]$SourceList = "NS_Renewal_Settings",
    [string]$TargetList = "NS_Renewal_Config",
    [switch]$Overwrite
)

$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host ""
    Write-Host "  This needs PowerShell 7 - you're on $($PSVersionTable.PSVersion)." -ForegroundColor Yellow
    Write-Host "  Re-run it like this:" -ForegroundColor Cyan
    Write-Host "      pwsh -File .\scripts\migrate-notes.ps1" -ForegroundColor White
    Write-Host ""
    exit 1
}
Import-Module PnP.PowerShell

Write-Host "Connecting to $SiteUrl ..." -ForegroundColor Cyan
Connect-PnPOnline -Url $SiteUrl -Interactive -ClientId $ClientId

# --- read the old settings ---------------------------------------------------
$src = $null
try {
    $src = Get-PnPListItem -List $SourceList -PageSize 500
} catch {
    Write-Host ""
    Write-Host "  Couldn't read '$SourceList'. If you've already deleted it, there's" -ForegroundColor Yellow
    Write-Host "  nothing to migrate and you can skip this script." -ForegroundColor Yellow
    Write-Host "  ($($_.Exception.Message))" -ForegroundColor DarkGray
    exit 1
}

Write-Host "Read $($src.Count) row(s) from $SourceList." -ForegroundColor DarkGray

# --- index the target --------------------------------------------------------
$dst = Get-PnPListItem -List $TargetList -PageSize 500
$byTitle = @{}
foreach ($i in $dst) {
    $t = [string]$i.FieldValues['Title']
    if ($t) { $byTitle[$t] = $i }
}

$created = 0; $updated = 0; $skipped = 0; $empty = 0

foreach ($row in $src) {
    $f     = $row.FieldValues
    $notes = [string]$f['Notes']
    if ([string]::IsNullOrWhiteSpace($notes)) { $empty++; continue }

    # EntityName is the display name the old app showed; OwnerName is what the
    # feed keys owners by. Prefer the one that matches how the new app groups.
    $portfolio = [string]$f['PortfolioType']
    $isMF      = $portfolio -and $portfolio.ToLower().Contains('multi')
    $scope     = if ($isMF) { 'Property' } else { 'Owner' }

    # Multi-family rows describe ONE property; single-family rows describe an
    # owner whose units are spread across many addresses.
    $key = if ($isMF) {
        [string]$f['OwnerName']   # the old app stored the property name here for MF
    } else {
        [string]$f['OwnerName']
    }
    if ([string]::IsNullOrWhiteSpace($key)) { $key = [string]$f['EntityName'] }
    if ([string]::IsNullOrWhiteSpace($key)) { $key = [string]$f['Title'] }
    if ([string]::IsNullOrWhiteSpace($key)) {
        Write-Warning "Row $($row.Id) has notes but no name to attach them to - skipped."
        $skipped++
        continue
    }

    $existing = $byTitle[$key]

    if ($existing) {
        $have = [string]$existing.FieldValues['StandingNotes']
        if (-not [string]::IsNullOrWhiteSpace($have) -and -not $Overwrite) {
            Write-Host "  = $key already has notes - left alone (use -Overwrite to replace)" -ForegroundColor DarkGray
            $skipped++
            continue
        }
        if ($PSCmdlet.ShouldProcess("$TargetList/$key", 'Update StandingNotes')) {
            Set-PnPListItem -List $TargetList -Identity $existing.Id `
                -Values @{ StandingNotes = $notes; Scope = $scope } | Out-Null
            Write-Host "  ~ $key  ($scope)" -ForegroundColor Yellow
            $updated++
        }
    } else {
        if ($PSCmdlet.ShouldProcess("$TargetList/$key", 'Create row with StandingNotes')) {
            Add-PnPListItem -List $TargetList -Values @{
                Title = $key; StandingNotes = $notes; Scope = $scope
            } | Out-Null
            Write-Host "  + $key  ($scope)" -ForegroundColor Green
            $created++
        }
    }
}

Write-Host ""
Write-Host "Done. Created: $created | Updated: $updated | Skipped: $skipped | No notes: $empty" -ForegroundColor Cyan
Write-Host "Open the app - notes now show on the owner card and on each property." -ForegroundColor Yellow
