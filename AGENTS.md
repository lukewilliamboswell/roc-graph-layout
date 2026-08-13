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

## Evolve from evidence

- Keep APIs provisional until an end-to-end implementation and example prove
  them.
- Prefer one complete exemplar over several inconsistent scaffolds.
- Let executable experience and generated documentation correct the design.
- When implementation evidence changes a principle or lifecycle, update the
  design guidance in the same change.
- Preserve enduring constraints here; keep current status, temporary migration
  notes, and task lists elsewhere.
