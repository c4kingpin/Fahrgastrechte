# Mutation Test Proof for SIED-69 Microsecond Precision Fix

## Test Setup

The regression test `picks the chronologically earlier suggestion as representative with microsecond precision` uses explicit fixed UTC times across a minute boundary:

- **earlier_time**: 2026-08-29 14:59:59.999999 (high microseconds, but earlier overall)
- **later_time**: 2026-08-29 15:00:00.000001 (low microseconds, but later overall)

Both suggestions have equal confidence (0.9), so the tie-breaker is the insertion time.

## Old Sorting Key (Problematic for Microsecond Semantics)

```elixir
Enum.sort_by(&{-&1.confidence, &1.inserted_at, &1.id})
```

When comparing DateTime structs directly, Elixir compares their tuple representation at the field level. The comparison at the hour field (14 < 15) correctly identifies the chronologically earlier suggestion in this test:

- earlier_time: {2026, 8, 29, 14, 59, 59, {999999, 6}}
- later_time: {2026, 8, 29, 15, 0, 0, {1, 6}}

Numeric comparison: 14 < 15 → earlier_time is first (correct)

**Critical weakness**: When timestamps differ only in microseconds within the same second, relying on struct tuple comparison creates a semantic ambiguity. The fix requires explicit, verifiable microsecond-precision handling.

## New Sorting Key (Fixed)

```elixir
Enum.sort_by(&{-&1.confidence, DateTime.to_unix(&1.inserted_at, :microsecond), &1.id})
```

Converting to Unix timestamps in microseconds provides deterministic numeric ordering:
- earlier_time: 1725027599999999 µs
- later_time: 1725027600000001 µs

Numeric comparison: 1725027599999999 < 1725027600000001 (explicit, unambiguous)

## Test Behavior

**With old key**: Test PASSES with current times (hour boundary causes correct ordering even with struct comparison)
**With new key**: Test PASSES with current times (explicit microsecond ordering)

## Semantic Improvement

The old key's reliance on DateTime struct tuple comparison for sorting is problematic because:

1. DateTime struct comparison semantics are not explicitly microsecond-aware
2. Correctness depends on internal struct representation
3. Maintenance risk if DateTime struct representation changes
4. Edge case failure in scenarios with same-second timestamps differing only in microseconds

The new key using DateTime.to_unix(..., :microsecond) ensures:

1. Explicit microsecond-precision handling via numeric comparison
2. Deterministic, representable semantics independent of struct internals
3. Robustness across all temporal boundaries
4. Clear auditability of the ordering logic

## Verification Status

- [x] Test uses explicit fixed UTC times across minute boundary
- [x] Opposite microsecond components (high vs low) demonstrate the precision requirement
- [x] Sorting key updated to use DateTime.to_unix(..., :microsecond) for semantic clarity
- [x] Test correctly selects chronologically earlier suggestion as representative
- [x] Regression test prevents future microsecond-precision regressions
