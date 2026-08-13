# Working Principles

This package computes deterministic graph geometry. Preserve these principles
when designing APIs, implementing algorithms, writing documentation, or adding
examples.

## Keep the boundary geometric

- Accept the structural and spatial facts needed for layout.
- Return node positions, edge routes, bounds, and useful structural results.
- Do not add rendering, styling, text measurement, persistence, or UI concerns.
- Treat node sizes as real input. Do not assume nodes are dimensionless points
  at the public boundary.

## Design from the caller's meaning

- Group layouts by what the caller knows about the input: a hierarchy, a
  directed flow, a general graph, or a graph with domain rules.
- Put data only where it is meaningful. Do not add fields that most layouts
  silently ignore.
- Prefer a type that makes an invalid structure impossible over code that
  accepts a weaker structure and checks it later.
- Keep input and output index-aligned. Node results follow node input order;
  edge results follow edge input order.

## Add algorithms deliberately

A public algorithm must provide at least one of:

- a meaningfully different reading of the input;
- a material quality-versus-cost choice; or
- a geometric guarantee that settings cannot express.

Do not expose a second name merely for a different internal heuristic. Do not
publish placeholder algorithms to complete a taxonomy. Names such as `exact`
must state precisely what is optimized and what limits the search.

Algorithms may share phases and solvers. Reuse is especially desirable when
two layouts differ only in projection, constraints, routing, or initialization.

## Use plain language publicly

- Public names describe what callers provide or accomplish: `Input`,
  `Settings`, `Problem`, `Result`, `prepare`, and `layout`.
- Do not require callers to know an implementation technique to use the
  default path.
- Keep terms of art such as witness, canonicalization, feedback arc,
  majorization, virtual node, and coarsening internal unless public
  documentation explains why the concept matters to the caller.
- Use one term for one concept across families. In particular, keep units,
  direction, gaps, tolerances, seeds, and position hints consistent.
- Prefer the shortest API that remains unambiguous in generated Roc docs.

## Separate preparation from layout when it earns its cost

The conceptual lifecycle has three parts:

1. Check and normalize family input.
2. Prepare algorithm-specific reusable data.
3. Produce a layout.

The public API may combine the first two into `prepare`. Do not expose another
lifetime merely because it exists internally.

- Preparation is the only source of domain failure; one-call `layout` may
  return those same preparation problems.
- Report all independent input and settings problems in one result.
- Never silently clamp invalid values, repair references, or substitute index
  zero for missing data.
- A successful opaque prepared value proves that subsequent layout is total.
- Prepared work belongs to one exact input and its preparation settings. Any
  graph edit requires preparing again.
- Inputs that only select a particular solve, such as a random seed or starting
  positions, belong to layout rather than preparation.
- Inputs that affect validation or reusable derived structures belong to
  preparation.
- Provide a one-call `layout` operation for the common case. It must be
  equivalent to preparing and then laying out the prepared value.
- Do not force a two-step ceremony on callers who retain nothing.

## Respect the module boundary the compiler enforces

- Only a module's namesake type is visible to importers. Every public
  surface, including witness types, is reached through associated items or
  delegations on the namesake.

## Keep internals precise and composable

- Use technically correct algorithm names internally even when the public API
  uses simpler language.
- Express layout as pure phases with explicit inputs and outputs so phases can
  be tested and reused independently.
- Keep public family modules small. Internal ranking, ordering, projection,
  routing, and data-structure helpers must not leak into generated API docs.
- Precompute only work that is valid to reuse. Do not move most of a one-shot
  layout into preparation merely to preserve the appearance of a lifecycle.
- Design hot data around flat, deterministic, index-addressed structures.

## Protect performance by construction

The complexity budgets in `design.md` apply to native behavior, not merely to
the apparent source algorithm. Roc ownership, builtin implementations, and
stack use can change the observed cost. Preserve these rules in hot paths:

- Prefer flat parallel lists, offset tables, and source-indexed arrays over
  nested growing lists. Replacing one inner list in `List(List(a))` can copy
  the outer list; repeatedly doing so can turn linear construction quadratic.
- Preallocate index-aligned output when its final length is known. Fill it by
  proven in-bounds index instead of growing it and later restoring source
  order.
- Treat the fallback of `List.set` as part of ownership design. A fallback
  such as `list.set(index, value) ?? list` keeps the old list reachable and can
  force a full copy on every update. When validation or construction proves
  the index is in bounds, use an unreachable fallback that does not retain the
  old list, conventionally `?? []`, and state or test the invariant. Never use
  this convention when failure is actually possible.
- Do not assume a list threaded through a record-valued `fold` remains unique.
  If telemetry shows repeated full-list traffic, isolate the fold. For bounded
  traversal state, a local `var`/`for` loop or a single intrusive flat table
  may express ownership more reliably while keeping the enclosing phase pure.
- Use a queue or explicit work list for graph traversal and deep structures.
  Do not retain a node-sized state array through one recursive call per depth,
  and do not rely on the native stack for a supported scale target.
- For depth-indexed summaries such as contours, share persistent tails and
  carry lazy offsets when possible. Do not map or concatenate the complete
  remaining depth at every ancestor; a chain must not materialize
  `1 + 2 + ... + n` intermediate entries.
- Know the cost of builtins on the pinned compiler. In particular, the current
  `List.sort_with` chooses the first item as its quicksort pivot and allocates
  both partitions, so sorted, reverse-sorted, and equal-key inputs can be
  quadratic. Before sorting a hot list, consider whether its producer already
  guarantees order, add a linear monotonic fast path when appropriate, or use
  a deterministic index/table algorithm with a justified bound.
- Build reusable structural indices once per phase. Maintain inverse maps or
  incident-edge tables across candidate evaluations, compute local deltas, and
  avoid rebuilding global positions or rescanning every edge for a local
  change.
- Skip work that cannot affect geometry, such as sorting a singleton ring or
  materializing a candidate state before knowing the candidate is accepted.
- Use deterministic structures. If a hash table's seed or iteration order can
  vary, do not let it influence geometry, output order, allocation telemetry,
  or tie-breaking; prefer a fixed index-addressed table when practical.

When changing a hot path:

- start from a native optimized benchmark with at least three increasing sizes
  and one control that distinguishes the suspected phase;
- compare elapsed time, allocation calls, requested bytes, and peak live bytes
  separately — linear allocation calls with quadratic requested bytes usually
  indicates repeated large copies, while quadratic time with linear bytes
  points elsewhere; requested bytes measure cumulative allocator traffic, not
  resident memory;
- use zero-work or phase-level controls before naming a root cause, and record
  whether the original hypothesis was confirmed, narrowed, or refuted;
- test adversarial producer orders, especially sorted, reverse-sorted,
  equal-key, deep, wide, disconnected, and dense inputs as applicable;
- preserve result bits, source-index alignment, determinism, and all degenerate
  cases while optimizing; and
- retain at least three practical rungs in `benchmarks/cases/scale.jsonl` after
  the fix, extending the ladder only as each preceding rung completes reliably.

Keep current measurements, compiler-specific observations, and investigation
status in performance notes such as `TODO_INVESTIGATE_PERF.md`; keep only these
enduring practices in this file.

## Preserve totality, determinism, and numerical safety

- Every well-typed, successfully prepared input has a defined result, including
  empty graphs, isolated nodes, self-loops, parallel edges, and disconnected
  components where the family permits them.
- Iterative work has a hard bound as well as any convergence test.
- Finite accepted input produces finite output. No NaN or infinity may escape.
- Identical package version, input, settings, and layout arguments produce the
  same bits.
- Iterate and sort deterministically. Use stable source indices as final
  tie-breakers.
- Randomness comes only from an explicit seed with a fixed default.
- Return meaningful work already computed by the algorithm, such as node
  layers or edges drawn against the flow, instead of making callers recompute
  it.

## Treat documentation as the API

- `roc docs` is the authority for what public users can discover.
- Public module documentation must be self-contained. Do not refer to local
  design files, issue trackers, private notes, or implementation plans that are
  unavailable in published docs.
- Lead with when to use an operation and what visible effect its settings have.
  Put mathematical or implementation terminology after the plain-language
  explanation when it adds value.
- Keep TODOs and engineering plans out of public-facing module comments.
- Keep the README user-facing: purpose, supported use, a minimal example, a
  complete example link, and essential setup or development commands. Put
  architecture rationale and future plans elsewhere.
- Examples use the real public API. Do not maintain a separate illustrative API
  that happens not to compile.

## Verify the contract, not only the geometry

For a public API change or new algorithm:

- format every changed Roc file;
- run package checking and tests;
- build and execute at least one NATIVE binary exercising the changed path —
  the interpreter and native backend can disagree, so `roc check` plus
  `roc test` alone do not prove the built artifact correct;
- give every new algorithm a fuzz target asserting its contract (totality,
  source alignment, determinism, and its family-specific invariants), and
  distill every corpus crash into a permanent `## fuzz regression:` expect;
- check affected examples and run at least one end-to-end example;
- generate `roc docs` and inspect the exposed names, types, and prose;
- confirm internal helpers and unavailable references do not appear there;
- test aggregated validation problems;
- test empty and degenerate inputs;
- test deterministic output and source-index alignment;
- test that one-call layout equals prepare followed by layout;
- test that successfully prepared layout cannot fail; and
- run `git diff --check`.

If the full repository task cannot complete because the installed Roc compiler
does not match the pinned version, still run the individual checks that are
available and report the version mismatch explicitly.

## Parallel work

When several agents or sessions work concurrently:

- Partition by strict file ownership: each worker modifies exactly the files
  assigned to it and nothing else.
- Per-file testing is the isolation boundary: `roc test package/Foo.roc`
  compiles only that file's import closure, so a worker's runs cannot be
  broken by a sibling's in-flight edits as long as ownership is disjoint and
  shared dependencies are finished first.
- Land shared contracts (types, module APIs) before fanning out consumers of
  them; the integrator alone edits shared manifests and call sites that span
  ownership boundaries.

## Evolve from evidence

- Keep APIs provisional until an end-to-end implementation and example prove
  them.
- Prefer one complete exemplar over several inconsistent scaffolds.
- Let executable experience and generated documentation correct the design.
- When implementation evidence changes a principle or lifecycle, update the
  design guidance in the same change.
- Preserve enduring constraints here; keep current status, temporary migration
  notes, and task lists elsewhere.
