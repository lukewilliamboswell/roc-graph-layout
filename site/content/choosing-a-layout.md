# Choosing a layout

Choose by what the connections mean, not just by the shape you want to draw.

## Directed flows: Layered

Use Layered for pipelines, dependencies, and process diagrams. Direction, node
gap, and layer gap control the reading direction and spacing. Cycles are
supported. The exact crossing-reduction option has an effort limit and reports
whether it proved optimality; “exact” does not mean unlimited search.

## Hierarchies: Tree

Use Tree when your input already describes a hierarchy. The level-by-level
layout emphasizes depth; the radial layout places the root at the center.
Do not turn an arbitrary network into a tree by silently dropping connections.

## General networks: Graph

- **Circular** places nodes on a ring, seating neighbors together.
- **Force** uses a seeded simulation to expose organic clusters.
- **Stress** makes drawn distances track graph distances.
- **Radial** emphasizes distance in hops from a selected root.

Keep seeds and settings fixed when comparing graph edits. Iteration limits
bound simulation work; more iterations are not a substitute for choosing the
right meaning for the input.

## Domain rules and nested groups

**Constrained** combines stress layout with axis separation, alignment, and
containment bands. **Compound** arranges nested groups from their completed
child boxes and routes connections across group boundaries.

## Geometry after placement

Pack, Overlap, and Route are placement-independent passes. Metrics lets you
compare crossings, bends, stress, separation violations, and displacement.
Consult the [API reference](docs/) for each pass's contract before composing it
with a layout.

[Try the playground](playground/) or [return to the introduction](index.html).
