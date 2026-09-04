<#
.SYNOPSIS
    Provisions the three SharePoint lists the rewritten Renewal Manager runs on.

.DESCRIPTION
    Creates (idempotently -- safe to re-run) on /sites/NewShirePM:

      NS_Renewal_Units     Nightly feed target. Written ONLY by the cloud ETL
                           (newshire-appfolio-dashboard/cloud/renewals_feed.py),
                           which reconciles it against AppFolio every night --
                           creating, patching AND DELETING. Never hand-edit it:
                           your edit survives until the next 4 AM run, then
                           vanishes without a trace.

      NS_Renewal_Pipeline  The human side. One ACTIVE row per unit tracking the
                           rate through owner negotiation and approval. Written
                           only by the app.

      NS_Renewal_Config    Per-property renewal policy (target increase, offer
                           window, owner-response SLA). One row per property,
                           plus a '__default__' row that fills any gap.

    WHY DATES ARE TEXT COLUMNS, NOT DateTime
    A SharePoint DateTime column stores an instant and renders it in the
    viewer's timezone. A lease that expires 2026-07-31 therefore reads as
    2026-07-30 for anyone whose regional setting lands west of the site's, which
    on a renewal deadline is the difference between "due today" and "overdue".
    Every business date here is a plain 'YYYY-MM-DD' string -- compared, sorted
    and displayed as text, identical for every viewer. Only the audit timestamps
    (SyncedAt, ModifiedOn) are real DateTime.

.PARAMETER SiteUrl
    Target site. Defaults to the live NewShirePM site.

.PARAMETER ClientId
    Entra app registration for interactive PnP. Defaults to the tenant-wide
    "NewShire Migration Tool" app, which is the one that actually works
    post-carve-out. The old 32e75ffa / 63567714 apps lived in Vanrock's tenant
    and now fail with AADSTS700016.

.PARAMETER WhatIf
    Report what would be created or changed; write nothing.

.EXAMPLE
    .\provision-renewal-lists.ps1
    .\provision-renewal-lists.ps1 -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$SiteUrl  = "https://newshirepmcom.sharepoint.com/sites/NewShirePM",
    [string]$ClientId = "7f310acf-12b1-4ba9-a113-c027614268b9"
)

$ErrorActionPreference = 'Stop'

# PnP.PowerShell 3.x dropped Windows PowerShell 5.1 -- it is PowerShell 7 only.
# Run under 5.1 and the only symptom is "Connect-PnPOnline is not recognized",
# which reads like a missing install rather than the wrong shell.
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host ""
    Write-Host "  This needs PowerShell 7 - you're on $($PSVersionTable.PSVersion)." -ForegroundColor Yellow
    Write-Host "  PnP.PowerShell 3.x doesn't run on Windows PowerShell 5.1." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Re-run it like this:" -ForegroundColor Cyan
    Write-Host "      pwsh -File .\scripts\provision-renewal-lists.ps1" -ForegroundColor White
    Write-Host ""
    exit 1
}

if (-not (Get-Module -ListAvailable PnP.PowerShell)) {
    Write-Host ""
    Write-Host "  PnP.PowerShell isn't installed for this PowerShell. Install it with:" -ForegroundColor Yellow
    Write-Host "      Install-Module PnP.PowerShell -Scope CurrentUser" -ForegroundColor White
    Write-Host ""
    exit 1
}
Import-Module PnP.PowerShell

# ---------------------------------------------------------------------------
# Schema definition
# ---------------------------------------------------------------------------
# Text is used for every business DATE on purpose -- see the .DESCRIPTION note.

$UnitsFields = @(
    @{ Name = 'UnitID';           Type = 'Text';     Indexed = $true;  Required = $true }
    @{ Name = 'PropertyID';       Type = 'Text' }
    @{ Name = 'PropertyName';     Type = 'Text';     Indexed = $true }
    @{ Name = 'UnitLabel';        Type = 'Text' }
    @{ Name = 'UnitAddress';      Type = 'Text' }
    @{ Name = 'PortfolioType';    Type = 'Text' }
    @{ Name = 'ManagerName';      Type = 'Text';     Indexed = $true }

    @{ Name = 'OwnerName';        Type = 'Text';     Indexed = $true }
    @{ Name = 'OwnerEmail';       Type = 'Note' }   # AppFolio returns several, comma-joined
    @{ Name = 'OwnerPhone';       Type = 'Text' }

    @{ Name = 'ResidentName';     Type = 'Text' }
    @{ Name = 'ResidentPhone';    Type = 'Text' }
    @{ Name = 'TenantID';         Type = 'Text' }

    @{ Name = 'LeaseStatus';      Type = 'Text' }   # Current / Notice-* / Evict / Vacant-*
    # Vacant units ship too, flagged -- they are the denominator for occupancy.
    @{ Name = 'IsOccupied';       Type = 'Boolean' }
    @{ Name = 'IsMTM';            Type = 'Boolean' }
    @{ Name = 'LeaseFrom';        Type = 'Text' }
    @{ Name = 'LeaseEnd';         Type = 'Text' }
    @{ Name = 'MoveIn';           Type = 'Text' }

    # AppFolio's own renewal pipeline state. Authoritative -- the app trusts
    # this over anything it inferred itself.
    @{ Name = 'AFRenewalStatus';  Type = 'Text';     Indexed = $true }
    @{ Name = 'InRenewalWindow';  Type = 'Boolean' }
    @{ Name = 'RenewalStartDate'; Type = 'Text' }
    @{ Name = 'LastLeaseRenewal'; Type = 'Text' }
    @{ Name = 'LeaseSignDate';    Type = 'Text' }
    @{ Name = 'NoticeGivenDate';  Type = 'Text' }

    @{ Name = 'CurrentRent';      Type = 'Number' }
    @{ Name = 'MarketRent';       Type = 'Number' }
    @{ Name = 'RentVsMarket';     Type = 'Number' }
    @{ Name = 'Deposit';          Type = 'Number' }

    # Negotiation context -- what the PM argues the owner's case with.
    @{ Name = 'PastDue';          Type = 'Number' }
    @{ Name = 'LateCount';        Type = 'Number' }
    @{ Name = 'NSFCount';         Type = 'Number' }

    @{ Name = 'SqFt';             Type = 'Number' }
    @{ Name = 'BedBath';          Type = 'Text' }
    @{ Name = 'UnitTags';         Type = 'Text' }
    @{ Name = 'TenantTags';       Type = 'Text' }
    @{ Name = 'LastRentIncrease'; Type = 'Text' }
    @{ Name = 'NextRentIncrease'; Type = 'Text' }

    @{ Name = 'SyncedAt';         Type = 'DateTime' }
)

$PipelineFields = @(
    @{ Name = 'UnitID';             Type = 'Text';    Indexed = $true; Required = $true }
    # One ACTIVE row per unit. When a renewal completes the row is closed rather
    # than deleted, so last cycle's negotiation stays on the record, and a fresh
    # row opens next cycle.
    @{ Name = 'IsActive';           Type = 'Boolean'; Indexed = $true }

    # Denormalised so the board can filter by PM / owner / property without
    # joining every row back to NS_Renewal_Units.
    @{ Name = 'PropertyName';       Type = 'Text' }
    @{ Name = 'OwnerName';          Type = 'Text';    Indexed = $true }
    @{ Name = 'ManagerName';        Type = 'Text';    Indexed = $true }

    @{ Name = 'Stage';              Type = 'Choice';  Indexed = $true
       Choices = @('Needs Rate','With Owner','Awaiting Approval','Approved to Send','Sent','Non-Renew') }

    @{ Name = 'CurrentRentSnapshot'; Type = 'Number' }
    # Up to three terms are offered at once (9mo, 12mo, and a term sized so the
    # NEXT expiration lands in peak leasing season). Stored as JSON:
    #   [{"months":9,"rent":1350},{"months":12,"rent":1300},{"months":17,"rent":1275}]
    # ProposedRent / ProposedTermMonths mirror the 12-month headline, so
    # approvals, metrics and sorting have one scalar to work from.
    @{ Name = 'OffersJSON';         Type = 'Note' }
    # Some units shouldn't be tied up on a fixed term at all -- owner is
    # selling, unit needs work, resident is shaky. Those get a single
    # month-to-month offer instead of the slate, stored with months = 0.
    @{ Name = 'IsMTMOnly';          Type = 'Boolean' }
    @{ Name = 'ProposedRent';       Type = 'Number' }
    @{ Name = 'ProposedTermMonths'; Type = 'Number' }
    @{ Name = 'ProposedLeaseStart'; Type = 'Text' }
    @{ Name = 'ProposedBy';         Type = 'Text' }
    @{ Name = 'ProposedOn';         Type = 'Text' }

    # The owner round. Every renewal goes through this -- it is the standard
    # step, not an exception path.
    @{ Name = 'OwnerContactedOn';   Type = 'Text' }
    @{ Name = 'OwnerOutcome';       Type = 'Choice'
       Choices = @('Approved','Countered','Declined','No Response') }
    @{ Name = 'OwnerCounterRent';   Type = 'Number' }
    @{ Name = 'OwnerRespondedOn';   Type = 'Text' }
    @{ Name = 'OwnerNotes';         Type = 'Note' }

    # What actually goes to the resident, after the owner round settles it.
    @{ Name = 'FinalRent';          Type = 'Number' }
    @{ Name = 'ApprovedBy';         Type = 'Text' }
    @{ Name = 'ApprovedOn';         Type = 'Text' }
    @{ Name = 'SentOn';             Type = 'Text' }

    @{ Name = 'NonRenewReason';     Type = 'Text' }

    # Owner has gone quiet past the SLA -- surfaces on the approver's board.
    @{ Name = 'Escalated';          Type = 'Boolean' }
    @{ Name = 'EscalatedOn';        Type = 'Text' }

    # The lease end this row was opened against. If AppFolio later reports a
    # later end date, the resident renewed and this cycle is over.
    @{ Name = 'LeaseEndSnapshot';   Type = 'Text' }

    @{ Name = 'Notes';              Type = 'Note' }
    @{ Name = 'ClosedOn';           Type = 'Text' }
    @{ Name = 'ClosedReason';       Type = 'Text' }
    @{ Name = 'ModifiedBy2';        Type = 'Text' }   # 'ModifiedBy' is reserved
    @{ Name = 'ModifiedOn';         Type = 'DateTime' }
)

$ConfigFields = @(
    # Title carries the property name, or the literal '__default__' fallback row.
    @{ Name = 'TargetIncreasePct';  Type = 'Number' }
    @{ Name = 'MinIncreasePct';     Type = 'Number' }
    @{ Name = 'MaxIncreasePct';     Type = 'Number' }
    @{ Name = 'OfferWindowDays';    Type = 'Number' }  # how far ahead a renewal opens
    @{ Name = 'OwnerSLADays';       Type = 'Number' }  # silence past this = escalate
    @{ Name = 'MTMFee';             Type = 'Number' }
    # Months (1-12, comma separated) you WANT leases to expire in. The third
    # offer's term is sized so the next expiration lands in one of these, which
    # is how expirations get steered into peak leasing season over time.
    # Standing notes that ride along with an owner or a property and show on
    # every renewal for them -- "always call before sending", "wants 2% max".
    # Carried over from the old NS_Renewal_Settings.Notes field.
    @{ Name = 'StandingNotes';      Type = 'Note' }
    # 'Property' | 'Owner' | 'Default' -- what the Title refers to. Owner rows
    # carry notes only; policy is resolved per property.
    @{ Name = 'Scope';              Type = 'Text' }
    @{ Name = 'PeakMonths';         Type = 'Text' }
    # Shorter term than 12mo costs the resident more; longer earns a discount.
    @{ Name = 'ShortTermPremium';   Type = 'Number' }
    @{ Name = 'LongTermDiscount';   Type = 'Number' }
    @{ Name = 'ConfigNotes';        Type = 'Note' }
)

$Lists = @(
    @{ Name = 'NS_Renewal_Units';    Fields = $UnitsFields
       Desc = 'AppFolio renewal feed. Written nightly by the cloud ETL - do not hand-edit; edits are erased by the next run.' }
    @{ Name = 'NS_Renewal_Pipeline'; Fields = $PipelineFields
       Desc = 'Renewal rate decisions: owner negotiation and approval. Written by the Renewal Manager app.' }
    @{ Name = 'NS_Renewal_Config';   Fields = $ConfigFields
       Desc = 'Renewal policy per property, plus standing notes per property or owner. One __default__ row supplies the fallback policy.' }
)

# ---------------------------------------------------------------------------

function New-FieldXml {
    param([hashtable]$F)

    $name = $F.Name
    $req  = if ($F.Required) { 'TRUE' } else { 'FALSE' }

    switch ($F.Type) {
        'Choice' {
            $opts = ($F.Choices | ForEach-Object { "<CHOICE>$([System.Security.SecurityElement]::Escape($_))</CHOICE>" }) -join ''
            # Format="Dropdown" + FillInChoice TRUE: AppFolio can invent a new
            # status at any time, and a Choice column that rejects it fails the
            # whole write. Accepting fill-ins degrades gracefully instead.
            return "<Field Type='Choice' Name='$name' StaticName='$name' DisplayName='$name' Required='$req' Format='Dropdown' FillInChoice='TRUE'><CHOICES>$opts</CHOICES></Field>"
        }
        'Note'    { return "<Field Type='Note' Name='$name' StaticName='$name' DisplayName='$name' Required='$req' NumLines='6' RichText='FALSE' />" }
        'Boolean' { return "<Field Type='Boolean' Name='$name' StaticName='$name' DisplayName='$name' Required='$req'><Default>0</Default></Field>" }
        'Number'  { return "<Field Type='Number' Name='$name' StaticName='$name' DisplayName='$name' Required='$req' Decimals='2' />" }
        'DateTime'{ return "<Field Type='DateTime' Name='$name' StaticName='$name' DisplayName='$name' Required='$req' Format='DateTime' />" }
        default   { return "<Field Type='Text' Name='$name' StaticName='$name' DisplayName='$name' Required='$req' MaxLength='255' />" }
    }
}

Write-Host "Connecting to $SiteUrl ..." -ForegroundColor Cyan
Connect-PnPOnline -Url $SiteUrl -Interactive -ClientId $ClientId
Write-Host "Connected as $((Get-PnPContext).Credentials)" -ForegroundColor DarkGray

$created = 0; $addedFields = 0; $skipped = 0

foreach ($spec in $Lists) {
    $listName = $spec.Name

    $list = Get-PnPList -Identity $listName -ErrorAction SilentlyContinue
    if (-not $list) {
        if ($PSCmdlet.ShouldProcess($listName, 'Create list')) {
            Write-Host "Creating list $listName ..." -ForegroundColor Green
            $list = New-PnPList -Title $listName -Template GenericList -OnQuickLaunch:$false
            Set-PnPList -Identity $listName -Description $spec.Desc
            $created++
        }
    } else {
        Write-Host "List $listName already exists." -ForegroundColor DarkGray
    }

    # Existing internal names, so re-runs only add what's genuinely missing.
    $have = @{}
    if ($list) {
        Get-PnPField -List $listName | ForEach-Object { $have[$_.InternalName] = $_ }
    }

    foreach ($f in $spec.Fields) {
        if ($have.ContainsKey($f.Name)) { $skipped++; continue }

        if ($PSCmdlet.ShouldProcess("$listName.$($f.Name)", "Add $($f.Type) column")) {
            $xml = New-FieldXml -F $f
            Add-PnPFieldFromXml -List $listName -FieldXml $xml | Out-Null
            Write-Host "  + $($f.Name) [$($f.Type)]" -ForegroundColor Green
            $addedFields++
        }
    }

    # Index the columns the app filters on. Without these SharePoint throws the
    # 5,000-item list-view threshold error once these lists grow, and the app's
    # filtered reads start failing outright rather than just running slowly.
    foreach ($f in ($spec.Fields | Where-Object { $_.Indexed })) {
        try {
            $fld = Get-PnPField -List $listName -Identity $f.Name -ErrorAction Stop
            if (-not $fld.Indexed) {
                if ($PSCmdlet.ShouldProcess("$listName.$($f.Name)", 'Index column')) {
                    Set-PnPField -List $listName -Identity $f.Name -Values @{ Indexed = $true } | Out-Null
                    Write-Host "  * indexed $($f.Name)" -ForegroundColor DarkCyan
                }
            }
        } catch {
            # Indexing is an optimisation, not a correctness requirement -- a
            # failure here must not abort provisioning.
            Write-Warning "Could not index $listName.$($f.Name): $($_.Exception.Message)"
        }
    }
}

# --- seed the fallback policy row ------------------------------------------
# Every property inherits from this unless it has its own row. Values are the
# defaults carried over from the previous app's settings.
$defaultRow = Get-PnPListItem -List 'NS_Renewal_Config' `
    -Query "<View><Query><Where><Eq><FieldRef Name='Title'/><Value Type='Text'>__default__</Value></Eq></Where></Query></View>" `
    -ErrorAction SilentlyContinue

if (-not $defaultRow) {
    if ($PSCmdlet.ShouldProcess('NS_Renewal_Config.__default__', 'Seed default policy row')) {
        Add-PnPListItem -List 'NS_Renewal_Config' -Values @{
            Title              = '__default__'
            Scope              = 'Default'
            TargetIncreasePct  = 3.0
            MinIncreasePct     = 0.0
            MaxIncreasePct     = 10.0
            OfferWindowDays    = 75
            OwnerSLADays       = 5
            MTMFee             = 100
            PeakMonths         = '5,6,7,8'
            ShortTermPremium   = 50
            LongTermDiscount   = 25
            ConfigNotes        = 'Fallback policy. Any property without its own row uses these values.'
        } | Out-Null
        Write-Host "Seeded NS_Renewal_Config.__default__" -ForegroundColor Green
    }
} else {
    Write-Host "NS_Renewal_Config.__default__ already present." -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "Done. Lists created: $created | Columns added: $addedFields | Already present: $skipped" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next:" -ForegroundColor Yellow
Write-Host "  1. Run the ETL feed once to populate NS_Renewal_Units:" -ForegroundColor Yellow
Write-Host "     GitHub > newshire-appfolio-dashboard > Actions > Daily AppFolio ETL > Run workflow" -ForegroundColor Yellow
Write-Host "  2. Confirm NS_Renewal_Units has ~470 rows, then open the app." -ForegroundColor Yellow
Write-Host "  3. The old NS_Units_Cache list and the AF_Sync_LeaseData flow can be" -ForegroundColor Yellow
Write-Host "     turned off once you've compared the two for a day. See docs/renewals-architecture.md" -ForegroundColor Yellow
