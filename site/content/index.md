# Graph geometry, ready for your renderer

roc-graph-layout computes deterministic node positions, edge routes, and drawing
bounds. Your application supplies the graph and the actual sizes of its nodes;
the package does not choose fonts, measure labels, or render the result.

![A build pipeline arranged into directed stages by Layered layout.](assets/build-pipeline.svg)

[Explore the interactive playground](playground/) to change graph data and
layout settings, then inspect the drawing and its geometry.

## Start with the structure you know

- A directed pipeline or dependency graph: start with **Layered**.
- An existing hierarchy: use **Tree**.
- A general network: explore **Graph** layouts.
- Domain-specific alignment and separation rules: use **Constrained**.
- Nested groups: use **Compound**.

Read [Choosing a layout](choosing-a-layout.html) for the differences, or browse
the [versioned API reference](docs/) for complete inputs and settings.

## Read the result

Positions are node centers and follow the input node order. Edge routes follow
the input edge order. A route can be a straight line, a polyline, or a chain of
cubic curves. Use the returned bounds to frame the drawing rather than assuming
all coordinates are positive.

For repeated solves of unchanged input and preparation settings, the prepared
APIs let you retain reusable work. Prepare again when the graph changes.
