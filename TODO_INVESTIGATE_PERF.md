# Performance hypotheses to investigate

These are investigation leads, not established root causes. Each hypothesis is
backed by allocation telemetry from the performance harness and points to code
whose behavior could explain the observation. Confirm or reject a hypothesis
with a focused benchmark before changing the implementation.

The measurements below were taken on macOS arm64 from commit `713c912`, using
the pinned 2026-08-13 Roc nightly, an optimized (`--opt=speed`) benchmark
binary, and one fresh process per sample. Times are useful for scale trends but
will vary by machine. Allocation counts and requested-byte growth are the more
important signals here.

## Reproducing the measurements

Set `ROC` to the compiler pinned by `.roc-version`, build the harness by running
its smoke suite, then invoke the cached binary directly:

```sh
export ROC=/private/tmp/roc-nightly-2026-08-13-2fdd90e/roc_nightly-macos_apple_silicon-2026-08-13-2fdd90e/roc
python3 benchmarks/run.py smoke --output benchmarks/results/investigate-smoke
export BENCH=benchmarks/.cache/layout-bench
```

Every direct invocation prints one JSON object. The fields used below are:

- `elapsed_ns`: time between the explicit measurement markers;
- `alloc_calls` and `realloc_calls`: calls through the Roc allocation boundary;
- `bytes_requested`: total bytes requested, including repeated allocation and
  reallocation of storage that is later released; and
- `peak_extra_bytes`: maximum additional live bytes during the measured region.

Run every size in a fresh process, as these loops do. Repeat a ladder when
comparing elapsed time. Allocation telemetry should be deterministic for an
identical binary and input. Do not interpret `bytes_requested` as RSS.

Some ladders below are intentionally not yet in `benchmarks/cases/scale.jsonl`.
That is not because they are unimportant: their current growth makes the
larger rungs too slow or memory-intensive for a routine scale run. Direct
commands document bounded reproductions while the hypotheses are open.

Follow-up: after improving an affected implementation, add successively larger
rungs to `scale.jsonl`. Start with sizes that complete reliably under the case
timeout, retain at least three sizes so the empirical exponent is meaningful,
and extend toward the committed targets only as each preceding rung becomes
practical. A timeout should stop later cases in the same series rather than
making normal benchmark runs unusable.

## H1: Force refinement loses unique ownership of node-sized lists

**Status (2026-08-14): narrowed and mitigated.** Focused rewrites of the
spring accumulator and position construction did not materially change
requested bytes, refuting those two suspected call sites. The dominant alias
was in `Quadtree.insert_at`: `List.set(...) ?? cells` retained the pre-update
flat cell store through recursive insertion and forced repeated copies. Using
an unreachable empty fallback preserved geometry while reducing the 3,000-node
star from 2,395,816,472 to 148,846,040 requested bytes (93.8%).

A phase benchmark then showed quadtree construction itself requested only
1,229,192 bytes at 3,000 nodes and 4,506,984 at 10,000. The remaining quadratic
traffic came from component position write-back: `acc.set(...) ?? acc` copied
the global position list for every member. Its index is proven in bounds, so an
unreachable empty fallback removes that alias. Together the fixes reduce the
3,000-node star to 4,822,040 requested bytes and about 14 ms, and the 10,000-node
star to 17,145,952 bytes. Allocation remained deterministic and the native
smoke suite passed. This confirms the general ownership mechanism, but narrows
it away from the originally suspected spring and iteration-position folds.

**Hypothesis.** A force refinement iteration repeatedly copies one or more
node-sized lists. In particular, the position fold both captures the original
`positions` list and threads `st.positions`, while the spring fold performs two
`List.set` operations per edge. One of these patterns may prevent unique
in-place updates.

**Observation.** One iteration on star graphs kept allocation-call growth close
to linear but made requested bytes approximately quadratic. At 3,000 nodes it
requested about 2.28 GB while peak extra storage was only about 2.4 MB. Stress
layout on a path is a useful control: at 10,000 nodes it made 22 allocation
calls and requested about 2.1 MB.

**Reproduce.** `place_prepared` excludes force preparation, and the harness
sets `max_iterations` to 1:

```sh
for n in 100 300 1000 3000; do
  "$BENCH" force place_prepared generated star "$n" 1
done

for n in 100 300 1000 3000 10000; do
  "$BENCH" stress place_prepared generated path "$n" 1
done
```

**Evidence that would support it.** Force `bytes_requested` grows near `n^2`
while `alloc_calls` and `peak_extra_bytes` remain near-linear. A microbenchmark
of position integration or spring accumulation should localize which list is
copied. Refute it if isolated folds request only linear bytes and another phase
accounts for the growth.

Relevant code: `package/ForceLayout.roc`, especially `one_iteration`,
`spring_disp`, the position fold, and `coincides`.

## H2: Dense overlap removal compounds quadratic constraints with global merges

**Status (2026-08-14): confirmed and mitigated.** The dominant cost occurred
before block merging. `Overlap.remove` emits its dense pair constraints in the
same canonical order that `Solver.project` requires, but `project` sorted them
again. The built-in `List.sort_with` uses its first item as the quicksort pivot,
so this already-sorted list of O(n^2) constraints triggered O(n^4) sorting work.
A linear sortedness check now preserves canonical input directly and retains
sorting for other callers. At 80 piled-up nodes this reduced the native case
from 22.1 seconds and 825,592,880 requested bytes to 2.64 ms and 745,144 bytes.
The formerly unattempted 160-node case completes in 6.3 ms. Dense constraint
construction and solver work remain at least quadratic, as expected; their
bounded 320/640/1,000-node ladder is now practical in the scale suite.

**Hypothesis.** A pileup creates quadratic pair constraints, after which every
solver merge scans all constraints and variables and repeated sweeps revisit
the full constraint list. Persistent list updates may add further copying, so
dense cases grow substantially worse than the pair-generation lower bound.

**Observation.** A pileup grew from roughly 305,000 allocations and 45 MB
requested at 40 nodes to 4.99 million allocations, 787 MB requested, and 23.8
seconds at 80 nodes. The 160-node case was not attempted after that growth.

**Reproduce.** Start small; the final case can take tens of seconds:

```sh
for n in 10 20 40 80; do
  "$BENCH" overlap run generated pileup "$n" 0
done
```

For a separated-input control:

```sh
for n in 100 300; do
  "$BENCH" overlap run generated grid "$n" 0
done
```

**Evidence that would support it.** Doubling a dense pileup increases allocation
calls and requested bytes much faster than 4x, with profiles attributing work
to constraint-wide folds in block merging and sweeping. Refute or narrow it if
constraint construction alone explains the growth.

Relevant code: pair generation in `package/Overlap.roc` and `merge_blocks`,
`sweep`, and repeated sweeping in `package/Solver.roc`.

## H3: Pack copies the growing placement list

**Status (2026-08-14): refuted and resolved.** The placement accumulator keeps
unique ownership; after the actual fix, a 10,000-box run performs only three
allocation calls. The triangular allocation count came from sorting instead:
equal boxes are mapped in ascending source-index order, which already matches
Pack's deterministic comparator, and the built-in first-pivot quicksort took
its quadratic worst case. A linear sortedness check now bypasses sorting for
canonical input while retaining it for arbitrary box orders. At 3,000 boxes
this reduced the native case from 21.2 seconds, 4,501,502 allocation calls, and
736,516,720 requested bytes to 0.13 ms, 3 allocation calls, and 508,664 bytes.
The new 10,000-box case completes in 0.31 ms with 1,576,120 requested bytes.

**Hypothesis.** `state.placements.append(...)` inside the record-valued fold is
not retaining unique ownership, causing a copy of the growing placement list
for each box.

**Observation.** At 1,000 equal boxes, Pack made about 500,502 allocation calls,
requested about 76 MB, and took 282 ms. The allocation count is strikingly
close to a triangular `n^2 / 2` pattern.

**Reproduce.** The 3,000-box case may take several seconds:

```sh
for n in 100 300 1000 3000; do
  "$BENCH" pack run generated equal "$n" 0
done
```

`compound` provides a useful comparison because its row-placement path does
not exhibit the same growth at smoke scale:

```sh
for n in 100 300 1000; do
  "$BENCH" compound run generated equal "$n" 0
done
```

**Evidence that would support it.** Allocation calls remain close to a
triangular sequence, and an isolated accumulator reproduces it. Refute it if
sorting or index-aligned result construction, rather than `append`, accounts
for the calls.

Relevant code: the `placed` fold in `package/Pack.roc`.

## H4: Deep tree contours cause quadratic memory traffic

**Status (2026-08-14): confirmed and resolved.** Two depth-proportional copies
compounded on chains. Every unary ancestor rebuilt both child contour lists,
and the downward pass recursed from inside a one-item child fold that retained
the prior growing output accumulators. Contours are now persistent spines:
unary parents prepend one entry while sharing the child tail, and multi-child
parents apply a lazy shift instead of mapping every depth. Unary flattening has
a direct tail path. Validation and bottom-up placement also use explicit flat
work lists, removing the separate native-stack failure on deep inputs; the
benchmark chain fixture is built leaf-first for the same reason. At 320 nodes,
tidy requested bytes fell from 7,796,608 to 204,856. Growth remains linear
through 10,000 nodes (6,955,368 bytes), and both tidy and radial layouts now
complete the 100,000-node chain target natively in under 1.1 seconds with
83–88 MB requested. Star geometry and the existing tree fuzz contract pass.

**Hypothesis.** Tidy placement materializes a contour proportional to subtree
depth at every ancestor. A chain therefore retains and reconstructs contours
of lengths `1 + 2 + ... + n`; radial tree layout inherits the same placement
phase. The recursive representation may present a separate stack-depth risk at
the committed 100,000-node scale.

**Observation.** On tidy chains, doubling from 80 to 160 to 320 nodes increased
requested bytes from about 0.52 MB to 1.95 MB to 7.44 MB. Radial tree chains
showed nearly identical requested-byte growth. Tidy stars, in contrast, showed
linear allocation counts and requested bytes through 10,000 nodes.

**Reproduce.** Keep the chain ladder modest until recursion and allocation
growth are addressed:

```sh
for n in 20 40 80 160 320; do
  "$BENCH" tree_tidy one_call generated chain "$n" 0
done

for n in 20 40 80 160 320; do
  "$BENCH" tree_radial one_call generated chain "$n" 0
done

for n in 100 300 1000 3000 10000; do
  "$BENCH" tree_tidy one_call generated star "$n" 0
done
```

**Evidence that would support it.** Chain `bytes_requested` grows about 4x per
doubling while the star control remains linear. Heap or call-site profiling
should point to contour `map`/`concat` construction. A threaded-contour
prototype should make the chain nearly linear before attempting 100,000 nodes.

Relevant code: subtree placement and contour merging in `package/Tree.roc`.

## H5: Layer transpose repeatedly rebuilds quadratic crossing data

**Status (2026-08-14): confirmed and mitigated.** Transpose polishing counted
every edge pair in both neighboring gaps before and after every candidate
swap. It now computes the exact before/after delta using only the two swapped
nodes' incident edges and constructs the swapped layer only when that delta is
an improvement. The reversed fixture exposed a second independent cost: its
median scores are reverse-sorted, which is the quadratic case for Roc's
first-pivot `List.sort_with`. Median sweeps now retain ascending scores, reverse
descending scores, and call the general sort only for unordered scores.

On the pinned native compiler, the 800-node case fell from 1.86 seconds and
340,843,007 requested bytes immediately before this change to 1.17 seconds and
53,880,543 bytes. All layered and layered fuzz tests, plus the native smoke
suite, pass. Other layered phases still make the overall bands ladder grow
quadratically; this change specifically removes the repeated full crossing
rebuild identified by H5. A bounded 200/400/800/1,000-node ladder replaces the
premature 10,000-node rung in the scale suite.

**Hypothesis.** `crossings_between` constructs full position and edge-pair
lists and performs a pair scan. `transpose_layer` invokes it before and after
each adjacent swap for both neighboring layer gaps, multiplying both work and
temporary allocation.

**Observation.** On reversed two-layer bands, doubling from 200 to 400 to 800
nodes increased requested bytes from about 10.4 MB to 40.6 MB to 170.7 MB.
Runtime increased from about 66 ms to 331 ms to 1.76 seconds.

**Reproduce.** The 800-node case takes around two seconds on the reference
machine:

```sh
for n in 50 100 200 400 800; do
  "$BENCH" layered one_call generated bands "$n" 0
done
```

**Evidence that would support it.** Requested bytes grow approximately
quadratically and profiles show repeated allocation in `crossings_between`
during transpose polishing. An incremental swap-delta implementation should
remove repeated full pair-list construction.

Relevant code: `crossings_between`, `transpose_layer`, and ordering sweeps in
`package/Layered.roc`.

## H6: Circular polish rebuilds global state for every candidate swap

**Hypothesis.** Circular polishing rebuilds the node-to-seat map for each seat
and uses a nested edge scan to compute crossings touching a swap. Repeating
that work before and after each candidate swap makes allocation at least
quadratic and computation potentially worse on chord-heavy graphs.

**Observation.** Cycle-with-chords fixtures made about 52,500 allocations at
200 nodes, 205,000 at 400, and 810,000 at 800. Requested bytes grew from about
7.7 MB to 31.2 MB to 127 MB, and the 800-node case took about 943 ms.

**Reproduce.** Seed zero is part of this fixture's deterministic chord pattern:

```sh
for n in 50 100 200 400 800; do
  "$BENCH" circular one_call generated cycle_chords "$n" 0
done
```

**Evidence that would support it.** Allocation calls and requested bytes grow
about 4x per doubling, with call-site profiles dominated by seat-map and
touching-edge construction. Maintaining seat positions and incident-edge
indices across swaps should materially change that slope.

Relevant code: circular ordering and polish helpers in `package/Graph.roc`,
especially `seats_of`, `crossings_touching`, and `polish_round`.

## H7: General radial layout copies its outer ring list on deep paths

**Hypothesis.** A path creates one singleton ring per node. Growing the outer
ring list with `acc.append(next.order)` and repeatedly updating it with
`acc.set(depth, reordered)` during median sweeps may copy a list whose length is
proportional to depth.

**Observation.** Radial paths requested about 1.4 MB at 100 nodes, 10.9 MB at
300, 120.6 MB at 1,000, and 1.09 GB at 3,000. The 3,000-node case took about
18.1 seconds and made 4.64 million allocations.

**Reproduce.** The largest case is intentionally slow:

```sh
for n in 100 300 1000 3000; do
  "$BENCH" radial one_call generated path "$n" 0
done
```

**Evidence that would support it.** Requested bytes and allocation calls remain
quadratic on singleton-ring paths. Isolating ring discovery from median sweeps
should reveal whether `append`, repeated outer-list `set`, or both dominate.

Relevant code: `expand_ring_orders` and `median_sweeps` in
`package/RadialLayout.roc`.

## H8: Metrics crossing count is a CPU scaling issue, not an allocation issue

**Hypothesis.** The nested segment-pair scan is quadratic in segment count, but
its inner loop allocates little. It will become a runtime hotspot at large
route counts without producing the dramatic allocation telemetry seen above.

**Observation.** From 100 to 3,000 all-crossing routes, allocation calls stayed
near one per route and requested bytes remained below 1 MB, while runtime rose
from roughly 0.34 ms to 22 ms.

**Reproduce.** This fixture intentionally makes every pair intersect:

```sh
for n in 100 300 1000 3000; do
  "$BENCH" metrics_crossings run generated all_crossing "$n" 0
done
```

**Evidence that would support it.** Runtime trends toward quadratic while
allocation counts and requested bytes stay near-linear. This should be
addressed with a sweep-line or inversion-counting algorithm, but allocation
micro-optimizations alone should not materially change the slope.

Relevant code: crossing measurement in `package/Metrics.roc`.

## Investigation discipline

For each hypothesis:

1. Save the complete JSONL baseline, compiler version, revision, OS, and
   architecture.
2. Add the smallest fixture or phase-level benchmark that distinguishes the
   suspected mechanism from neighboring phases.
3. Compare at least three sizes and judge the growth slope, not one elapsed
   time.
4. Check result observations and existing tests so a faster implementation
   does not change deterministic geometry or index alignment.
5. Record whether the hypothesis was confirmed, narrowed, or rejected before
   turning it into an implementation task.
6. After a fix, retain a bounded ladder as a regression benchmark and run
   `python3 benchmarks/run.py compare BASELINE/samples.jsonl CANDIDATE/samples.jsonl`
   on compatible environments.
7. Promote the direct diagnostic ladder into `benchmarks/cases/scale.jsonl`
   once its bounded rungs run reliably; then grow it toward the stated scale
   target in later changes.
