app [Model, Msg, init, update, render, subscriptions] {
	pf: platform "https://github.com/lukewilliamboswell/joy/releases/download/0.32.1-roc-2fdd90e/EF5SoS3kKaYNmGUYjwb3wt722A4TbyaJ4NxJbBYpL2W5.tar.zst",
	html: "https://github.com/niclas-ahden/joy-html/releases/download/0.15.0/5Yoz712P8ed4MBW74eddTEJdZ92ZDCUbVGFkt4XXSuj9.tar.zst",
	layout: "../package/main.roc",
	fixtures: "../examples/data/main.roc",
	rvn: "https://cdn.jasperwoudenberg.com/roc-rvn-v1.0.0-rc.2/8dArudMEhMfr4NTu1efFiFz5aCKMvSAmSspZctxFgZti.tar.zst",
}

import fixtures.ExampleData
import html.Attribute exposing [aria, attribute, checked, class, class_list, href, on_change, on_check, on_click, on_input, selected, type, value]
import html.Html exposing [Html, a, button, code, div, element, h1, h2, h3, header, input, label, main, option, p, pre, section, select, span, strong, svg, text, textarea]
import layout.Constrained
import layout.Graph
import layout.Layered
import layout.Tree
import pf.Effect exposing [Effect]
import rvn.Rvn

Point : { x : F64, y : F64 }

Rect : { x : F64, y : F64, width : F64, height : F64 }

Node : { width : F64, height : F64 }

Edge : { from : U64, to : U64 }

Route : [Line(Point, Point), Polyline(List(Point)), Curves(List({ from : Point, ctl_a : Point, ctl_b : Point, to : Point }))]

Doc : { labels : List(Str), graph : { nodes : List(Node), edges : List(Edge) } }

Example : [Pipeline, Org, Ring, Mind, Collaboration, Incident, Cloud, Release, Transit]

Mode : [LayeredMode, TreeMode, TreeRadialMode, CircularMode, ForceMode, StressMode, RadialMode, ConstrainedMode, CompoundMode]

NumberField : [NodeGap, LayerGap, RingGap, StartAngle, Iterations, Tolerance, Repulsion, Gravity, Sweeps, Seed]

Config : { node_gap : F64, layer_gap : F64, ring_gap : F64, start_angle : F64, iterations : U64, tolerance : F64, repulsion : F64, gravity : F64, sweeps : U64, seed : U32, direction : [Down, Up, Left, Right], clockwise : Bool, exact : Bool }

Drawing : { labels : List(Str), nodes : List(Node), routes : List(Route), positions : List(Point), bounds : Rect, groups : List(Rect), result : Str }

State : { example : Example, draft : Str, mode : Mode, config : Config, drawing : [Some(Drawing), None], errors : List(Str) }

Model : { version : Str, states : List(State), selected : Example, examples_open : Bool }

Msg : [Choose(Example), Edit(Str), ChooseMode(Str), SetNumber(NumberField, Str), SetDirection(Str), SetClockwise(Bool), SetExact(Bool), Run, Reset, ToggleExamples]

subscriptions = |_model| []

default_config : Config
default_config = { node_gap: 24, layer_gap: 70, ring_gap: 60, start_angle: -1.5707963267948966, iterations: 300, tolerance: 0.01, repulsion: 1, gravity: 0.05, sweeps: 4, seed: 0, direction: Down, clockwise: Bool.True, exact: Bool.True }

examples = [Pipeline, Org, Ring, Mind, Collaboration, Incident, Release, Transit]

meta = |example| match example {
	Pipeline => { title: "Build pipeline", family: "Directed flow", note: "Arrange dependencies into readable stages.", mode: LayeredMode }
	Org => { title: "Organization chart", family: "Directed hierarchy", note: "Arrange reporting lines into readable levels.", mode: LayeredMode }
	Ring => { title: "Service ring", family: "General graph", note: "Seat connected services around a circle.", mode: CircularMode }
	Mind => { title: "Mind map", family: "Radial hierarchy", note: "Place generations on rings around a root.", mode: RadialMode }
	Collaboration => { title: "Collaboration network", family: "General graph", note: "Reveal organic clusters with seeded forces.", mode: ForceMode }
	Incident => { title: "Incident blast radius", family: "General graph", note: "Show dependency distance from one service.", mode: RadialMode }
	Cloud => { title: "Cloud deployment", family: "Nested groups", note: "Compose layouts inside infrastructure boundaries.", mode: CompoundMode }
	Release => { title: "Release workflow", family: "Domain rules", note: "Honor alignment and separation rules.", mode: ConstrainedMode }
	Transit => { title: "Transit network", family: "General graph", note: "Make drawn distance reflect network distance.", mode: StressMode }
}

graph_doc = |labels, edges, width, height| { labels, graph: { nodes: List.repeat({ width, height }, labels.len()), edges } }

preset = |example| match example {
	Pipeline => graph_doc(["fetch", "compile", "lint", "build", "test", "package", "publish"], [{ from: 0, to: 1 }, { from: 0, to: 2 }, { from: 1, to: 3 }, { from: 2, to: 3 }, { from: 3, to: 4 }, { from: 3, to: 5 }, { from: 4, to: 6 }, { from: 5, to: 6 }], 90, 40)
	Org => graph_doc(["CEO", "CTO", "Engineering", "Dev 1", "Dev 2", "Quality", "COO", "Operations", "CFO"], [{ from: 0, to: 1 }, { from: 1, to: 2 }, { from: 2, to: 3 }, { from: 2, to: 4 }, { from: 1, to: 5 }, { from: 0, to: 6 }, { from: 6, to: 7 }, { from: 0, to: 8 }], 100, 36)
	Ring => graph_doc(["Gateway", "Auth", "Users", "Orders", "Billing", "Inventory", "Shipping", "Notify"], [{ from: 0, to: 1 }, { from: 1, to: 2 }, { from: 2, to: 3 }, { from: 3, to: 4 }, { from: 4, to: 5 }, { from: 5, to: 6 }, { from: 6, to: 7 }, { from: 7, to: 0 }, { from: 0, to: 4 }], 96, 32)
	Mind => graph_doc(["Trip", "Travel", "Flights", "Trains", "Stay", "Hotels", "Camping", "Activities", "Museums", "Hiking", "Budget"], [{ from: 0, to: 1 }, { from: 1, to: 2 }, { from: 1, to: 3 }, { from: 0, to: 4 }, { from: 4, to: 5 }, { from: 4, to: 6 }, { from: 0, to: 7 }, { from: 7, to: 8 }, { from: 7, to: 9 }, { from: 0, to: 10 }], 100, 36)
	Collaboration => graph_doc(["Ada", "Grace", "Alan", "Edsger", "Barbara", "Donald", "John", "Leslie", "Contractor A", "Contractor B"], [{ from: 0, to: 1 }, { from: 0, to: 2 }, { from: 0, to: 3 }, { from: 1, to: 2 }, { from: 2, to: 3 }, { from: 0, to: 4 }, { from: 4, to: 5 }, { from: 5, to: 6 }, { from: 5, to: 7 }, { from: 6, to: 7 }, { from: 8, to: 9 }], 86, 30)
	Incident => graph_doc(["Payments", "Checkout", "Orders", "Subscriptions", "Web", "Mobile", "Portal", "Fulfillment", "Support", "Export", "Notify", "Analytics"], [{ from: 0, to: 1 }, { from: 0, to: 2 }, { from: 0, to: 3 }, { from: 1, to: 4 }, { from: 1, to: 5 }, { from: 1, to: 6 }, { from: 2, to: 7 }, { from: 2, to: 8 }, { from: 2, to: 9 }, { from: 3, to: 10 }, { from: 10, to: 11 }], 108, 34)
	Cloud => graph_doc(["Customer", "CDN", "Gateway", "API", "Worker", "Postgres", "Redis", "Queue"], [{ from: 0, to: 1 }, { from: 1, to: 2 }, { from: 2, to: 3 }, { from: 3, to: 4 }, { from: 3, to: 5 }, { from: 3, to: 6 }, { from: 3, to: 7 }, { from: 7, to: 4 }], 104, 36)
	Release => graph_doc(["Brief", "Plan", "Build", "Test", "Threat model", "Security", "Approve", "Deploy", "Monitor"], [{ from: 0, to: 1 }, { from: 1, to: 2 }, { from: 1, to: 4 }, { from: 2, to: 3 }, { from: 3, to: 5 }, { from: 4, to: 5 }, { from: 5, to: 6 }, { from: 6, to: 7 }, { from: 7, to: 8 }], 112, 34)
	Transit => ExampleData.transit_network
}

encode = |value_| Str.from_utf8_lossy(Rvn.encode(value_))

initial_state = |example| { example, draft: encode(preset(example)), mode: (meta(example)).mode, config: default_config, drawing: None, errors: [] }

init = |version| {
	model = { version, states: examples.map(initial_state), selected: Pipeline, examples_open: Bool.False }
	(run_model(model), [])
}

current = |model| model.states.find_first(|state| state.example == model.selected) ?? initial_state(Pipeline)

map_current = |model, change| { ..model, states: model.states.map(|state| if state.example == model.selected change(state) else state) }

run_model = |model| map_current(model, run_state)

update = |model, msg| match msg {
	Choose(example) => {
		next = { ..model, selected: example, examples_open: Bool.False }
		match (current(next)).drawing {
			None => (run_model(next), [])
			Some(_) => (next, [])
		}
	}
	Edit(draft) => (run_model(map_current(model, |state| { ..state, draft })), [])
	ChooseMode(raw) => (run_model(map_current(model, |state| { ..state, mode: mode_from_str(raw, state.mode) })), [])
	SetNumber(field, raw) => (run_model(map_current(model, |state| { ..state, config: set_number(state.config, field, raw) })), [])
	SetDirection(raw) => (run_model(map_current(model, |state| { ..state, config: { ..state.config, direction: direction_from_str(raw) } })), [])
	SetClockwise(on) => (run_model(map_current(model, |state| { ..state, config: { ..state.config, clockwise: on } })), [])
	SetExact(on) => (run_model(map_current(model, |state| { ..state, config: { ..state.config, exact: on } })), [])
	Run => (run_model(model), [])
	Reset => {
		reset = initial_state(model.selected)
		(run_model({ ..model, states: model.states.map(|state| if state.example == model.selected reset else state) }), [])
	}
	ToggleExamples => ({ ..model, examples_open: !model.examples_open }, [])
}

parse_doc = |draft| {
	parsed : Try(Doc, _)
	parsed = Rvn.parse(draft.to_utf8())
	parsed.map_err(|_| ["The graph data is not valid RVN for labels, nodes, and edges."])
}

validate = |doc| {
	problems = if doc.graph.nodes.len() > 1000 ["The playground supports at most 1,000 nodes."] else []
	with_edges = if doc.graph.edges.len() > 5000 problems.append("The playground supports at most 5,000 edges.") else problems
	if doc.labels.len() != doc.graph.nodes.len() with_edges.append("Labels must contain exactly one item per node.") else with_edges
}

run_state = |state| {
	result = run_layout(state.mode, state.draft, state.config)
	match result {
		Ok(drawing) => { ..state, drawing: Some(drawing), errors: [] }
		Err(errors) => { ..state, drawing: None, errors }
	}
}

run_layout = |mode, draft, config| {
	doc = parse_doc(draft)?
	problems = validate(doc)
	if !problems.is_empty() return Err(problems)
	if config.iterations > 2000 or config.sweeps > 2000 return Err(["The playground limits layouts to 2,000 iterative steps."])
	match mode {
		LayeredMode => run_layered(doc, config)
		TreeMode => run_tree(doc, config, Bool.False)
		TreeRadialMode => run_tree(doc, config, Bool.True)
		CircularMode | ForceMode | StressMode | RadialMode => run_graph(doc, config, mode)
		ConstrainedMode => run_constrained(doc, config)
		CompoundMode => Err(["Compound layout needs a Roc nightly containing the Wasm dev-backend type fix."])
	}
}

route_settings = { ..Layered.default_settings.routing, obstacle_gap: 8, bend_penalty: 16, shared_path_penalty: 4, edge_gap: 6 }

make_drawing = |doc, layout_, groups| { labels: doc.labels, nodes: doc.graph.nodes, routes: layout_.routes, positions: layout_.positions, bounds: layout_.bounds, groups, result: geometry_str(layout_) }

layout_error = |errors| Err(["Layout rejected the input or settings (${errors.len().to_str()} problem(s))."])

run_layered = |doc, config| {
	input_ = { ..Layered.default_input, graph: doc.graph }
	settings = { ..Layered.default_settings, node_gap: config.node_gap, layer_gap: config.layer_gap, routing: route_settings, direction: config.direction, max_sweeps: config.sweeps }
	match Layered.layout(input_, settings, Layered.default_run) {
		Err(errors) => Err(errors.map(Layered.problem_to_str))
		Ok(result) => Ok(make_drawing(doc, result.layout, []))
	}
}

tree_problems = |doc| doc.graph.edges.map_with_index(|edge, index| if edge.from >= edge.to ["Tree edge ${index.to_str()} must point from an earlier parent to a later child."] else []).join()

tree_spec : Doc -> Tree.Spec
tree_spec = |doc| {
	node_count = doc.graph.nodes.len()
	var $specs = doc.graph.nodes.map(|size| { width: size.width, height: size.height, children: [] })
	for offset in 0..<node_count {
		index = node_count - offset - 1
		base = $specs.get(index) ?? { width: 0, height: 0, children: [] }
		children = doc.graph.edges.keep_oks(|edge| if edge.from == index $specs.get(edge.to).map_err(|_| Skip) else Err(Skip))
		$specs = $specs.set(index, { ..base, children }) ?? []
	}
	$specs.get(0) ?? { width: 0, height: 0, children: [] }
}

run_tree = |doc, config, radial| {
	problems = tree_problems(doc)
	if !problems.is_empty() return Err(problems)
	spec = tree_spec(doc)
	if radial {
		settings = { sibling_gap: 12, subtree_gap: 24, ring_gap: config.ring_gap, start_angle: config.start_angle, winding: if config.clockwise Clockwise else CounterClockwise }
		match Tree.layout_radial(spec, settings) {
			Err(errors) => layout_error(errors)
			Ok(result) => Ok(make_drawing(doc, result.layout, []))
		}
	} else {
		settings = { sibling_gap: 12, subtree_gap: 24, level_gap: config.layer_gap, direction: config.direction }
		match Tree.layout(spec, settings) {
			Err(errors) => layout_error(errors)
			Ok(result) => Ok(make_drawing(doc, result.layout, []))
		}
	}
}

run_graph = |doc, config, mode| match mode {
	CircularMode => {
		settings = { node_gap: config.node_gap, start_angle: config.start_angle, winding: if config.clockwise Clockwise else CounterClockwise }
		match Graph.layout_circular(doc.graph, settings) {
			Err(errors) => layout_error(errors)
			Ok(result) => Ok(make_drawing(doc, result.layout, []))
		}
	}
	ForceMode => {
		settings = { node_gap: config.node_gap, repulsion: config.repulsion, gravity: config.gravity, opening_angle: 0.9, max_iterations: config.iterations, tolerance: config.tolerance, pins: [] }
		match Graph.layout_force(doc.graph, settings, { seed: config.seed, hints: [] }) {
			Err(errors) => layout_error(errors)
			Ok(result) => Ok(make_drawing(doc, result.layout, []))
		}
	}
	StressMode => {
		settings = { node_gap: config.node_gap, mode: if config.exact Exact else Pivots(8), max_iterations: config.iterations, tolerance: config.tolerance, pins: [] }
		match Graph.layout_stress(doc.graph, settings, { seed: config.seed, hints: [] }) {
			Err(errors) => layout_error(errors)
			Ok(result) => Ok(make_drawing(doc, result.layout, []))
		}
	}
	RadialMode => {
		settings = { root: Auto, ring_gap: config.ring_gap, node_gap: config.node_gap, start_angle: config.start_angle, winding: if config.clockwise Clockwise else CounterClockwise }
		match Graph.layout_radial(doc.graph, settings) {
			Err(errors) => layout_error(errors)
			Ok(result) => Ok(make_drawing(doc, result.layout, []))
		}
	}
	_ => Err(["Unsupported general graph layout."])
}

run_constrained = |doc, config| {
	constraints = [Align({ axis: Y, nodes: [0, 1] }), Separate({ axis: X, first: 0, second: 1, gap: 140 }), Align({ axis: Y, nodes: [2, 3] }), Separate({ axis: X, first: 2, second: 3, gap: 140 })]
	settings = { node_gap: config.node_gap, max_iterations: config.iterations, tolerance: config.tolerance, pins: [] }
	match Constrained.layout({ graph: doc.graph, constraints }, settings, { seed: config.seed, hints: [] }) {
		Err(errors) => layout_error(errors)
		Ok(result) => Ok(make_drawing(doc, result.layout, []))
	}
}

geometry_str = |layout_| {
	positions = Str.join_with(layout_.positions.map(|point| "{ x: ${point.x.to_str()}, y: ${point.y.to_str()} }"), ", ")
	bounds = layout_.bounds
	\\{
	\\    positions: [${positions}],
	\\    bounds: { x: ${bounds.x.to_str()}, y: ${bounds.y.to_str()}, width: ${bounds.width.to_str()}, height: ${bounds.height.to_str()} },
	\\}
}

mode_from_str = |raw, fallback|
	match raw {
		"Tree" => TreeMode
		"TreeRadial" => TreeRadialMode
		"Circular" => CircularMode
		"Force" => ForceMode
		"Stress" => StressMode
		"Radial" => RadialMode
		_ => fallback
	}

direction_from_str = |raw|
	match raw {
		"Up" => Up
		"Left" => Left
		"Right" => Right
		_ => Down
	}

set_number = |config, field, raw| match field {
	NodeGap => { ..config, node_gap: F64.from_str(raw) ?? config.node_gap }
	LayerGap => { ..config, layer_gap: F64.from_str(raw) ?? config.layer_gap }
	RingGap => { ..config, ring_gap: F64.from_str(raw) ?? config.ring_gap }
	StartAngle => { ..config, start_angle: F64.from_str(raw) ?? config.start_angle }
	Iterations => { ..config, iterations: U64.from_str(raw) ?? config.iterations }
	Tolerance => { ..config, tolerance: F64.from_str(raw) ?? config.tolerance }
	Repulsion => { ..config, repulsion: F64.from_str(raw) ?? config.repulsion }
	Gravity => { ..config, gravity: F64.from_str(raw) ?? config.gravity }
	Sweeps => { ..config, sweeps: U64.from_str(raw) ?? config.sweeps }
	Seed => { ..config, seed: U32.from_str(raw) ?? config.seed }
}

render : Model -> Html(Msg)
render = |model| {
	state = current(model)
	div([], [header([class("header")], [strong([], [text("roc-graph-layout")]), div([class("header-links")], [span([class("version")], [text(model.version)]), a([href("./docs/")], [text("API docs")]), a([href("https://github.com/lukewilliamboswell/roc-graph-layout")], [text("GitHub")])])]), main([class("shell")], [section([class("intro")], [div([], [p([class("eyebrow")], [text("Interactive playground")]), h1([], [text("Graph layout, rendered as SVG")]), p([], [text("Choose an example, edit its RVN data, and inspect the geometry returned by the Roc package.")])]), example_picker(model)]), workspace(state)])])
}

example_key = |example| match example {
	Pipeline => "pipeline"
	Org => "org"
	Ring => "ring"
	Mind => "mind"
	Collaboration => "collaboration"
	Incident => "incident"
	Cloud => "cloud"
	Release => "release"
	Transit => "transit"
}

example_picker = |model| {
	active = model.selected
	info = meta(active)
	div([class("example-picker")], [span([], [text("Example")]), div([class("example-menu-wrap")], [button([class("example-select"), aria("expanded", if model.examples_open "true" else "false"), on_click(ToggleExamples)], [text((meta(active)).title), span([aria("hidden", "true")], [text(if model.examples_open "▴" else "▾")])]), if model.examples_open div([class("example-menu")], examples.map(|example| button([class_list([("example-option", Bool.True), ("active", example == active)]), on_click(Choose(example))], [text((meta(example)).title)]))) else div([], [])]), small_text(info.family, info.note)])
}

small_text = |family, note| span([class("example-note")], [strong([], [text(family)]), text(" · ${note}")])

workspace = |state| {
	info = meta(state.example)
	section([class("workspace")], [div([class("toolbar")], [div([], [p([class("eyebrow")], [text(info.family)]), h2([], [text(info.title)])]), div([class("actions")], [button([class("secondary"), on_click(Reset)], [text("Reset")]), button([class("primary"), on_click(Run)], [text("Run layout")])])]), div([class("grid")], [div([class("data-panel")], [div([class("section-heading")], [h3([], [text("Graph data (RVN)")]), span([], [text("Updates automatically")])]), textarea([class("editor"), attribute("spellcheck", "false"), aria("label", "Graph data in RVN"), on_input(|draft| Edit(draft))], [text(state.draft)]), controls(state)]), div([class("visual-panel")], [div([class("section-heading")], [h3([], [text("SVG preview")]), span([], [text("Fits to the available space")])]), error_view(state.errors), drawing_view(state.drawing)])]), result_view(state)])
}

number = |title, field, current_value| label([class("control")], [span([], [text(title)]), input([type("number"), value(current_value), on_input(|raw| SetNumber(field, raw))])])

picker = |state| match state.example {
	Org => select([], [option([], [text("Layered")])])
	Mind => select([], [option([], [text("Radial")])])
	Ring | Collaboration | Incident | Transit => select([on_change(|raw| ChooseMode(raw))], [("Circular", "Circular"), ("Force", "Force"), ("Stress", "Stress"), ("Radial", "Radial")].map(|pair| option([value(pair.0), selected(mode_name(state.mode) == pair.0)], [text(pair.1)])))
	_ => select([], [option([], [text(mode_name(state.mode))])])
}

basic_controls = |state| {
	c = state.config
	direction = label([class("control")], [span([], [text("Direction")]), select([on_change(|raw| SetDirection(raw))], ["Down", "Up", "Left", "Right"].map(|name| option([value(name), selected(direction_name(c.direction) == name)], [text(name)])))])
	match state.mode {
		LayeredMode => [number("Node gap", NodeGap, c.node_gap.to_str()), number("Layer gap", LayerGap, c.layer_gap.to_str()), direction]
		TreeMode => [number("Level gap", LayerGap, c.layer_gap.to_str()), direction]
		TreeRadialMode => [number("Ring gap", RingGap, c.ring_gap.to_str())]
		CircularMode => [number("Node gap", NodeGap, c.node_gap.to_str())]
		ForceMode => [number("Node gap", NodeGap, c.node_gap.to_str()), number("Repulsion", Repulsion, c.repulsion.to_str()), number("Gravity", Gravity, c.gravity.to_str())]
		StressMode | ConstrainedMode => [number("Node gap", NodeGap, c.node_gap.to_str())]
		RadialMode => [number("Node gap", NodeGap, c.node_gap.to_str()), number("Ring gap", RingGap, c.ring_gap.to_str())]
		CompoundMode => []
	}
}

advanced_controls = |state| {
	c = state.config
	winding = label([class("check")], [input([type("checkbox"), checked(c.clockwise), on_check(|on| SetClockwise(on))]), text("Clockwise")])
	match state.mode {
		LayeredMode => [number("Ordering sweeps", Sweeps, c.sweeps.to_str())]
		TreeMode => []
		TreeRadialMode | CircularMode | RadialMode => [number("Start angle", StartAngle, c.start_angle.to_str()), winding]
		ForceMode | ConstrainedMode => [number("Maximum iterations", Iterations, c.iterations.to_str()), number("Tolerance", Tolerance, c.tolerance.to_str()), number("Seed", Seed, c.seed.to_str())]
		StressMode => [number("Maximum iterations", Iterations, c.iterations.to_str()), number("Tolerance", Tolerance, c.tolerance.to_str()), number("Seed", Seed, c.seed.to_str()), label([class("check")], [input([type("checkbox"), checked(c.exact), on_check(|on| SetExact(on))]), text("Exact stress")])]
		CompoundMode => []
	}
}

controls = |state| {
	advanced = advanced_controls(state)
	div([class("settings")], [div([class("controls")], [label([class("control layout-control")], [span([], [text("Layout")]), picker(state)])].concat(basic_controls(state)).concat(advanced))])
}

mode_name = |mode|
	match mode {
		LayeredMode => "Layered"
		TreeMode => "Tree"
		TreeRadialMode => "TreeRadial"
		CircularMode => "Circular"
		ForceMode => "Force"
		StressMode => "Stress"
		RadialMode => "Radial"
		ConstrainedMode => "Constrained"
		CompoundMode => "Compound"
	}

direction_name = |direction|
	match direction {
		Down => "Down"
		Up => "Up"
		Left => "Left"
		Right => "Right"
	}

error_view = |errors| if errors.is_empty() div([], []) else div([class("errors"), attribute("role", "alert")], errors.map(|message| p([], [text(message)])))

drawing_view = |drawing|
	match drawing {
		None => div([class("preview")], [p([], [text("Run an example to see its geometry.")])])
		Some(result) => div([class("preview")], [graph_svg(result), div([class("meta")], [text("${result.nodes.len().to_str()} nodes · ${result.routes.len().to_str()} routes")])])
	}

graph_svg : Drawing -> Html(Msg)
graph_svg = |drawing| {
	pad = 32.0
	view_box = "${(drawing.bounds.x - pad).to_str()} ${(drawing.bounds.y - pad).to_str()} ${(drawing.bounds.width + pad * 2.0).to_str()} ${(drawing.bounds.height + pad * 2.0).to_str()}"
	groups = drawing.groups.map(|rect| element("rect", [class("group"), attribute("x", rect.x.to_str()), attribute("y", rect.y.to_str()), attribute("width", rect.width.to_str()), attribute("height", rect.height.to_str()), attribute("rx", "16")], []))
	routes = drawing.routes.map(route_svg)
	nodes = drawing.positions.map_with_index(
		|point, index| {
			size = drawing.nodes.get(index) ?? { width: 0, height: 0 }
			name = drawing.labels.get(index) ?? index.to_str()
			[element("rect", [class("node"), attribute("x", (point.x - size.width / 2.0).to_str()), attribute("y", (point.y - size.height / 2.0).to_str()), attribute("width", size.width.to_str()), attribute("height", size.height.to_str()), attribute("rx", "8")], []), element("text", [class("label"), attribute("x", point.x.to_str()), attribute("y", (point.y + 4.0).to_str()), attribute("text-anchor", "middle")], [text(name)])]
		},
	).join()
	svg([class("graph"), attribute("viewBox", view_box), attribute("preserveAspectRatio", "xMidYMid meet"), attribute("role", "img"), aria("label", "Generated graph layout")], groups.concat(routes).concat(nodes))
}

route_svg : Route -> Html(Msg)
route_svg = |route| match route {
	Line(from, to) => element("line", [class("edge"), attribute("x1", from.x.to_str()), attribute("y1", from.y.to_str()), attribute("x2", to.x.to_str()), attribute("y2", to.y.to_str())], [])
	Polyline(points) => element("polyline", [class("edge"), attribute("points", Str.join_with(points.map(|point| "${point.x.to_str()},${point.y.to_str()}"), " "))], [])
	Curves(curves) => element("path", [class("edge"), attribute("d", Str.join_with(curves.map(|curve| "M ${curve.from.x.to_str()} ${curve.from.y.to_str()} C ${curve.ctl_a.x.to_str()} ${curve.ctl_a.y.to_str()}, ${curve.ctl_b.x.to_str()} ${curve.ctl_b.y.to_str()}, ${curve.to.x.to_str()} ${curve.to.y.to_str()}"), " "))], [])
}

result_view = |state|
	match state.drawing {
		None => div([], [])
		Some(drawing) => section([class("inspect")], [div([class("result")], [h3([], [text("Returned geometry")]), pre([], [code([], [text(drawing.result)])])])])
	}
