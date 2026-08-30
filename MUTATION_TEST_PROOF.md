# Mutation Test Proof: DateTime Sorting in Duplicate Suggestion Selection

## Root Cause: Map Key Ordering

`DateTime` is a Struct (a special case of Map). Erlang's term ordering compares Maps by their key order lexicographically, not by semantic meaning or structure.

The actual key order in a DateTime struct is:
```
:__struct__, :calendar, :day, :hour, :microsecond, :minute, :month,
:second, :std_offset, :time_zone, :utc_offset, :year, :zone_abbr
```

Critically, `:microsecond` is compared **before** `:minute`, `:month`, `:second`, and `:year`.

### Why the Original Test Case Masked the Defect

The original test used times that crossed an **hour boundary**:
- earlier: `14:59:59.999999`
- later: `15:00:00.000001`

When comparing these DateTime structs as Maps:
- Both have `:__struct__` = `DateTime` (equal)
- Both have `:calendar` = `Calendar.ISO` (equal)
- Both have `:day` = same day (equal)
- At `:hour`: `14 < 15` → comparison stops here, result determined

The defect in `:microsecond` ordering never manifests because `:hour` decides the comparison first.

### Real Minute Boundary Test

A true **minute boundary** within the same hour forces evaluation to reach `:microsecond`:
- earlier: `2026-08-29T14:30:59.999999Z`
- later: `2026-08-29T14:31:00.000001Z`

When comparing these as Maps:
- `:__struct__`, `:calendar`, `:day`, `:hour` all equal
- At `:microsecond`: `999999 > 1` → **Map ordering says later is less than earlier**

This is the semantic defect: microseconds should not influence whether 14:30:59 or 14:31:00 comes first.

## Test Results: New Sorting Key

**Sorting key in `lib/fahrgastrechte/claim_workspace.ex:575`:**
```elixir
|> Enum.sort_by(&{-&1.confidence, DateTime.to_unix(&1.inserted_at, :microsecond), &1.id})
```

**Test data (minute boundary):**
```elixir
earlier_time = DateTime.new!(Date.new!(2026, 8, 29), Time.new!(14, 30, 59, {999_999, 6}))
later_time = DateTime.new!(Date.new!(2026, 8, 29), Time.new!(14, 31, 0, {1, 6}))
```

**Execution via `mise exec --` (Elixir 1.20.2-otp-28):**

| Seed | Result | Notes |
|------|--------|-------|
| 0 | ✓ PASS | 1 passed, 21 excluded |
| 1 | ✓ PASS | 1 passed, 21 excluded |
| 42 | ✓ PASS | 1 passed, 21 excluded |
| 999999 | ✓ PASS | 1 passed, 21 excluded |

**Assertion passes for all seeds:**
```elixir
assert Enum.map(workspace.suggestion_groups.booking, & &1.id) == [earlier_suggestion.id]
```

The chronologically earlier suggestion (`14:30:59.999999`) is correctly selected as the representative.

## Mutation Test: Old Sorting Key (Actual Results)

**Test execution via `mise exec --` with old sorting key `{-&1.confidence, &1.inserted_at, &1.id}`:**

The sorting key was temporarily reverted to use DateTime struct comparison directly. All four seeds failed with the expected wrong representative ID:

### Seed 0
```
Assertion with == failed
code:  assert Enum.map(workspace.suggestion_groups.booking, & &1.id) == [earlier_suggestion.id]
left:  ["da024fbd-28b5-49e1-946c-dc0037ac99a3"]
right: ["05290f62-e6c6-439d-9c99-8495e8f75485"]
Result: 0/1 passed, 21 excluded
Failed: 1 test
```

### Seed 1
```
Assertion with == failed
code:  assert Enum.map(workspace.suggestion_groups.booking, & &1.id) == [earlier_suggestion.id]
left:  ["cc23bc04-1888-40ed-9186-1ce42bcaef43"]
right: ["b89a10a9-fb21-4f1b-855a-59c202b749b1"]
Result: 0/1 passed, 21 excluded
Failed: 1 test
```

### Seed 42
```
Assertion with == failed
code:  assert Enum.map(workspace.suggestion_groups.booking, & &1.id) == [earlier_suggestion.id]
left:  ["2fff7a4b-10ec-4c1f-9814-0e379920bac7"]
right: ["2973e511-d67d-4997-bd43-f734637819b9"]
Result: 0/1 passed, 21 excluded
Failed: 1 test
```

### Seed 999999
```
Assertion with == failed
code:  assert Enum.map(workspace.suggestion_groups.booking, & &1.id) == [earlier_suggestion.id]
left:  ["22056a93-d972-481d-a52c-d4268e9ac008"]
right: ["175771f5-3c8e-4dae-be6b-446030e9a670"]
Result: 0/1 passed, 21 excluded
Failed: 1 test
```

**Summary**: All four seeds fail with `0/1 passed` when the old sorting key is used. The mutation consistently selects the wrong representative (the later-created suggestion instead of the chronologically earlier one), proving that the fix is a genuine correctness improvement.

## Full Test Suite Results

**All checks passed:**
- `mix format --check-formatted`: ✓ PASS (no formatting issues)
- `mix compile --warnings-as-errors`: ✓ PASS (83 files compiled)
- Target test (all 4 seeds): ✓ PASS
- `mix test` (full suite): ✓ PASS (325/325 tests)
- `mix hex.audit`: ✓ PASS (no vulnerabilities)
- `mix deps.audit`: ✓ PASS (no vulnerabilities)
- `mix sobelow --exit medium`: ✓ PASS (low-confidence warnings only)

## Conclusion

The new sorting key (`DateTime.to_unix/2`) bypasses the Map key ordering issue by converting DateTimes to a scalar integer (microseconds since epoch). This ensures correct chronological ordering regardless of the DateTime struct's internal field layout.

The test with a real minute boundary now correctly exposes the defect of the old key, providing proof that the change from DateTime comparison to Unix timestamp comparison is a correctness fix, not merely an enhancement.
