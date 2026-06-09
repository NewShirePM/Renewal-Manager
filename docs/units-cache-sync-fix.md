# Fixing moved-out residents in NS_Units_Cache

## Root cause
The Power Automate flow **`AF_Sync_LeaseData`** (daily) pulls AppFolio's full `rent_roll`
report — which includes every unit with a real status of **Current / Month-To-Month /
Notice / Evict / Vacant** — but then a `Filter array` action throws most of it away:

```
Filter_Active_Units
  where:  status == 'Current'  OR  status == 'Month-To-Month'
```

Only those rows reach the upsert loop. So:

- When a resident moves out, the unit's status flips to **Vacant** → it's filtered out →
  its cache row is never updated again → it stays frozen on **"Current"** forever (fossil).
- **Notice** and **Eviction** units never reach the cache at all.

The loop upserts by `UnitID` (one row per unit) and stamps `LastSyncedAt = utcNow()` each run,
so once a unit stops appearing in the filtered set, its `LastSyncedAt` stops advancing.

## The fix — stop filtering out the other statuses
Let every unit through so its real status is always written. A move-out then lands as
**Vacant**, which the app already hides (`isInactiveStatus()`), and Notice/Eviction finally
show up correctly.

### Step 1 — broaden `Filter_Active_Units`
Open the flow → the **Filter_Active_Units** action → switch the advanced (code) view of the
condition and replace the expression with:

```
@contains(createArray('Current','Month-To-Month','Notice','Evict','Eviction','Vacant'), item()?['status'])
```

(Or, to include anything with a status, use `@not(empty(item()?['status']))`.)

That's the only change strictly required.

### Step 2 — let the LeaseStatus column accept the new values
`LeaseStatus` is a **Choice** column (the flow writes `item/LeaseStatus/Value`). If it only
lists `Current` / `Month-To-Month`, writing `Notice`/`Evict`/`Vacant` will fail.

In the **NS_Units_Cache** list → **LeaseStatus** column settings, either:
- add the choices **Notice**, **Evict**, **Vacant**, or
- turn on **"Allow custom values" / fill-in choices** (future-proofs any AppFolio status).

### Result
- Existing fossils self-heal: on the next run the unit now appears (as Vacant), `Check_Unit_Exists`
  matches its `UnitID`, and `Update_item` overwrites status → Vacant and clears the old resident
  name. The app hides it.
- Notice / Eviction units flow in and light up those views.
- No deletions, nothing destructive.

## Optional — physically prune Vacant rows (keep the list to occupied units)
Step 1/2 leave Vacant rows in the list (hidden, but they accumulate). If you'd rather the list
hold only occupied units and delete the rest:

1. In **Step 1**, use the *occupied-only* set (drop `Vacant`):
   ```
   @contains(createArray('Current','Month-To-Month','Notice','Evict','Eviction'), item()?['status'])
   ```
2. Add an **Initialize variable** as the very first action: name `RunStart`, type String,
   value `@{utcNow()}`.
3. After the existing `Apply_to_each`, add:
   - **Get items** — Site `https://vanrockre.sharepoint.com/sites/NewshirePM`, List **NS_Units_Cache**,
     Filter Query: `LastSyncedAt lt '@{variables('RunStart')}'`, Top Count `5000`.
   - **Apply to each** over its `value` → **Delete item** (Id = `@{items('Apply_to_each_2')?['ID']}`).

   Every occupied unit is stamped this run (so `LastSyncedAt >= RunStart`); any row left with an
   older `LastSyncedAt` is a unit that's no longer occupied → safe to delete. Because Notice/Evict
   are included in the occupied set, they're never wrongly removed.

## Notes
- `LastSyncedAt` is the internal column name (display name "Last Synced").
- Companion app change already shipped: `mapLeaseStatus()` now recognizes AppFolio's `Evict`
  (not just `Eviction`) so eviction units render with the right badge.
- `scripts/reconcile-moved-out.ps1` is a one-off cleanup using the same `LastSyncedAt` signal —
  no longer needed once the flow fix above is in place.
