# Renewal Manager

Lease renewals for NewShire Property Management. Property managers work their
renewals here: set the ask, negotiate it with the owner, route it for approval,
send the offer in AppFolio.

**→ [docs/renewals-architecture.md](docs/renewals-architecture.md)** — how it
works, why it was rewritten, and the cutover steps.

## Quick facts

| | |
|---|---|
| App | Single-page `index.html`, vanilla JS, no build step |
| Auth | MSAL → Microsoft Graph, signed in as the user |
| Data in | `NS_Renewal_Units` — written nightly from AppFolio by the [newshire-appfolio-dashboard](https://github.com/BrandyTurner815/newshire-appfolio-dashboard) ETL |
| Data out | `NS_Renewal_Pipeline` (decisions), `NS_Renewal_Config` (policy) |
| Site | `newshirepmcom.sharepoint.com/sites/NewShirePM` |

## Setup

```powershell
.\scripts\provision-renewal-lists.ps1     # creates the three lists; -WhatIf to preview
```

Then run the **Daily AppFolio ETL** workflow once to populate the feed.

## ⚠️ This repo is public

No resident or employee data, ever. `.gitignore` blocks `*.csv` / `*.xlsx` /
`*.iqy`; never `git add -A` without looking first.

`NS_Renewal_Units` is machine-owned — the nightly sync deletes anything AppFolio
no longer reports, so hand edits to that list disappear at 4 AM.
