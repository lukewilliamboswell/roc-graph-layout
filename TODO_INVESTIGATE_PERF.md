# Performance hypotheses to investigate

## Mermaid theme and messy-label baseline (2026-10-28)

Native optimized measurements on macOS arm64 with
`nightly-2026-10-26-3c0fffe`, using the vendored allocation-counting platform.
`package-mermaid/measure_diagrams.roc` constructs a chain with extra forward
dependencies and long node/edge labels before starting measurement. Each row
below is one fresh process, so timings are indicative rather than a statistical
comparison. Requested bytes are cumulative allocator traffic, not RSS.

| Path | Nodes | Time | Allocation calls | Requested bytes | Peak extra bytes |
|---|---:|---:|---:|---:|---:|
| zero work | 12 | 0.001 ms | 0 | 0 | 0 |
| parse only | 12 | 2.12 ms | 245 | 104,266 | 26,651 |
| recorded Mermaid sizing/drawing | 12 | 61.38 ms | 51,030 | 4,409,847 | 137,445 |
| recorded Mermaid sizing/drawing | 24 | 313.56 ms | 154,459 | 13,343,005 | 301,333 |
| recorded Mermaid sizing/drawing | 48 | 1,316.80 ms | 519,581 | 45,320,230 | 631,037 |
| themed sizing/drawing | 12 | 44.66 ms | 51,178 | 4,365,735 | 137,735 |
| themed sizing/drawing | 24 | 321.50 ms | 159,770 | 13,618,745 | 301,923 |
| themed sizing/drawing | 48 | 1,884.92 ms | 538,160 | 46,285,978 | 632,227 |

The themed path changes wrapping and line spacing, so it intentionally changes
geometry and is not a performance optimization. The recorded comparison path
retains its original defaults. A repeated 12-node recorded-path control in the
second executable measured 61.56 ms with identical allocator traffic.

The controls narrow the superlinear growth to work after parsing; they do not
identify a particular layout, text-measurement or drawing phase as its cause.
No speedup claim is made. Keep these three practical sizes when investigating
the new path; existing scale ladders in `benchmarks/cases/scale.jsonl` remain
unchanged. Further phase-level controls are needed before changing a hot loop.

Reproduce with `roc build --opt=speed package-mermaid/measure_diagrams.roc
--output=/tmp/measure-diagrams`, then run `/tmp/measure-diagrams draw 12`,
`themed 12`, `parse 12`, or `zero 12`; repeat the drawing paths at 24 and 48.
These measurements precede the final per-shape padding and rounded-attachment
corrections and do not measure the public SVG serialization/view-bounds pass.

These are investigation leads, not established root causes. Each hypothesis is
backed by allocation telemetry from the performance harness and points to code
whose behavior could explain the observation. Confirm or reject a hypothesis
with a focused benchmark before changing the implementation.

The measurements below were taken on macOS arm64 from commit `713c912`, using
the pinned 2026-08-13 Roc nightly, an optimized (`--opt=speed`) benchmark
binary, and one fresh process per sample. Times are useful for scale trends but
will vary by machine. Allocation counts and requested-byte growth are the more
important signals here.

## Routing-quality pipeline control (2026-08-14)

Native optimized `route run generated disjoint` measurements after flexible
portal assignment, bounded joint sweeps, and lane nudging:

| edges | elapsed | allocation calls | requested bytes | peak extra bytes |
|---:|---:|---:|---:|---:|
| 100 | 7.0 ms | 717 | 2.62 MB | 30.8 KB |
| 300 | 31.5 ms | 2,117 | 31.4 MB | 83.6 KB |
| 1,000 | 233.9 ms | 7,017 | 371.3 MB | 279.6 KB |

The disjoint control confirmed bounded live memory and roughly linear
allocation-call growth, but cumulative requested bytes remain superlinear.
Replacing per-endpoint side-bucket reconstruction with flat node-side count and
rank tables reduced the 1,000-edge control from 9,015 to 7,017 allocation calls
and from 250.8 ms to 233.9 ms; it did not materially change requested bytes.
That narrows the remaining traffic to repeated route/segment list construction,
including the current lane peer scans, rather than portal counting. A future
phase-level control should isolate nudging from visibility routing before naming
the dominant source.

## Reproducing the measurements

Put the Roc nightly under investigation on `PATH` as `roc` (the measurements
above used `nightly-2026-08-13-2fdd90e`), build the harness by running its
smoke suite, then invoke the cached binary directly:

```sh
blueprint run bench -- smoke --output benchmarks/results/investigate-smoke
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

**Status (2026-08-14): partially refuted, then resolved.** A zero-polish
control retained 810,421 of the original 810,424 allocation calls at 800
nodes, disproving polish as the source of the observed quadratic allocation.
The dominant source was circular routing: `parallel_ranks` sent an edge list
with a long sorted prefix into Roc's first-pivot `List.sort_with`. A flat,
deterministic open-addressed pair table now computes parallel counts and
source-order ranks in linear requested memory, without the per-process hash
seed and variable allocation behavior of `Dict`.

The polish hypothesis did identify real secondary work. Seat positions are now
maintained across a round, incident edge indices are prepared once, and a
candidate swap is scored virtually so rejected candidates do not copy the
node-sized seat map. At 800 nodes these changes together reduce the native case
from 869 ms, 810,424 allocation calls, and 133,175,304 requested bytes to about
80 ms, 8,826 calls, and 900,401 bytes. Requested memory is linear through the
10,000-node rung (11,250,401 bytes); crossing comparisons remain quadratic, as
expected for the polish heuristic. Circular tests, its fuzz contract, and the
native smoke suite pass. A 1,000/3,000/10,000-node ladder is now in the scale
suite.

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

**Status (2026-08-14): original hypothesis partly refuted; broader issue
confirmed and resolved.** Preallocating the outer ring list and changing its
updates did not materially affect the path ladder. The largest initial cost
was shared routing: source-ordered path edges hit the quadratic case of Roc's
first-pivot `List.sort_with` in `EdgeRoutes.parallel_ranks`. A deterministic
flat pair table now computes counts and source-order ranks without sorting.

After removing that noise, two genuine nested-state costs remained. Component
members were accumulated by repeatedly replacing a growing inner list, and
BFS carried node-sized distance and queue lists through one recursive wave per
path depth. Component membership now uses flat offsets and members. BFS uses
an imperative, bounded intrusive queue whose one flat entry list stores both
distance and next-queue links; this is important on the pinned compiler,
because the equivalent record-threaded functional fold copied the entry list.
Singleton rings also skip meaningless median reordering, while wider rings
reuse one node-indexed fraction table per sweep.

At 3,000 nodes, native runtime fell from 13.5 seconds to about 46 ms and
requested bytes from 1,140,724,128 to 3,784,799. The path remains linear in
requested memory through 30,000 nodes (36,641,183 bytes, about 0.64 seconds).
The current recursive ring discovery has a separate native stack limit before
100,000 nodes, so the committed scale ladder is 1,000/3,000/10,000/30,000.
Radial, shared path, fuzz-contract, and native smoke tests pass.

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

## H9: Layered layout is superlinear in every phase, and routing dominates

**Status (2026-10-24): confirmed; layered phases resolved, routing open.**
Measured on Linux x86_64 with nightly `2026-10-23-18478ff`, native
`--opt=speed`, one fresh process per sample. Fixture `dag` (new in
`benchmarks/Generators.roc`) is a flowchart-like DAG: every node hangs from
one of the four previous nodes, every third node also joins from one up to
twelve back, so edges span several layers (n nodes, about 1.3 n edges).

**Hypothesis.** Ranking (`grow_weighted_forest`, `improve_weighted_ranks`)
rescans every edge per step. **Confirmed but narrowed**: ranking was cubic,
yet at the sizes callers reported (Mermaid flowcharts of 20–160 nodes) the
orthogonal router accounted for about 99% of `Layered.layout`.

**Phase-level control.** A scratch copy of the package exposed a probe that
runs the pipeline up to a named phase; each phase's cost is the difference of
cumulative prefixes. Before (cumulative elapsed, `dag`):

| n | orient | +rank | +chains¹ | +order | +place | +finish² | +route (0 sweeps) | +route (4 sweeps) |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 80 | 0.6 ms | 3.4 ms | 3.8 ms | 9.4 ms | 16 ms | 40 ms | 1.0–1.6 s | 3.2–4.6 s |
| 160 | 4.6 ms | 31 ms | 39 ms | 56 ms | 68 ms | 171 ms | 7.2–11 s | 21–39 s |
| 320 | 24 ms | 229 ms | 259 ms | 314 ms | 357 ms | 802 ms | — | — |
| 640 | 155 ms | 3.4 s | 3.2 s | 3.7 s | 4.4 s | 8.6 s | — | — |

¹ includes `constrain_ranks`. ² `finish` re-runs preparation, then the second
ordering, coordinates, routes through chains, and hint projection.

After (same probe; ranking, orientation and chains are now negligible):

| n | +rank | +chains | +order | +place | +finish | +route (0 sweeps) |
|---:|---:|---:|---:|---:|---:|---:|
| 160 | 1.2 ms | 1.0 ms | 15 ms | 25 ms | 74 ms | 10.9 s |
| 640 | 3.7 ms | 3.8 ms | 89 ms | 131 ms | 361 ms | — |
| 1,280 | 8.6 ms | 8.2 ms | 205 ms | 305 ms | 815 ms | — |
| 2,560 | 19 ms | 19 ms | 406 ms | 647 ms | 1.75 s | — |

Root causes, each fixed with identical result bits:

- *Cycle breaking* (`orient_edges`) recomputed every vertex's degrees by
  scanning all edges for each of n steps: O(n²·m). Acyclic input (checked by
  Kahn's algorithm) provably keeps every edge; cyclic input uses heaps with
  lazy deletion for the first sink, first source and best score.
- *Ranking*: longest-path initialisation ran n Bellman-Ford passes; tight-tree
  growth rescanned all edges and remapped all ranks per added node; every
  network-simplex pivot recomputed each tree edge's side by n-pass label
  propagation and its cut value by a full edge scan, O(n·m) per tree edge.
  Now: topological longest path; Prim-like growth with two heaps keyed by
  slack plus a lazy tree offset; per pivot one postorder numbering (O(1)
  side tests), subtree sums of net node inflow for all cut values, one edge
  scan for the entering edge. Cut values are exact for whole weights; a
  fractional cut value within the rounding bound of zero is recomputed in
  the reference summation order. `normalize_ranks` used n propagation passes.
- `constrain_ranks` ran `(n + rules + 1)(n + 1)` relaxation passes even with no
  rules (and materialised that index list): now stops at the fixed point.
- `group_by_rank` filtered all nodes once per layer; virtual chains and the
  ordering phase's crossing count, sweeps and transpose scanned every edge per
  node or per layer and built node-sized tables per layer. Ordering now works
  on a flat layer-major list with edge-index adjacency (Fenwick-tree crossing
  counts, two-pointer swap deltas, a stable merge sort instead of first-pivot
  quicksort).
- Brandes-Köpf: conflict marking compared all segment pairs, neighbour lookup
  scanned all edges per node, conflict lookup scanned the conflict list, and
  compaction ran n relaxation passes over all constraints: O(n²). Now prefix
  maxima mark conflicts, adjacency finds neighbours, conflicts are per-edge
  flags, and compaction is one topological pass (the same fixed point).
- `enforce_precedences` ran `len²` empty passes per layer with no rules, and
  `run` repeated the preparation's ordering when no hints or rules apply.

Bit identity was checked natively against the original package on 3,400
random graphs (cycles, self-loops, parallel edges, integer and fractional
weights, minimum spans, centred and end labels, all four directions, with and
without routing sweeps) plus the examples (`tests/examples.json`); all
identical.

**Harness caveat.** The benchmark host uses Zig's `DebugAllocator`, which
page-faults on most allocations. For `straight` `dag` at 10,000 nodes,
`perf stat` shows 0.46 s user and 4.2 s system time of 4.75 s elapsed; for
`dense` at 1,000 nodes 0.50 s user of 6.07 s. Elapsed time in this harness is
therefore dominated by allocation count; compare `alloc_calls` and user time
before reading elapsed time as computation.

**Remaining.** The orthogonal router (`Route.layout`) is superlinear and is
about 99% of `Layered.layout` with default routing: `dag` 160 nodes, routing
with `max_sweeps: 0` takes 10.8 s of 10.9 s. Reproduce with
`"$BENCH" layered sweepless generated dag 160 0` against
`"$BENCH" layered straight generated dag 160 0` (the `layered-dag-routed`
scale series uses default sweeps at 20/40/80 nodes). `Settings.routing:
Straight` skips it. The layered phases still allocate about 80 times per
node (small per-node lists), which this harness magnifies.

**Guards.** `package/fuzz_layered_scaling.roc` builds a motif graph from the
fuzz bytes, repeats it 1 and 8 times, and bounds each phase's allocations per
unit of input (cycle breaking, ranking, chain splitting, median and average
sweeps, swap polish, crossing count, placement), plus `expect_no_leaks!` per
phase. It found two things: network-simplex exchanges allocated fresh work
lists, so ranking allocations followed the exchange count (now allocation-free
per exchange; the exchange count itself is the reference sequence's and is
input-dependent), and ranking can interleave copies so that the split graph
grows faster than the copy count (bounds now use the split graph's size).
With the 2026-10-23 nightly, `expect_no_leaks!` reports one outstanding
allocation for a whole `LayeredOrder.order` call although its sweeps, polish
and count each pass, and the benchmark host's exit-time leak check finds no
leak for complete layouts; the target checks the parts.

Ladders after the change (elapsed in this harness):

| series | sizes | elapsed |
|---|---|---|
| `layered straight dag` | 1,000 / 3,000 / 10,000 | 0.38 / 1.33 / 4.75 s |
| `layered straight dense` | 300 / 1,000 | 1.65 / 6.26 s |
| `layered one_call bands` | 200 / 400 / 800 / 1,000 | 60 / 52 / 157 / 203 ms (was 49 / 185 / 996 / 1,649 ms) |

## H10: The orthogonal router searched the whole grid for blocked legs

**Status: root cause confirmed and resolved in two stages; two adversarial
fixtures remain quadratic.** Measured natively (`--opt=speed`, nightly
2026-10-23-18478ff, x86_64 Linux, one process per sample, machine under
heavy load from other jobs, so trust allocation counts and bytes more than
milliseconds).

**Hypothesis.** After Layered's ranking, ordering and placement became
near-linear, routing dominated: a 160-node flowchart DAG spent ~7.2 s of
7.3 s in `Route.layout`, even with `max_sweeps: 0`.

**Phase controls** (a scratch-only `bench_phase` hook runs validation,
attachment resolution, parallel/fan ranks, initial routing, refinement and
lane nudging separately) showed that validation, resolution and nudging
were negligible and initial routing was everything. Requested bytes were
modest (49 MB at 160 nodes), so this was algorithmic CPU, not repeated
copies.

**Root cause (confirmed).** The fallback grid search for an L-blocked leg
(13 searches at 80 nodes, 20 at 160, 129 at 1,280 in the Layered DAG) was a
Dijkstra search over the whole Hanan grid (every obstacle edge line, ~5k to
~360k points) that: picked the next state by scanning every state; relaxed
moves by scanning every grid point with a visibility test against every
obstacle; and recounted every earlier route segment for every move. Each
search was roughly O(V^2 · B). `unique_values` and the point filter were
also quadratic and cubic in the obstacle count.

Secondary superlinear terms, each confirmed by reading and removed:
attachment-rule, boundary, membership, waypoint and guide lookups by
`find_first` per edge (O(E·rules)); the endpoint fan table (O(E^2));
group-portal buckets sorted once per use; per-edge obstacle lists rebuilt
from every node (O(E·N)); `path_cost` and refinement statistics rescanning
every earlier route (O(E·S)); lane nudging comparing every segment with
every segment and sorting per segment (O(S^2 log S)); duplicate-rule
validation comparing every pair of rules (Layered passes one guide per
edge). Hypothesis refuted: `EdgeRoutes.parallel_ranks`' record-threaded fold
did not copy its tables on this nightly (allocation calls stayed linear in
the fuzz control); it is now written with flat loops anyway.

**Stage 1 (bit-identical).** Exact replacements: the grid search now walks
only the visible runs of each expanded point with a binary heap and a
sparse state table, keeping the original first-appearance tie-break; flat
lookup tables; a uniform-grid index for obstacles and one for route
segments (with exact canonical-cell dedup so counts and float sums stay
identical); Fenwick-tree lane ranking; sort-based duplicate detection.
Results were compared bit for bit (FNV hash over every output float) on a
1,913-case corpus: 1,400 random inputs (groups, portals, shared ends,
labels, guides, waypoints, ellipses, seven settings variants), 352 router
inputs taken from Layered drawings, 33 full Layered drawings, 112 direct
fixtures and 16 larger Layered inputs (80 to 160 nodes). Identical on the
dev and `--opt=speed` native backends, and on 337 cases under the
interpreter. The 160-node DAG fell from 7.6 s to 94 ms. Remaining cost was
the exact exhaustive Dijkstra itself (2 million expanded states at 1,280
nodes) and refinement re-running it each sweep.

**Stage 2 (behaviour changes).** The search is now A* (Manhattan
heuristic) inside a window around the leg, widened twice before the whole
drawing, with an expansion budget per attempt; obstacles holding a leg's
end are ignored. Route DAG 1,280 nodes: 3.4 s → 0.22 s; deep 1,280:
timeout → 0.52 s; dag_cycles 1,280: 61 s → 0.33 s; requested bytes fell
by 50 to 250 times.

**Still open.** Two adversarial fixtures stay quadratic in both stages:
`shared_port` (every edge on one fixed port; refinement statistics and
lane counts are pairwise inside the bundle, ~1.2 to 2.5 times stage 1 under
load) and `wide` (one hub with every node on one side). `grid` (random
spans across a grid of nodes, every leg blocked) is dominated by windowed
searches and refinement re-routing. Refinement still re-routes every edge
with any crossing or overlap each sweep, so very crossing-heavy inputs pay
up to `max_sweeps` times the initial cost.

**Reproduce.** The scratch harness (`scratchpad/route/bench-*`) adds
`route` and `phase` modes over the Layered fixtures; the committed harness
can reproduce the Layered ladder with:

```sh
for n in 320 640 1280; do "$BENCH" layered one_call generated dag "$n" 0; done
```

Phase-level guards are now fuzz targets with allocation-growth bounds:
`fuzz_route_search` (A* against the exhaustive reference), `fuzz_route_index`,
`fuzz_route_lanes`, `fuzz_route_ports` and the whole-router scaling property
in `fuzz_route`.

Compiler observation: on the 2026-10-23 nightly a native build that divides
by `n` inside a callback that never runs may assume `n != 0` and fold
`n == 0` away (roc-lang/roc#12556); the fuzz and corpus generators guard
their divisors with `.max(1)`.

## Resolved: shared fixed-port ranking repeated sorts

**Finding.** Ranking each endpoint by filtering and sorting its complete peer
group once per edge produced pathological shared-port behavior. In the
optimized native benchmark, 100 edges took about 338 ms and requested 166 MB;
300 edges took 7.78 s and requested 4.78 GB. The original hypothesis was
confirmed: repeated peer-list allocation plus the pinned compiler's sort made
this substantially worse than the surrounding routing work.

**Change.** Rank is now computed by one deterministic peer scan per endpoint,
using the same ordering and stable edge-index tie-breaker without allocating or
sorting a bucket. The same native fixture now measures about 22.6 ms / 7.1 MB
at 100 edges, 133 ms / 86.2 MB at 300, and 848 ms / 1.02 GB at 1,000. The
remaining requested-byte growth is still worth monitoring, but all three
practical rungs complete reliably and remain in `benchmarks/cases/scale.jsonl`.

The fixture also exposed two narrow inferred integer accumulators: attachment
slots overflowed at node index 64 and route crossing telemetry overflowed at
64 interactions. Both are now explicitly `U64`, and the 100-edge smoke case
guards the native path.

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
   `blueprint run bench -- compare BASELINE/samples.jsonl CANDIDATE/samples.jsonl`
   on compatible environments.
7. Promote the direct diagnostic ladder into `benchmarks/cases/scale.jsonl`
   once its bounded rungs run reliably; then grow it toward the stated scale
   target in later changes.

## Mermaid framing oracle correction (2026-10-28)

The oracle exposed a correctness error in final framing: every path was padded
by four stroke widths, even when its joins were straight, smooth, or right
angles. A 4px shadow plus that maximum envelope enlarged normal state views by
4px and shifted styled flowchart comparisons. The correction computes actual
miter extents from adjacent segment tangents, with the SVG miter-limit fallback.
It retains conservative cubic control hulls and includes explicit thick strokes.
This is a framing correction, not a layout optimization.

Native optimized phase controls (`package-mermaid/measure_framing.roc`, compiler
2026-10-26-3c0fffe, arm64 macOS; three runs per size, median elapsed):

| Rectangles | Before ms | After ms | Alloc calls (both) | Requested bytes (both) | Peak live bytes (both) |
|---:|---:|---:|---:|---:|---:|
| 100 | 1.806 | 2.220 | 403 | 17,552 | 46,760 |
| 300 | 5.203 | 6.524 | 1,203 | 51,152 | 131,720 |
| 1,000 | 17.393 | 18.954 | 4,003 | 168,752 | 439,160 |

Zero-work controls at all three sizes exclude parsing, text measurement and
layout, and confirm those phases cannot explain this observation. Allocator
traffic and peak live bytes are unchanged; additional tangent arithmetic costs
CPU time. The hypothesized excessive final envelope was confirmed separately
from performance. Raw telemetry is in `/tmp/mermaid-framing-{before,after}.json`
for this session; commands above reproduce the measurements without fixtures.

## SVG vertical glyph bounds (2026-10-28)

The remaining state pixel discrepancy was traced to source font data, not a
fixture offset: Inter glyph `g` has y_min=-442 at2048units/em, so at14px its
3.021484375px descent exceeds the rounded logical descent3. The reference
measures17.021484375px for Checking/Changes; legacy TextMeasure used17.
`block_svg` unions raw vertical glyph extents with logical metrics in the same
shaping pass, including all lines when spacing is small. Existing `block` and
`block_advance` preserve their original observations and allocator traffic.

Native optimized ClassTextBench before/after (compilerOct26, arm64macOS,
labels generated before measurement, elapsed single observations in ms):

| Labels | Old block before/after | Advance before/after | SVG mode | Calls (all modes) | Requested B (all) | Peak live B (all) |
|---:|---:|---:|---:|---:|---:|---:|
|100|28.168/30.739|26.951/30.291|29.571|15,200|2,562,660|5,758|
|300|81.943/92.871|83.292/88.142|88.922|45,600|7,743,860|10,623|
|1000|289.265/295.930|277.614/300.652|292.303|152,000|25,878,060|27,423|

Zero controls allocate/request0, at1/1/2µs. SVG mode observes height as well
as width; elapsed values are not a speedup claim. The one-line benchmark is
unchanged by the subsequent all-row envelope regression. Raw session data:
`/tmp/mermaid-vertical-{before,after}.json`. The confirmed cause and the additive
mode preserve legacy Linux-style glyph-bound expectations while state callers
can select the actual SVG glyph envelope.
