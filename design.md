# Roc Graph Layout Package — Design

## Scope and Boundary

### Guiding principle

The library computes **geometry**, not pixels. It answers "where should each
node and edge go?" and stops there.

Layout and rendering are different problems with different inputs, different
correctness criteria, and different rates of change. Layout correctness is
about structure — no unwanted overlaps, readable edge crossings, respect for
hierarchy or grouping. Rendering correctness is about appearance in a
specific medium — pixels, vector paths, terminal cells — and is bound to
whatever surface the caller happens to be targeting. Fusing the two forces
every caller to accept both concerns even when they only need one, and
forces the library to grow a rendering surface for every target its users
might have (vector graphics, a canvas, a terminal, print) rather than one
clean geometric contract that any of those can be built on top of.

Coupling also compounds: once layout code carries assumptions about a
specific output format, changing the format touches layout logic, and
extending layout logic risks breaking the format. Keeping the boundary
where the problem is naturally discontinuous — geometry in, geometry out —
keeps each side simple and independently testable, and lets one layout
engine serve any number of downstream renderers without modification.

Concretely: the core package has no concept of a drawing surface, no color,
no fonts, no label text rendering. It is pure computation over an abstract
graph, with no platform/host dependency — maximally reusable, easy to test
in isolation from any effectful concern, and consumable by any downstream
renderer without the renderer's choices leaking back into layout.

### In scope

#### Input model — the abstract graph

A description of nodes and edges carrying only what layout algorithms
need to reason about space and structure:

- `Node`: opaque id, size (width/height or bounding-box hint — required,
  see rationale below), optional fixed/pinned position, optional
  parent/group (for nested or compound graphs).
- `Edge`: source id, target id, optional weight/priority (affects rank
  assignment in Sugiyama-style layouts), optional routing hints (e.g.
  "must be orthogonal").
- `Graph`: directed vs. undirected, and structural shape where relevant
  (tree, forest, DAG, general graph) — algorithms differ in what they
  require or assume of the input (Reingold–Tilford requires a tree;
  Sugiyama assumes a DAG or needs cycle-breaking first).

#### The algorithm surface — what layout produces

Purely geometric output:

- Node positions (x, y), and any structurally meaningful byproduct worth
  exposing (e.g. Sugiyama layer/rank index).
- Edge routes: at minimum, straight lines implied by node positions;
  algorithms that do orthogonal or curved routing output a polyline or
  bezier control points per edge.
- Overall bounding box / canvas extents, useful for any consumer that
  needs to fit the result to a view.

#### Configuration — the algorithm's dials

Each algorithm family has its own parameters (spacing, iteration count or
convergence tolerance for force-directed, rank separation for Sugiyama,
etc.). A shared subset of spacing-related config should apply across
algorithms where meaningful, with algorithm-specific extensions layered
on top.

### Out of scope

- **Rendering or drawing in any format.** SVG/canvas/DOM/terminal output
  belongs in separate, downstream packages that consume this library's
  geometric output.
- **Interactivity** (drag-to-reposition, animated transitions between
  layouts). This is a consumer/UI concern. Related but distinct: producing
  *stable* layouts, where a small input change yields small position
  changes rather than a full re-layout, is a legitimate future algorithmic
  requirement, but it is about the algorithm's output stability, not about
  animating a transition.
- **Styling** — color, node shape beyond its bounding box, fonts, label
  text rendering.
- **Persistence or serialization format.** A Roc-native way to construct
  and inspect graph values is part of the data type itself, not an I/O
  concern.

### A boundary decision made explicitly, not by default

Node sizes are accepted as **required input**, not inferred and not
ignored. The alternative — treating nodes as sizeless points and leaving
spacing to a config constant — is simpler but produces lower-quality
layouts once nodes have real content: uniform spacing either wastes space
around small nodes or overlaps large ones, because it has no way to know
how much room a given node actually needs. Overlap-avoidance and
space-efficient packing are only solvable if the algorithm knows true
node extents at layout time. Retrofitting that knowledge later, after
algorithms have been built around sizeless points, means revisiting every
algorithm's core math; asking callers for sizes from day one avoids that
rework entirely, so this library requires them from the start.

## Requirements

[Scope and Boundary](#scope-and-boundary) fixes what the library is; this section fixes what it must
achieve inside that boundary. Nothing here is staged or provisional:
these requirements are the durable contract, and they change only when
the problem changes — new science about what makes drawings readable,
or a new kind of input callers can honestly provide — never as a
matter of implementation progress.

### Functional requirements

**F1 — Spec classes group input; algorithms provide readings.** There
is no universal layout algorithm because there is no universal way to
read a graph: a build pipeline is read as directed flow, an
organization as a hierarchy, a social network as clusters and bridges,
a protocol ring as a cycle. Each reading has its own correctness
criteria, and an algorithm can only optimize criteria it knows about.
The library therefore has a two-level surface. The outer level is a
small set of **spec classes**, grouped by what input the caller can
honestly provide: `Tree` (a hierarchy, given as one), `Layered` (a
directed graph read as flow, plus flow-specific edge data), `Graph`
(any sized graph), and `Constrained` (a graph plus domain rules).
Nested under each class are its **algorithms** — tidy and
radial drawing for trees; the layer-sweep pipeline for flow; force,
stress, circular, and radial placement for general graphs — each held
to the strongest practical method for its reading, argued in [Spec classes and their algorithms](#spec-classes-and-their-algorithms).
Alongside them sit placement-independent passes (component packing,
overlap removal, edge routing) that compose with any algorithm's
output ([Placement-independent passes](#placement-independent-passes)).

**F2 — The whole input domain is defined.** Algorithms of the `Graph`
class accept every well-formed graph: self-loops, parallel edges,
disconnected graphs, the empty graph, a single node. None of these are
errors; each has specified output ([Degenerate inputs and the failure posture](#degenerate-inputs-and-the-failure-posture)). Structural preconditions are
pushed into spec shape wherever possible — the tree class's spec is
recursive, so a non-tree cannot even be written ([Data model](#data-model)) — and where a
precondition cannot be shaped away, the algorithm absorbs it: layered
layout accepts any directed graph and breaks cycles itself, reporting
exactly which edges it reversed.

**F3 — Output is complete, not approximate.** Every node gets a
position, every edge gets a route, and the layout reports a tight
bounding box ([Scope and Boundary](#scope-and-boundary)). Structurally meaningful byproducts — layer index,
tree depth, connected-component id, the set of edges reversed to break
cycles — are returned, not discarded: consumers routinely need them (to
style by depth, to draw reversed arrowheads correctly), and recomputing
them downstream duplicates work the algorithm already did.

**F4 — Determinism, bit for bit.** Identical input and configuration on
the same package version produce identical output. Layouts are cached,
diffed, snapshot-tested, and embedded in documents; any nondeterminism
converts each of those uses into a source of noise. Algorithms remain
free to use randomized techniques — all randomness derives from an
explicit seed among the run arguments, with a fixed default ([Determinism and numerics](#determinism-and-numerics)).

**F5 — Zero-configuration quality.** Every algorithm must produce a
readable layout with default configuration and default run arguments on
graphs up to a few hundred nodes. Configuration exists to adapt output
to a context, never to make the default usable.

**F6 — Compound graphs.** Nodes may be grouped, groups may nest, and
edges may cross group boundaries; layout recurses through the nesting
([Placement-independent passes](#placement-independent-passes)). Grouping is its own spec class wrapping the others — a use of
the spec-composition architecture ([Data model](#data-model)), not a group field threaded
through every spec.

**F7 — Stability under re-layout.** Callers may supply
previous positions as hints; algorithms that can honor them minimize
movement, so a small change to the graph yields a small change to the
drawing. This is the output-stability requirement distinguished from
animation in [Scope and Boundary](#scope-and-boundary), and it exists
because diagrams live in documents and tools
where churn destroys the reader's mental map.

**F8 — Quality is measurable, in-library.** A public metrics module
scores any layout: crossing count, stress, bend count, area and aspect
ratio, minimum-separation violations, displacement against a previous
layout. "State of the art" must be falsifiable — by the library's own
regression suite and by consumers choosing between algorithms on
their own data.

### Non-functional requirements

**N1 — Purity and platform independence.** The package depends on no
platform and performs no effects; it is computation from values to
values. This makes the [Scope and Boundary](#scope-and-boundary) a hard requirement, and it is
what makes F4 cheap: with no ambient clock, randomness, or I/O, the only
way nondeterminism can enter is by explicit design error.

**N2 — Totality.** Every public function returns a defined result for
every input that type-checks. No panics, no hangs: every iterative
process carries a hard iteration cap alongside its convergence test, so
termination never depends on numerical luck ([Determinism and numerics](#determinism-and-numerics)).

**N3 — Complexity budgets.** Asymptotics are commitments, not
accidents: trees in O(n); layered layout near-linear per sweep with a
bounded number of sweeps; force and stress iterations in
O((n + m) log n) via approximation, never O(n²) per step at scale;
memory O(n + m) throughout. Practical targets: 10⁵-node trees, 10⁴-node
layered drawings, 10⁴–10⁵-node force/stress layouts ([Performance model](#performance-model)).

**N4 — Numerical robustness.** Finite inputs produce finite outputs. No
NaN or infinity ever escapes a public function; coincident positions,
zero-size nodes, and degenerate configurations are handled by explicit,
deterministic rules rather than by luck ([Determinism and numerics](#determinism-and-numerics), [Degenerate inputs and the failure posture](#degenerate-inputs-and-the-failure-posture)).

**N5 — Output compatibility policy.** Because consumers snapshot
geometry, geometric change is a compatibility event, tiered by semver:
patch releases reproduce layouts bit for bit; minor releases may change
geometry and say so; API shape breaks only on major (see the [output compatibility policy](#non-functional-requirements)).

**N6 — Documentation is part of the API.** Every configuration field is
documented by its visible effect on the drawing; every algorithm
documents when to choose it and what it optimizes. A layout library is
used by
people who are not layout specialists; the docs are the interface most
users actually program against.

### Explicit non-requirements

Beyond the [Scope and Boundary](#scope-and-boundary) exclusions: no automatic algorithm selection in the
core (a convenience layer could rank classes and algorithms per input
shape, but it belongs above the core); no dynamic/streaming graph
maintenance (stability hints, F7, cover the practical need without an
incremental-update API); no text or label measurement (callers
measure, the library only ever sees boxes); and no unbounded search:
where a problem is NP-hard, the library uses bounded-effort methods —
heuristics held to measured quality (F8), or exhaustive search behind
an explicit cap ([the layered class](#the-layered-class)) — because predictable cost is itself a
requirement.

## Design principles

Six commitments recur through every decision below; they are stated
once here.

**Plain data at the boundary.** Input is a record of lists; output is a
record of lists. No callbacks, no interfaces to implement, no builder
object to thread. Values can be constructed by literal, generated by
test code, stored, diffed, and shipped across any embedding boundary
with no ceremony. Behavior lives inside the library; only data crosses
the edge.

**Determinism is a contract, not an accident.** Purity makes
determinism available; the design makes it guaranteed: explicit seeds,
fixed iteration orders, and a deterministic tie-break rule at every
point where order could influence output ([Determinism and numerics](#determinism-and-numerics)).

**Parse, don't validate.** Wherever possible the spec's shape makes
invalid input unwritable — a tree spec that is recursive cannot
contain a cycle. What shape cannot rule out, each algorithm's `build`
checks exactly once, jointly over spec and configuration, and either
reports every problem it found or returns a witness value from which
running the layout is total ([Data model](#data-model)). Nothing downstream re-checks, and
nothing downstream can fail.

**Layout is phases; phases are functions.** Decompose, place, refine,
route, pack: each phase is a pure function from geometry to geometry.
This is what lets the shared passes serve every algorithm, and it is
why the layered pipeline can be tested phase by phase ([the layered class](#the-layered-class), [Placement-independent passes](#placement-independent-passes)).

**Consistency across algorithms.** Same field names for the same
concepts, same conventions for direction, units, and tolerances, same
two-step contract, same output shape. A user who has learned one
algorithm has learned most of the next one.

**Plain language at the public boundary.** Public names describe what callers
provide or accomplish: input, settings, preparation, layout, layers, and edges.
Terms of art such as witness, canonicalization, stress majorization, virtual
nodes, and feedback arcs remain internal or appear only in documentation that
explains why they matter. Algorithm names are public only when choosing the
algorithm is a meaningful user decision; the default path does not make callers
name its implementation.

**Speed is a data-structure discipline.** In a pure language,
performance is earned by designing for unique ownership (so updates
happen in place) and for flat, contiguous, index-addressed data. That
choice is made once, in the core representation, and every algorithm
inherits it ([Performance model](#performance-model)).

## Data model

### The shared spec: pure structure

The one input every algorithm consumes is the same: sized nodes and
the edges between them. That — and deliberately nothing else — is the
shared spec:

```roc
Graph.Spec : {
    nodes : List({ width : F64, height : F64 }),
    edges : List({ from : U64, to : U64 }),
}
```

**Identity is the index.** A node is identified by its position in
`nodes`; an edge by its position in `edges`. The alternative —
caller-supplied ids of some caller-chosen type — forces an
equality/hashing requirement through every internal structure and a
dictionary lookup onto every access, and it buys nothing: the caller
already holds their domain objects in some ordered collection, so a
mapping to indices exists on their side by construction. Index identity
gives O(1) access, cache-friendly flat storage, a deterministic
iteration order for free, and — most valuable — index-aligned output:
`positions` lines up with `spec.nodes`, `routes` lines up with
`spec.edges`, and the join back to caller data is zero code. Indices
stay plain integers at the boundary — a spec must be writable as a
literal — while inside the implementation, index spaces that could be
confused (real versus virtual nodes in the layer sweep) are kept apart
by nominal wrapper types.

**Direction is data; interpretation belongs to the algorithm.** Every
edge is an ordered pair, so a directed reading is always available.
Algorithms for which direction is meaningless (force, stress,
circular) treat the pair symmetrically; the class for which it is the
point (layered) consumes the orientation. The "directed vs.
undirected" distinction thus lives in which class is invoked — not in
a mode flag, which would add a switch without adding information, as described
in [Scope and Boundary](#scope-and-boundary).

**Everything else travels with its reader.** Per-edge weights matter
only to flow layout; pins only to algorithms that can hold a position
fixed; grouping only to the compound layer. A shared spec that
accumulated such fields would make most of them silently ignored by
most algorithms — set a weight, run force layout, and nothing happens,
with nothing to say so. Instead, each input lives in the spec, config,
or layer that reads it, and "who reads what" is visible in the types.
The input model from [Scope and Boundary](#scope-and-boundary) lands as follows: node size in the shared spec;
edge weight and routing hints in the layered class's spec; fixed
(pinned) position in the configuration of the algorithms that honor it
([Degenerate inputs and the failure posture](#degenerate-inputs-and-the-failure-posture)); parent/group in the compound layer ([Placement-independent passes](#placement-independent-passes)).

Specs are constructed by record update over a default —

```roc
g = { ..Graph.default_spec, nodes: my_nodes, edges: my_edges }
```

— which is also the forward-compatibility mechanism: new fields
default to "absent" and existing call sites keep compiling (see the [output compatibility policy](#non-functional-requirements)).

### Class specs: bare, extended, or replaced

Each spec class relates to the shared spec in one of three ways,
chosen by what its algorithms can honestly consume:

**Bare.** The general-graph algorithms ([the graph class](#the-graph-class)) read nothing beyond
structure and size: their class consumes `Graph.Spec` directly.

**Extended.** Flow layout reads more: per-edge weight (straightness
priority) and minimum layer span. Its spec wraps the shared one and
adds those as sparse attribute lists — `{ index, value }` pairs rather
than optional fields on every edge, so absence costs nothing, the
common edge stays a two-field record, and each attribute evolves
independently (see the [output compatibility policy](#non-functional-requirements)):

```roc
Layered.Spec : {
    graph : Graph.Spec,
    edge_weights : List({ edge : U64, weight : F64 }),
    min_spans : List({ edge : U64, span : U64 }),
}
```

The constrained class extends the same way, with its constraint list
([the constrained class](#the-constrained-class)).

**Replaced.** A caller who has a hierarchy holds it *as* a hierarchy —
a filesystem, an organization, a syntax tree. Asking them to flatten
it into an edge list so the library can verify treeness is a round
trip through a weaker type. The tree class takes the strong shape
directly:

```roc
Tree.Spec := { width : F64, height : F64, children : List(Tree.Spec) }
```

The spec is the root node. This type cannot express a cycle, and under
value semantics two references to one subtree simply *are* two
subtrees — so every value of this type is a tree, and the "is it a
tree" check does not exist. That is parse-don't-validate at full
strength: a shape with nothing left to check (sizes still get
validated at build). Index-aligned output survives by convention:
nodes are numbered in depth-first order — the order a reader of the
spec literal encounters them — and routes follow the same numbering,
one per non-root node's link from its parent. A forest is several
specs and one packing call ([Placement-independent passes](#placement-independent-passes)).

### The algorithm contract: build, then run

Every algorithm has the same two-step lifecycle. Roc's generated documentation
is organized around the family nominal type, so public operations use
algorithm-qualified names on that family; the returned witness supplies
`run` as a method. The executable layered exemplar is:

```roc
Layered.prepare :
    Layered.Input, Layered.Settings
    -> Try(Layered.Prepared, List(Layered.Problem))

Layered.layout_prepared : Layered.Prepared -> Layered.Result
```

Public names describe the caller's task rather than the implementation:
`Input`, `Settings`, `prepare`, `layout_prepared`, and `layout`. Technical names
such as sweep, rank assignment, and cycle breaking remain in algorithm
documentation and internals. A future alternative algorithm uses a qualified
name only when callers genuinely need to choose it. Every public operation
appears on the family type so generated documentation is complete.

**`build` validates jointly, because validity is joint.** Whether an
input is usable is a property of spec and configuration *together*: a
radial root index must name a real node, per-edge attribute lists must
reference real edges, a pivot count is judged against the node count,
pinned positions must name real nodes and be finite. (Structural
checks ride along: edge endpoints in range, sizes finite and
non-negative — zero-size nodes are legal waypoints; negative and
non-finite sizes are not.) Validating the spec alone and "sanitizing"
the configuration separately would leave exactly the cross-references
unchecked — and clamping a bad root index to the nearest valid one is
not safety, it is silent nonsense. `build` reports **all** problems it
found, not the first: build is a boundary that tools sit on, and a
tool that reveals one error per run is a bad tool.

On success, `prepare` returns the opaque `Layered.Prepared` value above —
which is two things at once. It is a **witness**: it cannot be
constructed except through `build`, so holding one is proof that this
spec and this configuration are valid together. And it is a
**precomputation**: it carries whatever derived structure the
algorithm wants ready — compressed adjacency in deterministic
insertion order ([Performance model](#performance-model)), the broken-cycle edge set for flow layout
([the layered class](#the-layered-class)), graph distances and pivot tables for stress ([the graph class](#the-graph-class)), the
coarsening hierarchy for force — so repeated runs never pay twice.

**`run` is total, and takes only what varies per run.** With the
witness in hand, `run` cannot fail; it returns geometry
unconditionally (N2). Its arguments are the inputs that select *which*
of the algorithm's equally valid outputs is wanted: a seed, for
algorithms that use randomness, and position hints (F7), for
algorithms that can continue from a previous drawing. Build fixes the
problem; run picks the starting point. Re-rolling a force layout under
a new seed, or starting again from different hints, is a cheap second
`run` against one `build` **only while the spec and build configuration
are unchanged**. A graph edit requires a new build; hints from the old
result may seed the new witness's run, but the old witness does not
represent the edited graph.
Algorithms with nothing that varies take no run arguments — the tree
algorithms' criteria determine their drawing uniquely, so there is
nothing to select — and for them the contract's value is the witness
and the uniform shape, and that is enough.

Each family also provides a one-shot operation — for example
`Layered.layout` — which performs preparation then layout. This is the
default API for callers keeping nothing; the two-step form is the
reusable path, not mandatory ceremony.

**Family validation and algorithm compilation are distinct concepts.**
The public exemplar combines them in `prepare`, because one boundary
is easier to use and report errors from. Internally, family invariants
are canonicalized by shared helpers so sibling algorithms do not grow
divergent endpoint, size, or attribute validation. If real callers need
to compare several algorithms over one large spec, a public
family-preparation witness may be added later; the design does not
require that extra lifetime until it earns its API cost.

### Geometry, units, and conventions

One convention, stated once, held everywhere:

- **Units are the caller's.** The library computes in the same units
  node sizes arrive in. There is no pixel, point, or DPI concept —
  resolution is a rendering concern, and [Scope and Boundary](#scope-and-boundary) keeps it out.
- **x grows right, y grows down.** A convention must be picked so that
  "direction: Down" means one thing; y-down is chosen because hierarchy
  and flow read top-to-bottom, and the default direction should match
  the words used to describe it. A consumer targeting a y-up surface
  flips with one subtraction against `bounds`.
- **Positions are centers.** Layout math is symmetric around node
  centers (forces, alignment, centering a parent over children);
  storing centers makes the code read like the geometry. The top-left
  rectangle form consumers often want is one derived accessor away.
- **Layouts are normalized.** Every layout is translated so its
  bounding box has its top-left corner at the origin. Output is then
  directly usable as canvas coordinates, and two layouts are comparable
  without first agreeing on a frame.

Output is again plain data:

```roc
Point : { x : F64, y : F64 }
Rect : { x : F64, y : F64, width : F64, height : F64 }

Route : [
    Line(Point, Point),
    Polyline(List(Point)),
    Curves(List({ from : Point, ctl_a : Point, ctl_b : Point, to : Point })),
]

Layout : {
    positions : List(Point), # one per node, in spec order
    routes : List(Route),    # one per edge, in spec order
    bounds : Rect,
}
```

Route endpoints lie on the node's bounding rectangle, not at its center
— an arrowhead is drawn at a route's end, and the boundary is the only
attachment point the library can know, given that it knows shapes only
as boxes ([Scope and Boundary](#scope-and-boundary)). A consumer drawing non-rectangular nodes re-clips
locally; that is their shape knowledge, not ours. Self-loops route as a
small loop beside the node; parallel edges fan with deterministic
offsets — both defined uniformly, so every algorithm inherits the same
behavior. The `Route` union is closed by design: lines, polylines, and
cubic segments express every planar curve a renderer can draw, so
algorithm growth never forces union growth (see the [output compatibility policy](#non-functional-requirements)).

Each algorithm's `run` returns this common `Layout` plus its own
byproducts as a per-algorithm result record (`ranks` and `reversed`
for the layer sweep, `depths` for trees, `components` when packing
ran, a convergence record for the iterative algorithms, …) rather than
a kitchen-sink record of mostly-empty fields.

### Ports and edge labels

Two further inputs complete the model; both follow the
travels-with-its-reader rule.

**Ports.** Some diagrams fix where an edge may touch a node — a pin on
a chip, a field in a record. A port is a declared attachment point on
a node: a side and a fractional offset along it, in the node's own
frame. An edge may bind either endpoint to a port; unbound endpoints
keep the boundary-clip behavior above. Ports are read by whatever
produces routes: the layered class, whose spec carries them and whose
ordering keeps port-bound edges in declared order at their node —
attachment semantics outrank crossing count, a deliberate priority —
and the routing passes ([Placement-independent passes](#placement-independent-passes)), which start and end at bound ports.
`build` validates as ever: ports name real nodes, offsets lie in
[0, 1], bindings name real ports.

**Edge labels.** Label text is out of scope ([Scope and Boundary](#scope-and-boundary)), but the space a
measured label needs is layout's problem: a label that overlaps a node
was placed by whoever ignored it. A label is a sized box attached to
an edge, carried where space is actually reserved: in the layered
spec, where it widens the edge's virtual node at its layer ([the layered class](#the-layered-class)), and
in the routing passes, which keep clearance along computed routes.
Wherever a label is consumed, the result reports an **anchor** per
labeled edge — the point whose space was reserved. The library places
the space; the consumer draws the text, preserving the boundary described in
[Scope and Boundary](#scope-and-boundary).

## Spec classes and their algorithms

Each class below states its input contract (its spec, per [Data model](#data-model)), then
its algorithms. Each algorithm is specified the same way: the reading
it serves, the quality criteria that define "good" for that reading,
the method that best meets those criteria at acceptable cost, and its
dials — split into `build` configuration and `run` arguments. Method
choices are argued from the criteria and the complexity budget — where
a subproblem is NP-hard, that is said, and the chosen heuristic's
effort is bounded (N2, N3).

| Class | Spec | Algorithms | Dominant cost |
|---|---|---|---|
| [`Tree`](#the-tree-class) | recursive hierarchy | `Tidy`, `Radial` | O(n) |
| [`Layered`](#the-layered-class) | graph + flow edge data | `Sweep`, `Exact` | near-linear per sweep; capped search |
| [`Graph`](#the-graph-class) | sized nodes + edges | `Force`, `Stress`, `Circular`, `Radial` | O((n+m) log n) or O(nk) per iteration |
| [`Constrained`](#the-constrained-class) | graph + constraints | `Stress` | descent + projection per iteration |

The table is a direction, not a quota. A new public algorithm earns a name only
when it provides a different reading of the data, a material quality/cost
tradeoff, or a hard geometric guarantee unavailable through configuration.
Two heuristics pursuing the same criteria remain internal strategies until a
caller needs to choose between their contracts. In particular, `Exact` means
exact with respect to a stated bounded objective and is not exposed merely as a
placeholder; projections such as tree radial may share one placement engine
while remaining named readings at the public boundary.

### The tree class

The class for data that *is* a hierarchy, held as one — its spec is
the recursive shape described in [Data model](#data-model). Two algorithms draw it: `Tidy` for the
level-by-level reading, `Radial` for the centered one.

#### Tree.Tidy

For a hierarchy, the drawing should be an honest picture of it. That
intuition decomposes into five checkable criteria: nodes of
equal depth share a level line; sibling order is preserved left to
right; a parent is centered over its children; identical subtrees
produce identical (translated) drawings; and the drawing is as narrow
as the first four criteria allow. The first three make the structure
legible, the fourth makes repetition recognizable — a reader who sees
the same shape twice may trust it is the same structure — and the fifth
respects the reality that trees grow wide and screens do not.

These criteria are satisfiable together in linear time, for arbitrary
arity and heterogeneous node sizes, by bottom-up subtree combination:
lay out each child subtree independently, then merge siblings by
walking their facing contours to find the minimum non-overlapping
separation, centering the parent over the resulting span. Two
refinements make this linear rather than quadratic: subtree shifts are
recorded as deferred offsets and pushed down in a single second pass
instead of eagerly moving whole subtrees, and contours are threaded so
that each contour step is amortized O(1). Levels are placed from
cumulative per-depth maximum node heights plus a configurable gap.

A forest is several specs, one `Tidy` per root, and one packing call
([Placement-independent passes](#placement-independent-passes)).

Config: sibling gap, subtree gap, level gap, direction. Run: nothing —
the algorithm has no per-run inputs.

#### Tree.Radial

The same hierarchy read as centrality: the root at the center,
generations on concentric rings. This is a projection of `Tidy`'s
geometry — depth maps to ring radius, horizontal extent to angular
extent — and it preserves the tidy criteria's radial analogues: wedges
nest, sibling order is preserved around the ring, and subtree identity
survives rotation. Sharing the engine is the point: one placement
method, two coordinate systems, and any improvement to the tidy engine
improves both algorithms.

Config: ring gap, start angle, winding direction. Run: nothing.

### The layered class

The class for directed graphs read as flow — dependencies, pipelines,
causality. Its spec extends the shared graph with the per-edge facts
only flow layout reads: weight and minimum layer span ([Data model](#data-model)). Two
algorithms serve it: `Sweep`, the bounded-effort method for any size,
and `Exact`, the exhaustive one for small drawings.

#### Layered.Sweep

Criteria in priority order: (1) edges point one way, so the reader can
trust direction; (2) few crossings, the dominant cost to tracing an
edge; (3) compactness — short edges, tight layers; (4) long edges run
straight, because a bend that encodes nothing still costs attention;
(5) nodes sit balanced under their neighborhoods rather than piled to
one side. The priority order is itself a design decision: a drawing
with perfect straightness but arbitrary edge directions is a worse
*flow* drawing, so direction dominates.

No single algorithm optimizes these jointly — several subproblems are
individually NP-hard — but they factor into a pipeline of phases, each
phase solvable well on its own:

**Cycle handling — once, at `build`.** If the spec's graph is not
acyclic, reverse a small edge set to make it so, restoring true
direction in routes and reporting the reversed set in every result, so
consumers draw the true arrowheads. Minimizing the reversal exactly is
NP-hard; a linear-time greedy vertex-ordering heuristic guarantees
fewer than half of all edges reversed and is near-optimal on the
sparse graphs flow diagrams actually are. The broken-cycle set lives
in the witness ([Data model](#data-model)): repeated runs never pay for it again.

**Ranking.** Assign each node an integer layer, minimizing total
weighted edge span subject to each edge spanning at least one layer.
This is an integer program whose constraint structure makes the linear
relaxation integral, so the *exact* optimum is affordable: an iterative
tight-tree method with cut-value pivoting reaches it in near-linear
time in practice. Ranking is solved exactly rather than heuristically
because everything downstream inherits its quality, and it is the one
phase where exactness is cheap. Per-edge weight biases important edges
toward shorter spans; per-edge minimum span is the reserved hook for
"keep these layers apart" constraints.

**Virtual chains.** Edges spanning multiple layers are subdivided with
a virtual node per crossed layer. This single move reduces crossing
minimization and coordinate assignment to adjacent-layer problems and
gives long edges concrete geometry; virtual nodes carry width, so edge
corridors reserve real space (edge label boxes widen a chain's virtual
node at their layer, [Data model](#data-model)).

**Ordering.** Crossing minimization is NP-hard even between two layers,
so: initialize orders by traversal, then sweep down and up,
repositioning each layer by the median position of its fixed neighbors,
followed by adjacent-swap polishing; keep the best ordering seen as
scored by counted crossings; stop on no improvement or at the sweep
cap. Median ordering is chosen over averaging because it is robust to
outlier neighbors and provably within a constant factor of optimal on
the two-layer subproblem; ties break by prior position, then index, so
the phase is deterministic (F4).

**Coordinates.** Within each layer, place nodes respecting sizes and
gaps while straightening virtual chains and balancing: four directional
alignment passes (each greedily aligns nodes into vertical blocks,
favoring one sweep direction), then a per-node median of the four
candidates. Linear time; straight chains fall out because all four
passes agree on aligning a chain's virtual nodes. An exact
least-squares placement was considered and rejected: solver cost and
failure modes, for quality indistinguishable from the median of
alignments. Layer y-positions come from per-layer maximum heights plus
the layer gap.

**Routes.** Each edge becomes a polyline through its virtual waypoints;
an optional smoothing pass replaces bends with monotone cubic segments
(the `Curves` route form) that stay within the reserved corridor.
Orthogonal edge styling is the [Placement-independent passes](#placement-independent-passes) router applied to this placement.

Config: direction, layer gap, node gap, sweep cap; per-edge weight and
minimum span live in the spec ([Data model](#data-model)). Run: position hints (F7), which
seed the initial ordering so that re-laying-out an edited graph
preserves the surviving order.

#### Layered.Exact

Exact crossing minimization, for drawings small enough to afford it
and important enough to deserve it. Ranking, virtual chains,
coordinates, and routes are exactly as in `Sweep`; the ordering phase
is replaced by branch-and-bound over layer orderings with lower-bound
pruning. Exponential in the worst case, so the search carries an
explicit effort cap (N2); at the cap it returns the best ordering
found and reports whether optimality was proven — capped exactness is
stated, never silent. It is a separate named algorithm rather than a
quality mode of `Sweep` because it makes a different promise at a
different cost, and that choice should be explicit (see the [output compatibility policy](#non-functional-requirements)).

Config: direction, layer gap, node gap, effort cap. Run: nothing — an
optimum does not depend on a starting point.

### The graph class

The general class: any sized graph, no structure claimed beyond nodes
and edges — its spec is `Graph.Spec` itself, bare ([Data model](#data-model)). Four
algorithms, four readings of one input.

#### Graph.Force

For graphs whose reading is organic: what clusters, what
bridges, what is central. The model is physical because the criteria
are: edges should have roughly uniform length (adjacent things near),
non-adjacent nodes should spread (unrelated things apart), and
symmetric substructures should settle into symmetric positions — an
equilibrium of springs along edges plus pairwise repulsion between
nodes delivers exactly these. Iterate: compute forces, cap displacement
by a temperature that cools over iterations, stop at the movement
tolerance or the iteration cap.

Three additions take the naive method to the state of the art:

- **Far-field aggregation.** Pairwise repulsion is O(n²) per iteration.
  A quadtree over positions lets distant clusters act as single point
  masses, with an opening-angle parameter bounding the approximation
  error, restoring O((n + m) log n) per iteration. This is a controlled
  approximation of a term that is itself a heuristic — the aggregated
  far-field force is as defensible as the exact one, at a fraction of
  the cost.
- **Multilevel refinement.** Simulation started from random positions
  falls into local minima on anything but small graphs — global
  structure cannot emerge from local moves. Coarsen the graph by
  repeatedly merging matched node pairs until it is trivially small,
  lay out the coarsest graph, then prolong positions level by level,
  refining with a cooling schedule at each. Global shape is decided
  where the graph is small and the energy landscape simple; fine levels
  only polish locally. Total work stays near-linear.
- **Seeded determinism.** Initial scatter and any tie-breaking jitter
  derive from the seed in the run arguments (fixed default), making
  runs identical (F4) and giving callers a legitimate "reroll" dial:
  different seeds are different, equally valid equilibria — and from
  one built witness, each reroll is just another `run`.

Node sizes enter through per-edge ideal lengths (derived from endpoint
extents plus the configured gap), not through box-aware forces —
box-aware repulsion is expensive and oscillation-prone. Residual box
overlaps are removed by the shared post-pass ([Placement-independent passes](#placement-independent-passes)), which preserves the
shape the simulation found. This split — points simulate, projection
enforces boxes — is deliberate architecture, not a shortcut.

Config: ideal edge length (or derived), repulsion strength, centering
gravity, opening angle, iteration cap, tolerance, pinned nodes. Run:
seed, position hints (F7).

#### Graph.Stress

Force-directed layout sees only edges plus generic repulsion; its
global proportions are emergent and unreliable. When the reading is
"distances mean something" — how far apart two subsystems are drawn
should track how far apart they are in the graph — the criterion should
be optimized directly. Define stress as the weighted squared error
between drawn distance and graph-theoretic distance over node pairs,
weighted by inverse squared distance so that near pairs dominate
(long-range error is visually cheap; short-range error is what
misleads), and minimize it.

Minimization is by majorization: at each step, replace the stress
function with a quadratic upper bound tangent at the current layout,
minimize the bound exactly (a weighted-average update per node), and
repeat. Each step provably decreases stress — no step size, no cooling
schedule, no tuning — and iteration stops on relative stress change
below tolerance or at the cap. The simultaneous-update variant is
chosen over sequential sweeps: it is order-independent, which makes
determinism structural rather than disciplined, and leaves the door
open to parallel execution without output change ([Performance model](#performance-model)).

Exact all-pairs distances cost O(nm), with O(n²) terms per iteration —
fine to a few thousand nodes, prohibitive past that. Beyond it, pivot
approximation: choose k pivots by farthest-point sampling
(deterministic, from a fixed start), compute distances only from
pivots, and adapt weights so each pivot stands for the region it
covers — O(km) for distances and O(nk) per iteration, with k a quality
dial. Distances and pivots live in the witness, and initialization is
the run's seeded scatter or its position hints (F7) — stress descent
is the natural consumer of a previous drawing, and a hinted re-run
costs only its iterations.

Stress is also the objective the constrained class ([the constrained class](#the-constrained-class)) optimizes
subject to rules, which is why the two share a solver skeleton.

Config: pivot count (or exact mode), target scale, iteration cap,
tolerance, pinned nodes. Run: seed, position hints.

#### Graph.Circular

All nodes on one ring: the reading is symmetry and completeness —
protocol rings, cliques, cycle structures. The one degree of freedom
is the ordering, and the criterion is chord crossings; exact
minimization is NP-hard, so order by a greedy adjacency-affinity pass
(neighbors want to sit adjacent on the ring), polished by the same
adjacent-swap machinery as the layer sweep ([the layered class](#the-layered-class)). Spacing comes from
node extents along the circumference; the radius is derived, not
configured.

Config: node gap along the ring, start angle, winding direction. Run:
nothing.

#### Graph.Radial

Concentric rings by breadth-first depth from a root: the reading is
centrality — everything is oriented around one thing. The root is
configured or defaults to highest degree; a configured root is an
index into the spec, validated at `build` — [Data model](#data-model)'s argument for joint
validation, made concrete. Within-ring order is crossing-reduced by
neighbor-median sweeps against adjacent rings, reusing the layer
sweep's ordering machinery ([the layered class](#the-layered-class)). A hierarchy held as a hierarchy is
better served by `Tree.Radial`, which guarantees the tidy criteria;
this algorithm is for general graphs, where "depth from a center" is a
discovered property rather than a given structure.

Config: root (or auto), ring gap, start angle, winding direction. Run:
nothing.

### The constrained class

Real diagrams obey rules that are facts about the domain, not
preferences about aesthetics: these three services sit in the same
tier; the timeline runs left to right; this group stays inside its
lane. Enforcing rules after layout produces conflicts between the rule
and the shape; rules must join the optimization itself. Its spec
extends the shared graph with a constraint list over node indices
([Data model](#data-model)): minimum separation along an axis, alignment along an axis,
containment within a band.

#### Constrained.Stress

Stress ([the graph class](#the-graph-class)), optimized subject to the rules. The solver alternates a
stress-descent step with projection onto the feasible region — and the
projection must be one SIMULTANEOUS solve per axis, never a sequence
of per-kind projections: implementation evidence (a fuzzer-found
violation) showed that projecting separations, then alignments, then
bands lets each later stage break the one before it. Instead,
alignment groups merge into single solver variables, band and pin
bounds enter the same solve as separations against an effectively
immovable anchor variable, and per-axis projection of the combined
system is solved exactly and near-linearly by incremental block
merging: scan the constraints, merge violating nodes into rigid blocks
placed at their offset-weighted average (respecting every constraint
that crosses the merged blocks), and the result is the minimally-moved
feasible placement. Alternating descent and unified projection
converges to layouts that satisfy every constraint while staying as
faithful as the constraints allow.

The projection solver is the same machinery overlap removal uses ([Placement-independent passes](#placement-independent-passes))
— one solver, two consumers — and pinning ([Degenerate inputs and the failure posture](#degenerate-inputs-and-the-failure-posture)) is its degenerate
case: an equality the solver never moves. The constraint list enters
through [Data model](#data-model)'s spec-extension pattern, so constraints compose with
everything the shared spec already carries.

Config: as `Graph.Stress`, whose dials it shares. Run: seed, position
hints.

## Placement-independent passes

Placement is what algorithms compete on; everything around placement
is shared. Factoring these passes out once is what keeps algorithms
thin, consistent, and composable — any pass below works with any
algorithm's output.

**Components and packing.** Disconnected input is normal (forests,
unlinked clusters), so decomposition is not an error path: split into
connected components, lay each out with the chosen algorithm, then pack
the component boxes. Optimal packing is NP-hard; a deterministic shelf
heuristic — components sorted by descending extent then index, placed
into rows targeting a configured aspect ratio — is within a small
constant of optimal area and never surprising. Config: component gap,
target aspect ratio.

**Overlap removal.** Point-based algorithms (force, stress) can leave
node boxes overlapping. The requirement is not merely "no overlaps" —
it is "no overlaps, minimal movement, relative order preserved,"
because the placement's shape is information the pass must not destroy.
A sweep over the placement generates the violated separation
requirements; per-axis projection (the block-merge solver from [the
constrained class](#the-constrained-class))
computes the minimally-displaced positions satisfying them. Chosen over
naive iterative push-apart, which oscillates, over-scatters, and
carries no termination guarantee at all.

**Edge routing.** Straight, box-clipped routes with deterministic
parallel-edge fanning and self-loop stubs are the universal default
([Data model](#data-model)); bound ports replace the clip point, and label boxes keep their
clearance ([Data model](#data-model)). Above that, an orthogonal router works over any
placement: build
an axis-aligned visibility structure over the node boxes, route each
edge by shortest path with a per-bend penalty, process edges in
deterministic order with a congestion cost so bundles spread, then
nudge coincident segments apart into parallel tracks. Routing over a
fixed placement — rather than jointly optimizing placement and routes —
is a deliberate boundary: joint optimization is a research-grade
pipeline with brittle quality cliffs, while routing-over-placement
composes with every algorithm and covers the diagrams that actually want
orthogonal edges (boxes-and-arrows over layered placement). A bend
should exist only to avoid a node or to merge a reading; the bend
penalty is that principle made into arithmetic.

**Compound graphs.** Grouping recurses: lay out
the innermost groups first; each laid-out group becomes a single node
of derived size (contents plus padding, with an optional configured
minimum) in its parent's layout; edges crossing a boundary route to
the boundary in the outer context and continue inside. Because each
level is an ordinary layout over an ordinary graph, any algorithm can
serve any level — a layered diagram whose one chaotic group is laid
out by force internally falls out of the recursion for free. The
compound layer is accordingly its own spec class, in which each group
lists its members and names the algorithm and configuration for its
interior — grouping wraps the other classes rather than threading a
group field through every spec (F6).

**The internal kit.** Shared machinery, internal unless a consumer
case exists: a seeded pseudo-random generator (a small 64-bit mixer —
part of the determinism contract, so its algorithm is frozen within a
major version); a quadtree; breadth-first and weighted shortest paths;
union-find; the per-axis projection solver; contour structures. Public:
`Metrics` (F8) — crossings (exact by sweep where affordable, a sampled
estimate above a documented size threshold), stress, bends, area and
aspect, separation violations, and displacement versus a reference
layout for evaluating stability (F7).

## Configuration

Configuration follows one pattern everywhere. Each family exposes an
algorithm-qualified defaults value — and an algorithm-qualified default run
value where it has per-run arguments — and callers update them:

```roc
settings = { ..Layered.default_settings, direction: Right, layer_gap: 60 }
prepared = Layered.prepare(input, settings)?
```

The pattern is load-bearing, not stylistic: it is how configs grow
without breaking (see the [output compatibility policy](#non-functional-requirements)), it makes every non-default choice visible at
the call site, and it gives F5 ("defaults are good") a concrete
referent the test suite pins.

The split between configuration and run arguments is mechanical rather than
philosophical. Build inputs affect validity or reusable preprocessing; run
inputs affect only a particular solve. A pivot count that constructs a distance
table therefore belongs at build. A seed belongs at run. Iteration caps and
tolerances belong wherever their implementation lifecycle puts them: normally
at run when they only control stopping, but at build if they alter validated or
precomputed solver structure. Callers should not rebuild merely to ask an
otherwise identical witness for a more thorough solve.

Shared vocabulary is a rule ([Design principles](#design-principles)): `node_gap`, `layer_gap`,
`direction : [Down, Up, Left, Right]`, `max_iterations : U64`, and
`tolerance : F64` mean the same thing in every configuration that has
them, as do `seed : U64` and `hints` across run arguments. All lengths
are in the caller's units; there are no percentages or
resolution-relative values.

Configuration is validated at `build`, jointly with the spec ([Data model](#data-model)), and
that is the only place it can fail: referential fields must resolve (a
root must name a real node; attribute lists, real edges; pins, real
nodes), and numeric fields must be finite and within documented
ranges. There is no clamping — a nonsensical value is a reported
problem, not a silent adjustment — and no separate config checker,
because `build` already is one: a caller who wants validation without
geometry builds the witness and discards it. Past `build`,
configuration is beyond questioning: `run` is total (N2).

## Determinism and numerics

**One entropy source, and only at `run`.** All randomness — initial
scatter, jitter for coincident points — derives from the seed in the
algorithm's run arguments, through the library's own generator. The
default seed is fixed, so determinism holds for callers who never
think about it, and varying the seed is an explicit, legitimate dial
([the graph class](#the-graph-class)). `build` is seed-free by construction — its precomputation is
deterministic, down to pivot selection by farthest-point sampling from
a fixed start ([the graph class](#the-graph-class)) — so one witness explores many seeds without
rebuilding.

**No order left to chance.** Iteration follows index order; sorts are
stable with index as the final key; simultaneous-update formulations
are preferred where their cost is acceptable ([the graph class](#the-graph-class)) precisely because
they make output independent of traversal order. Every comparison that
could tie has a documented tie-break ending in the index.

**Termination is structural, and observable.** Every iterative process
pairs its convergence tolerance with a hard iteration cap (N2).
Tolerances are relative (movement per unit of layout scale, relative
stress change), so behavior does not depend on the caller's units. And
every iterative algorithm's result includes a convergence record —
iterations used, and which of tolerance or cap ended the run ([Data model](#data-model)) — so
the cap is not only a guarantee but a measurement the caller can react
to.

**One number type.** All geometry is `F64`. Fixed-point decimals are
too slow for simulation loops and lack the needed functions; `F32`
loses precision exactly where layouts get interesting (large
coordinates, small differences); and genericity over fractional types
would tax every internal structure to offer a dial no consumer of
*geometry* has asked to turn. Sizes in, coordinates out: `F64`.

**The precision of the guarantee.** Determinism (F4) is bit-exact:
same package version, same input, same configuration, same run
arguments — same bits, on every platform, conditional on the compiler
emitting correct code. That condition is real, not theoretical:
interpreter and native backends have been observed to disagree, so the
verification suite must run against built binaries as well as the test
runner, and ultimately on more than one platform. Basic arithmetic
and square root are exactly specified by the floating-point standard,
so the only threat is transcendental functions, whose last-bit
behavior varies between platform math libraries. The library therefore
ships its own fixed implementations of the few it uses (sine and
cosine, for radial angles): determinism is a contract ([Design principles](#design-principles)), and a
contract does not delegate its hard cases to whichever math library
happens to be installed.

**No escaping non-finites.** `build` rejects non-finite input ([Data model](#data-model));
internal divisions are guarded (a zero-distance pair repels along a
seeded deterministic direction rather than dividing by zero); and
finiteness of all public output is a property the fuzz suite asserts
(N4), as asserted by the fuzz suite.

## Performance model

A pure language earns performance through data-structure discipline,
and the discipline is set once, at the core:

**Unique ownership in hot loops.** Roc updates a value in place when it
is uniquely referenced. Every simulation and sweep therefore threads
its state linearly — positions in, positions out, no aliasing captures
— so per-iteration cost is index reads and in-place writes, not
allocation. This is a stated implementation constraint, not an
optimization to be discovered later: an algorithm whose inner loop
cannot be written unique-in/unique-out is reshaped until it can.

**Flat, index-addressed data.** Adjacency is compressed lists (offsets
plus targets, both directions), built once at each algorithm's `build`
and carried in its witness. Positions and per-phase scratch are flat
lists indexed by node. No dictionaries on hot paths — index identity
([Data model](#data-model)) was chosen partly so that this is the natural representation
rather than an internal translation layer.

Costs the design commits to (N3):

| Phase | Cost |
|---|---|
| any `build` (validation + adjacency) | O(n + m), plus algorithm precompute |
| `Tree.Tidy` / `Tree.Radial` | O(n) |
| `Layered.Sweep` (rank, order, coordinates) | near-linear per sweep, sweeps capped |
| `Graph.Force`, per iteration | O((n + m) log n) |
| `Graph.Stress`, per iteration | O(nk) with k pivots; O(n²) exact mode |
| Overlap removal | O((n + C) log n), C generated constraints |
| Component packing | O(c log c) for c components |
| Orthogonal routing | per edge, shortest path over the visibility structure |

Memory is O(n + m) throughout, plus O(n) for the quadtree.

**Measured, not claimed.** A complexity budget in the table above
counts as met only once a scale test exercises it; until then it is a
commitment the implementation has not yet earned, and saying otherwise
is the same dishonesty F8 exists to prevent in quality claims. The
regression suite grows a benchmark tier as algorithms approach their
stated scales.

**Scale targets, honestly framed.** The targets — 10⁵-node trees,
10⁴-node layered drawings, 10⁴–10⁵-node force/stress layouts — are set
by the asymptotics above; constant factors in a pure language are real
but bounded, and do not change the class. Where quality-versus-time
trades exist at scale (sweep caps, pivot counts, sampled metrics), the
defaults favor quality at F5's few-hundred-node center and degrade
gracefully, never at a cliff.

**Parallelism belongs to the platform; the design keeps it free.**
Packages have no threads; execution parallelism is the platform's and
compiler's concern. The design's contribution is to prefer
order-independent formulations ([the graph class](#the-graph-class), [Determinism and numerics](#determinism-and-numerics)) where they are free, so that
parallel execution changes wall-clock time, never output.

## Degenerate inputs and the failure posture

The failure posture in one sentence: **the only fallible operation is
`build` — the one place caller claims are inspected ([Data model](#data-model)).** Every
`run` holds a witness and returns geometry unconditionally.

Defined behavior at the edges, chosen and tested rather than emergent:

- **Empty graph** → empty layout, zero-size bounds at the origin.
- **Single node** → its rectangle sits at the origin; its center
  position is half its size.
- **Zero-size nodes** → legal waypoints; spacing rules still apply
  around their point extent.
- **Self-loops and parallel edges** → uniform loop-stub and fanning
  rules ([Data model](#data-model)), in every algorithm.
- **Pinned nodes** → a capability of the algorithms whose optimization
  is continuous — force, stress, constrained layout, overlap removal —
  which hold pins exactly by excluding them from updates.
  Discrete-placement algorithms have no pin field at all: that pins do
  not apply is said by the type system, not by documentation or a
  runtime report ([Data model](#data-model)).
- **Adversarial scale** → iteration caps bound time; quality degrades
  gradually (N3); nothing hangs.

**Guarantees are proven, or their residual is reported.** When an
algorithm's promise cannot be established at `build` time — constraint
feasibility being the exemplar: the analysis is sound but not complete —
the result must carry the discrepancy explicitly (the constrained
class's `unsatisfied` list). Silent best effort is forbidden; a
guarantee by construction (overlap removal's two-pass projection, whose
postcondition is a theorem) is preferred wherever it is achievable.
This generalizes the rule that capped exactness is stated, never
silent.

A panic anywhere, on any input, is a bug by definition, and the fuzz
pass exists to enforce that definition.

## Package and module layout

One package (working name `layout`), platform-free (N1). Modules map
onto the spec classes, so a consumer's import list reads as a
description of what they are doing:

| Module | Responsibility |
|---|---|
| `Graph` | shared spec ([Data model](#data-model)); the general class: `Force`, `Stress`, `Circular`, `Radial` |
| `Tree` | recursive spec; `Tidy`, `Radial` |
| `Layered` | flow spec; `Sweep`, `Exact` |
| `Constrained` | constraint spec; `Stress` |
| `Overlap`, `Pack`, `Route` | placement-independent passes ([Placement-independent passes](#placement-independent-passes)) |
| `Layout`, `Geom` | output types; `Point`/`Rect`; flip/translate/rect helpers |
| `Metrics` | layout scoring (F8) |

The general class shares the `Graph` module with the shared spec
deliberately: that class adds nothing to the spec, so they share a
home. Algorithms with a reusable preparation surface live in their own
modules (`ForceLayout`, `StressLayout`, `RadialLayout`), each exposing
its witness and prepare/run operations through its namesake type, with
one-call conveniences on the family module. Implementation experience
promoted this from workaround to design: per-algorithm modules produce
smaller, clearer generated documentation and smaller review surfaces
than a monolithic family module, and the compiler's namesake-only
visibility rule makes the namesake the natural public boundary. Internal and unexposed: the pseudo-random generator, quadtree,
shortest paths, union-find, projection solver, and contours.

End to end — inside a function returning `Try`, so `?` propagates build
problems:

```roc
g = { ..Graph.default_spec,
    nodes: [
        { width: 120, height: 40 },
        { width: 90, height: 40 },
        { width: 90, height: 40 },
    ],
    edges: [{ from: 0, to: 1 }, { from: 0, to: 2 }],
}

input = { ..Layered.default_input, graph: g }
prepared = Layered.prepare(input, Layered.default_settings)?
result = Layered.layout_prepared(prepared, Layered.default_run)

# result.layout.positions : List(Point) — one per node, in spec order
# result.layout.routes : List(Route)    — one per edge, in spec order
# result.layout.bounds : Rect
# result.layers : List(U32), result.backward_edges : List(U64)
```

One `build`, many `run`s — the seed selects among equally valid
equilibria ([Data model](#data-model)):

```roc
force = Graph.build_force(g, Graph.force_defaults)?
first = force.run(Graph.force_default_run)
again = force.run({ ..Graph.force_default_run, seed: 2 })
```

A renderer consumes `result.layout` and nothing else; a styling layer
may also read `result.layers`. Nothing here knows about the renderer —
which is [Scope and Boundary](#scope-and-boundary) holding at the API surface.
