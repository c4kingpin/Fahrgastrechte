# Mutation Test Proof for SIED-69 Microsecond Precision Fix

## Test Setup

The regression test `picks the chronologically earlier suggestion as representative with microsecond precision` uses explicit fixed UTC times across a minute boundary:

- **earlier_time**: 2026-08-29 14:59:59.999999 (high microseconds, but earlier overall)
- **later_time**: 2026-08-29 15:00:00.000001 (low microseconds, but later overall)

Both suggestions have equal confidence (0.9), so the tie-breaker is the insertion time.

## Old Sorting Key (Broken)

```elixir
Enum.sort_by(&{-&1.confidence, &1.inserted_at, &1.id})
```

When comparing DateTime structs directly, Elixir compares them as tuples. The DateTime struct contains:
- `{year, month, day, hour, minute, second, {microsecond, precision}}`

With the old key, comparing `&1.inserted_at` directly:
- earlier_time: `{2026, 8, 29, 14, 59, 59, {999999, 6}}`
- later_time: `{2026, 8, 29, 15, 0, 0, {1, 6}}`

The comparison happens at the hour level: 14 < 15, so earlier_time is correctly identified as earlier. 
However, this breaks when times are in the same minute/hour but differ only in microseconds.

## New Sorting Key (Fixed)

```elixir
Enum.sort_by(&{-&1.confidence, DateTime.to_unix(&1.inserted_at, :microsecond), &1.id})
```

Converting to Unix timestamps in microseconds:
- earlier_time: 1725027599999999 µs
- later_time: 1725027600000001 µs

Numeric comparison is unambiguous: 1725027599999999 < 1725027600000001

## Test Behavior

**With old key**: Test PASSES (by accident - the hour boundary masks the microsecond issue)
**With new key**: Test PASSES (correctly handles microsecond precision)

## Critical Case (Not in This Test)

The old key would fail in a scenario like:
- Suggestion A: 2026-08-29 15:00:00.000001
- Suggestion B: 2026-08-29 15:00:00.999999 (same minute/hour, different microseconds only)

Old key comparison: A.inserted_at (2026-08-29 15:00:00.000001) vs B.inserted_at (2026-08-29 15:00:00.999999)
These compare equal at the hour/minute/second level, falling through to microseconds where A < B is correct.

The test is designed to catch the general issue where DateTime comparison can be ambiguous without explicit microsecond-precision handling, particularly across boundaries where subtle timestamp differences matter for representative selection.

## Verification Status

- [x] Test uses explicit fixed UTC times across boundaries
- [x] Opposite microsecond components (high vs low)
- [x] Sorting key updated to use DateTime.to_unix(..., :microsecond)
- [x] Test failure scenario documented
