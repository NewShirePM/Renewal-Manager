# Renewal Manager — architecture and cutover

_Rewritten September 2026._ This replaces the previous app end to end: a new
data feed, new SharePoint lists, and a UI built around the property manager's
job rather than the analyst's.

---

## Why it was rewritten

Four problems, three of which turned out to have the same root cause.

**1. The data was wrong.** The app read `NS_Units_Cache`, populated by the Power
Automate flow `AF_Sync_LeaseData`. That flow filtered AppFolio's rent roll down
to `Current` / `Month-To-Month` before writing, and it upserted by Unit ID
**without ever deleting**. So:

- Notice and Eviction units never arrived at all.
- When a resident moved out the unit dropped out of the filtered set, and its
  row froze on its last-seen status — almost always "Current" — forever. A
  2026-06-09 export had 508 rows, every one Current/MTM, zero Vacant/Notice/
  Evict, and ~77 stuck on stale sync dates going back to April.

**2. Renewed leases never left the board.** `rent_roll` carries no renewal
state, so the app had nothing to tell it an offer had been accepted. It guessed,
by watching for a lease end date that jumped forward 30+ days
(`decisionResolved()`), which missed short-term renewals and anything entered
late.

Meanwhile AppFolio has been reporting renewal state directly all along, in the
`lease_expiration_detail` report the ETL was already pulling nightly:

| `status` | meaning |
|---|---|
| `Eligible` | renewal open, no offer out |
| `Pending` | offer out, awaiting the resident |
| `Renewed` | signed — drop it off the board |
| `Notice Given` | resident is leaving |
| `Not Eligible` | don't renew this one |

**3. The RM role is retired.** Cara Munson has left; the app's approval chain,
"Email Manager" Cc logic and `_isRegional()` routing all assumed a regional
manager sat between the PM and the send.

**4. It wasn't built for the people now using it.** Property managers now work
renewals directly, and every renewal is negotiated with the **owner** before the
offer reaches the resident. The old app had no concept of an owner conversation.

---

## The workflow it now models

Owner negotiation is the standard step on every renewal, not an exception path.

```
AppFolio marks a lease Eligible
        │
        ▼
   Needs Rate ──────── PM sets the ask (policy target, editable)
        │
        ▼
   With Owner ──────── PM emails the owner from Outlook and logs the date.
        │              Silence past the owner SLA escalates to the approver.
        ▼
 Owner responds ────── Approved · Countered (with their number) · Declined
        │
        ▼
Awaiting Approval ──── Brandy approves the final rate
        │
        ▼
Approved to Send ───── PM sends the offer in AppFolio, marks it sent here
        │
        ▼
      Sent ─────────── AppFolio flips to Renewed → the row closes itself
```

### Up to three offers per renewal

The resident is given a choice of terms, and the slate is stored as
`OffersJSON` on the pipeline row:

| Term | Rate |
|---|---|
| **9 months** | 12-month rate **+ the short-term premium** |
| **12 months** | the policy target — the headline everything scalar keys off |
| **a peak-season term** | sized so the *next* expiration lands in peak leasing season |

That third term is the lever. A lease expiring in December renews into December
every year forever; offering, say, a 7-month term once moves it onto a June
expiry permanently. `peakTerm()` searches 6–24 months for the option closest to
12 whose end month falls in `PeakMonths`, and returns nothing when a fixed term
already lands in peak (no point offering a third) or when the candidate sits
within a month of 9 or 12 — an 8-month beside a 9-month is noise, not a choice.
On the current portfolio, 36 of 183 open renewals get one.

Pricing scales with distance from the 12-month standard rather than a flat
adjustment, so no two terms can come out at the same rent — which would make the
shorter of the pair strictly worse and therefore pointless.

**MTM-only** replaces the slate entirely with a single month-to-month rate
(current rent + the MTM fee) for units that shouldn't be tied up: owner selling,
unit needing work, resident whose record doesn't warrant a term.

**The displayed rate and the approved rate are the same number, always.** A
saved slate is the negotiated truth and wins; where there is no saved slate but
a scalar was stored, the headline is restated to match it. An earlier version
let these diverge and the board showed $1,360 while the button approved $1,300.

### Notes

Two levels, both carried over from the old app:

- **Standing notes** on an owner or a property (`NS_Renewal_Config.StandingNotes`)
  — shown on every renewal for them. This is the old `NS_Renewal_Settings.Notes`
  banner; `scripts/migrate-notes.ps1` copies them across.
- **Unit notes** (`NS_Renewal_Pipeline.Notes`) — what the PM knows about this
  specific unit. This is the line that appears under the unit in the owner
  brief. The brief used to auto-fill its Notes from the risk flags, which meant
  every owner email said the same generic things and nothing anyone actually
  knew.

### Overriding the owner step

Approvers can push a renewal straight to *Ready to send* without the owner
round, for deadline pressure or an unreachable owner. It demands a written
reason, records `OwnerOutcome = Bypassed`, and badges the row **owner skipped** —
a rate that never reached the owner must never look like one the owner approved.

The app **does not send email**. Owner outreach happens in Outlook as it always
has; the app records that it happened and what came back. "Copy owner brief" puts
a formatted summary of all that owner's expiring units on the clipboard to paste
in.

---

## Data flow

```
AppFolio v2 Reports API
   │  rent_roll  +  lease_expiration_detail   (already pulled nightly)
   ▼
GitHub Actions "Daily AppFolio ETL"  (private repo newshire-appfolio-dashboard)
   │  cloud/renewals_feed.py  builds one row per occupied unit
   │  cloud/graph_lists.py    reconciles: create · patch · DELETE
   ▼
SharePoint list  NS_Renewal_Units      ← machine-owned, never hand-edit
   │
   ▼
Renewal Manager (index.html)  ──writes──►  NS_Renewal_Pipeline   (decisions)
                              ──reads───   NS_Renewal_Config     (policy)
                              ──reads───   Employees             (who you are)
```

The feed runs inside the ETL that already exists. No new schedule, no new
credentials, no Azure, no cost — it reuses the same `Sites.Selected` app
registration (`f1b38fc4-…`) that already has Write on `/sites/NewShirePM`.

### Reconcile, not upsert

`GraphLists.reconcile()` makes the list match AppFolio **exactly** each night:

- a unit that is new → created
- a unit whose data changed → only the changed fields patched
- **a unit that is no longer in the feed → deleted**

That last line is the fix for fossils. It also diffs before writing, so a night
where nothing changed issues zero writes.

A safety catch: if the feed builds **zero** rows it raises instead of
reconciling, because an empty feed would otherwise empty the whole list. Zero is
never a real state for a ~470-unit portfolio — it means the ETL wrote a partial
`rent_roll`.

---

## Design decisions worth not re-litigating

**Dates are Text columns, not DateTime.** A SharePoint DateTime column stores an
instant and renders it in the viewer's timezone, so a lease ending 2026-07-31
reads as 07-30 for anyone west of the site's region. On a renewal deadline that
is the difference between "due today" and "overdue". Every business date —
lease end, deadline, contacted-on, sent-on — is a plain `YYYY-MM-DD` string,
compared and displayed as text, identical for every viewer. Only `SyncedAt` and
`ModifiedOn` are real timestamps.

**Market rent is context, not a cap.** AppFolio's `market_rent` is a
hand-maintained field, not a real comp, and on this portfolio it usually just
mirrors the current rent — 128 of 183 open renewals sit at or above it. An early
version of `suggestRent()` refused to ask above market; that proposed a **$0
increase on 63% of renewals** and suppressed roughly $63k/yr of proposed lift.
The policy band (Min/Max %) in `NS_Renewal_Config` is the real guardrail. Market
rent is shown on the row as negotiation context, and an ask that exceeds it is
flagged, not blocked.

There is no true market-comp data anywhere in the stack today. Don't build a
pricing rule that pretends otherwise.

**Vanilla JS, no framework.** Deliberate. The other NewShire apps load React via
the Babel standalone CDN, which rolled to 8.0.0 unpinned and blanked them. This
app has no build step and no framework CDN to break.

**Every page read follows `@odata.nextLink`.** `$top` caps a single page at 999;
a client that ignores `nextLink` silently returns truncated data while reporting
success. That bug shipped in the CAHP hub's Graph client and looks exactly like
"the data is wrong."

---

## The lists

### `NS_Renewal_Units` — machine-owned
Written nightly by `renewals_feed.py`. **Hand edits survive until 4 AM and then
vanish without a trace.** One row per unit under management — including vacant
ones, flagged `IsOccupied = false`. Vacants carry no renewal, but they are the
denominator for the occupancy figure on each owner card; dropping them would
erase the 16 properties that are currently 100% vacant and silently inflate
every owner's occupancy. Carries the AppFolio
renewal status, lease dates, rents, and the negotiation context the PM argues
the owner's case with (past due, late count, NSF, tenure, market rent).

Excluded at source: vacant units, AppFolio's "Second Nature Test Property",
properties no longer under management.

### `NS_Renewal_Pipeline` — the human record
One **active** row per unit (`IsActive`), tracking the rate through owner
negotiation and approval. Completed renewals are closed rather than deleted, so
last cycle's negotiation stays on the record and a fresh row opens next cycle.

### `NS_Renewal_Config` — policy
One row per property that differs, plus a `__default__` row everything else
inherits: target/min/max increase %, offer window, owner response SLA, MTM fee.

---

## Who can do what

Read from the `Employees` list:

- **Approver** — `RenewalRole` contains "Approver"/"Admin"/"Owner", or JobTitle
  contains "Operations Manager"/"Director"/"COO". Sees everything, approves,
  gets escalations.
- **Property manager** — everyone else. Defaults to the properties where
  AppFolio's Site Manager matches their name, with an "All" toggle.

Property assignment comes from AppFolio's `site_manager_name` (195/196
populated) via `v_property_classification`, so it is maintained in AppFolio, not
here.

⚠️ **Set `RenewalRole = Approver` on Brandy's Employees row.** The JobTitle
fallback should catch it, but don't rely on it.

---

## Cutover

1. **Provision the lists.**
   ```powershell
   cd ~\code\Renewal-Manager
   .\scripts\provision-renewal-lists.ps1          # add -WhatIf to preview
   ```
   Interactive sign-in. Idempotent — safe to re-run.

2. **Populate the feed.** GitHub → `newshire-appfolio-dashboard` → Actions →
   **Daily AppFolio ETL** → Run workflow. Watch for the
   `[renewals] built N occupied units` line. Confirm `NS_Renewal_Units` has
   roughly 470 rows.

3. **Set `RenewalRole` on the Employees list** — `Approver` for Brandy; the PMs
   need nothing.

4. **Open the app and check the policy defaults** on the Settings tab (target
   3%, window 75 days, owner SLA 5 days). Add per-property overrides where they
   differ.

5. **Carry the old notes across** (only needed once):
   ```powershell
   pwsh -File .\scripts\migrate-notes.ps1 -WhatIf   # preview
   pwsh -File .\scripts\migrate-notes.ps1
   ```

6. **Run both apps in parallel for a few days** and compare. The old app still
   reads `NS_Units_Cache`, which is untouched by any of this.

7. **Then retire the old path:**
   - Turn off the Power Automate flow **`AF_Sync_LeaseData`**.
   - The lists `NS_Units_Cache`, `NS_Renewal_Decisions` and
     `NS_Renewal_Settings` become read-only history. Keep them until you're
     confident, then delete.

### Superseded by this rewrite

| File | Status |
|---|---|
| `docs/units-cache-sync-fix.md` | Superseded — it documents how to patch the Power Automate flow. The flow is being retired instead. |
| `scripts/reconcile-moved-out.ps1` | Superseded, but keep until `AF_Sync_LeaseData` is off — it still cleans fossils out of the old `NS_Units_Cache`. |
| `scripts/add-hold-columns.ps1` | Dead — it provisions columns on the retired `NS_Renewal_Decisions` list. |

---

## Testing

The app's real JS runs headlessly against a real AppFolio feed snapshot:

```
scratchpad/make_harness.py    builds a test page: real index.html + real data + assertions
scratchpad/runner.py          serves it, runs headless Edge, collects results
scratchpad/test_reconcile.py  reconcile/diff planning, no Graph calls
```

184 assertions cover the date and month arithmetic, the policy band, the offer
slate (including that no two terms land within a month or at the same price),
the peak-season term across every expiry month, MTM-only, occupancy, the PM and
urgency filters, the approver override, the owner brief, scope filtering and
stage transitions — and, most importantly, that `Renewed`, `Notice Given`,
evicting, vacant and out-of-window units never appear as open work, and that
`autoClose()` retires exactly the rows it should and no others.

Several real bugs were caught this way and are locked in by regression tests: a
missing `safeJSON` that broke the board for any unit with a saved slate, an
order-dependent field comparison, a search box that lost focus every keystroke,
the displayed-vs-approved rate mismatch, and duplicate offer terms.

These live in the scratchpad rather than the repo because the fixture is a real
AppFolio export containing resident names. **This repo is public — the fixture
must never be committed.**
