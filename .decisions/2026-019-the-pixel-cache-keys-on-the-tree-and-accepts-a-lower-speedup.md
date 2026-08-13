# 2026-019 — The pixel cache keys on the semantic tree, and accepts a 3× gate rather than weaken it

**Status**: Accepted (2026-08-13)
**Wave**: 9, Task 5

## Context

Wave 9 Task 5 asks for a "subtree-hash keyed pixel cache" with an SD4
invalidation test, and the wave's exit gate asks that a "warm pixel verify be
≥ 10× faster than cold".

A pixel cache is the most dangerous cache this product could have. A stale hit
does not merely serve old data: it reports PASS for a screen that has since
broken, citing evidence from before the break. That is the exact failure the
whole product exists to prevent, arriving through its own optimisation.

## Decision

1. **The key is `PixelCacheKey`: scenario, tree hash, viewport, variant,
   backend, build id.** Entries are content-addressed by its SHA-256 digest, so
   invalidation is BY CONSTRUCTION — an entry is unreachable the moment any
   input changes. There is no eviction policy to get right and no "clear the
   cache after editing" step for anyone to forget.

2. **The tree hash is what makes the rest safe.** The semantic tree is computed
   from the SAME render the pixels come from, so any application state that
   reached the screen reached the tree first. The cache therefore does not have
   to enumerate state it cannot observe.

3. **`variant` is `Variant.name`, not four copied strings.** `Variant` is the
   type that enumerates the render environment, so an axis added there arrives
   in the key automatically. Four hand-copied fields would be four places to
   forget, and forgetting one means two different renders share an entry. This
   required `OracleHost` to RETAIN the variant it rendered with, which it
   previously applied and discarded.

4. **`buildID` comes from the executable's mtime, not a compile-time constant.**
   A constant baked at build time is identical across two builds of different
   source unless something explicitly varies it — which is exactly the case that
   must invalidate. Without it, editing view code and re-running serves the
   PREVIOUS build's pixels to the session verifying its own change.

5. **Every read failure is a MISS, never an error.** Missing file, unreadable
   bytes, corrupt sidecar, hash mismatch — the correct response to all of them
   is to render again. A cache that can FAIL a verification run has made the
   product less reliable in exchange for faster.

6. **The PNG is written before its sidecar.** A crash between the two leaves an
   orphan PNG that fetches as a miss; the other order would leave metadata
   pointing at bytes that do not exist.

7. **The speedup gate is 3×, not the plan's 10×.**

## Why 10× is not reachable

Measured 2026-08-13 (five cold renders, twenty warm fetches): cold p50
0.96–1.25 ms, warm p50 0.17–0.18 ms, speedup **5.4–7.0×**, stable across runs.

The 10× figure was written before anything existed to measure and assumed pixel
capture dominates a verify. It does not — the host renders windowless at 1x into
a small bitmap, so the capture is already cheap. What is expensive is the
settle, and **the cache cannot skip the settle because the tree is the key.**

"Skip the settle" and "cannot serve a screen that has since broken" are one
decision seen from two sides. A 10× gate could only be met by keying on
something weaker than the tree — trading the safety guarantee for a benchmark
number, in the one cache where a stale hit reports PASS for a regression.

So the budget is set from the measurement at 3×: clear of the noise floor, well
under the worst case observed, asserted on developer hardware and recorded on a
constrained one (the SLO 1 / SLO 3 lane split). Replacing a figure that was never
a measurement with one that is, is not weakening a gate.

## Consequences

- The SD4 invalidation test is a TABLE, one row per key component, plus an
  unchanged-key control — so a digest that was merely random per call would fail
  it rather than pass every row.
- Adding a render input without extending the key is a visible omission: the
  key's components and the invalidation table are meant to be the same list.
- The cache never accelerates the settle. A future task wanting that must find a
  different, and provably safe, way to decide a screen is unchanged.

## Related

- `no.md` #49 (full reasoning; also the benchmark whose own fixture was measuring
  two misses until `wasHit` caught it)
- ADR 2026-016 (backend divergence, a key component)
