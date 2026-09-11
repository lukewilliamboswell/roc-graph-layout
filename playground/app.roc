app [main] {
	pf: platform "https://github.com/lukewilliamboswell/roc-signals/releases/download/0.2.0-rc3/HVTvH6n1bcFccyLz5xtdpjRrStMa2T6CmHQRiuTtTs6F.tar.zst",
	roc: "nightly-2026-09-04-c125b82",
	layout: "../package/main.roc",
	fixtures: "../examples/data/main.roc",
	rvn: "https://cdn.jasperwoudenberg.com/roc-rvn-v1.0.0-rc.2/8dArudMEhMfr4NTu1efFiFz5aCKMvSAmSspZctxFgZti.tar.zst",
}
import fixtures.ExampleData
import LayoutDemo
import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal exposing [Signal]
import pf.Svg
import pf.Ui
import rvn.Rvn

Point : LayoutDemo.Point

Rect : LayoutDemo.Rect

Node : LayoutDemo.Node

Edge : LayoutDemo.Edge

Route : LayoutDemo.Route

Doc : LayoutDemo.Doc

Example : [Pipeline, Org, Ring, Mind, Collaboration, Incident, Cloud, Release, Transit]

Mode : LayoutDemo.Mode

NumberField : [NodeGap, LayerGap, RingGap, StartAngle, Iterations, Tolerance, Repulsion, Gravity, Sweeps, Seed]

Config : LayoutDemo.Config

Drawing : LayoutDemo.Drawing

State : { example : Example, draft : Str, mode : Mode, config : Config, revision : U64 }

Model : { version : Str, states : List(State), selected : Example, examples_open : Bool }

Msg : [Choose(Example), Edit(Str), ChooseMode(Str), SetNumber(NumberField, Str), SetDirection(Str), SetClockwise(Bool), SetExact(Bool), Run, Reset, ToggleExamples]

default_config : Config
default_config = { node_gap: 24, layer_gap: 70, ring_gap: 60, start_angle: -1.5707963267948966, iterations: 300, tolerance: 0.01, repulsion: 1, gravity: 0.05, sweeps: 4, seed: 0, direction: Down, clockwise: Bool.True, exact: Bool.True }

examples = [Pipeline, Org, Ring, Mind, Collaboration, Incident, Cloud, Release, Transit]

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

initial_state = |example| { example, draft: encode(preset(example)), mode: (meta(example)).mode, config: default_config, revision: 0 }

init : Str -> Model
init = |version| {
	model = { version, states: examples.map(initial_state), selected: Pipeline, examples_open: Bool.False }
	run_model(model)
}

current = |model| model.states.find_first(|state| state.example == model.selected) ?? initial_state(Pipeline)

map_current = |model, change| { ..model, states: model.states.map(|state| if state.example == model.selected change(state) else state) }

run_model = |model| map_current(model, run_state)

update : Model, Msg -> Model
update = |model, msg| match msg {
	Choose(example) => { ..model, selected: example, examples_open: Bool.False }
	Edit(draft) => run_model(map_current(model, |state| { ..state, draft }))
	ChooseMode(raw) => run_model(map_current(model, |state| { ..state, mode: mode_from_str(raw, state.mode) }))
	SetNumber(field, raw) => run_model(map_current(model, |state| { ..state, config: set_number(state.config, field, raw) }))
	SetDirection(raw) => run_model(map_current(model, |state| { ..state, config: { ..state.config, direction: direction_from_str(raw) } }))
	SetClockwise(on) => run_model(map_current(model, |state| { ..state, config: { ..state.config, clockwise: on } }))
	SetExact(on) => run_model(map_current(model, |state| { ..state, config: { ..state.config, exact: on } }))
	Run => run_model(model)
	Reset => {
		reset = initial_state(model.selected)
		run_model({ ..model, states: model.states.map(|state| if state.example == model.selected reset else state) })
	}
	ToggleExamples => { ..model, examples_open: !model.examples_open }
}

run_state : State -> State
run_state = |state| { ..state, revision: state.revision + 1 }

run_layout : Mode, Str, Config -> Try(Drawing, List(Str))
run_layout = |mode, draft, config| LayoutDemo.run_layout(mode, draft, config)

mode_from_str = |raw, fallback|
	match raw {
		"Layered" => LayeredMode
		"Constrained" => ConstrainedMode
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

## Tree adaptation restores source node and edge order after depth-first layout.
expect {
	doc : Doc
	doc = { labels: ["root", "left", "right", "leaf"], graph: { nodes: List.repeat({ width: 10, height: 10 }, 4), edges: [{ from: 0, to: 2 }, { from: 0, to: 1 }, { from: 1, to: 3 }] } }
	points = [{ x: 0, y: 0 }, { x: 1, y: 0 }, { x: 3, y: 0 }, { x: 2, y: 0 }]
	tree_routes = [Line(points.get(0)?, points.get(1)?), Line(points.get(1)?, points.get(2)?), Line(points.get(0)?, points.get(3)?)]
	geometry = LayoutDemo.tree_geometry(doc, { positions: points, routes: tree_routes, bounds: { x: 0, y: 0, width: 10, height: 10 } })
	source_routes = [tree_routes.get(2)?, tree_routes.get(0)?, tree_routes.get(1)?]
	geometry.positions.map(|point| point.x) == [0, 1, 2, 3] and geometry.routes == source_routes
}

## Tree mode derives a spanning hierarchy from disconnected and multi-parent input.
expect {
	nodes = List.repeat({ width: 10, height: 10 }, 3)
	disconnected : Doc
	disconnected = { labels: ["A", "B", "C"], graph: { nodes, edges: [{ from: 0, to: 1 }] } }
	multiple : Doc
	multiple = { labels: disconnected.labels, graph: { nodes, edges: [{ from: 0, to: 1 }, { from: 0, to: 2 }, { from: 1, to: 2 }] } }
	LayoutDemo.tree_problems(disconnected).is_empty() and LayoutDemo.tree_problems(multiple).is_empty() and LayoutDemo.tree_edges(disconnected) == [{ from: 0, to: 1 }, { from: 0, to: 2 }] and LayoutDemo.tree_edges(multiple) == [{ from: 0, to: 1 }, { from: 0, to: 2 }]
}

main : () -> Elem
main = || Ui.state((init("dev")), view)

html : Str, List(Html.Attr), List(Elem) -> Elem
html = |tag, attrs, children| Elem.Element({ namespace: Html, tag, attrs, children })

panel : Str, List(Elem) -> Elem
panel = |classes, children| Html.div([Html.class_attr(classes)], children)

heading : Str, Str -> Elem
heading = |tag, title| html(tag, [], [Html.text(title)])

dispatch : Ui.State(Model), Msg -> _
dispatch = |state, message| state.on_unit(|model| (update(model, message)))

view : Ui.State(Model) -> Elem
view = |model| {
	state = Signal.map(model.signal(), current)
	result = Signal.map(state, |value| run_layout(value.mode, value.draft, value.config))
	drawing = Signal.map(
		result,
		|value| match value {
			Ok(item) => Some(item)
			Err(_) => None
		},
	)
	Html.div(
		[Html.class_attr("shell")],
		[
			panel(
				"intro",
				[
					panel(
						"intro-copy",
						[
							Html.paragraph_attrs("INTERACTIVE EXAMPLES", [Html.class_attr("eyebrow")]),
							heading("h1", "Graph layout playground"),
							Html.paragraph("Explore a layout. Change the graph. See how the geometry responds."),
						],
					),
					html(
						"label",
						[Html.class_attr("example-picker")],
						[
							Html.text("Choose an example"),
							Html.select(
								"Example",
								Signal.map(model.signal(), |value| example_key(value.selected)),
								examples.map(|example| Html.option(example_key(example), (meta(example)).title)),
								model.on_str(
									|value, raw| {
										chosen = examples.find_first(|example| example_key(example) == raw) ?? crash "Unknown example selection"
										(update(value, Choose(chosen)))
									},
								),
							),
						],
					),
				],
			),
			panel(
				"workspace",
				[
					panel(
						"toolbar",
						[
							panel(
								"workspace-title",
								[
									html("h2", [], [Html.text_s(Signal.map(state, |value| (meta(value.example)).title))]),
									html("p", [], [Html.text_s(Signal.map(state, |value| (meta(value.example)).note))]),
								],
							),
							panel(
								"actions",
								[
									Html.button_c("Reset", "secondary", dispatch(model, Reset)),
									Html.button_c("Run layout", "primary", dispatch(model, Run)),
								],
							),
						],
					),
					panel(
						"grid",
						[
							panel(
								"data-panel",
								[
									controls(model, state),
									heading("h3", "Graph data (RVN)"),
									Html.textarea_attrs("Graph data in RVN", Signal.map(state, |value| value.draft), [Html.class_attr("editor"), Html.attr("spellcheck", "false")], model.on_str(|value, raw| (update(value, Edit(raw))))),
									Html.paragraph_attrs("Edits update the preview automatically.", [Html.class_attr("field-note")]),
								],
							),
							panel(
								"visual-panel",
								[
									panel("section-heading", [heading("h3", "SVG preview"), html("span", [Html.class_attr("live-badge")], [Html.text("Live preview")])]),
									Html.paragraph_s_attrs(
										Signal.map(
											result,
											|value| match value {
												Err(errors) => Str.join_with(errors, "\n")
												Ok(_) => ""
											},
										),
										[Html.class_attr("errors"), Html.attr("role", "alert"), Html.test_id("errors")],
									),
									Ui.switch(drawing, drawing_view),
								],
							),
						],
					),
					html(
						"details",
						[Html.class_attr("inspect")],
						[
							html("summary", [], [Html.text("Returned geometry"), html("span", [], [Html.text("Positions, routes & bounds")])]),
							Html.pre_s_c(
								Signal.map(
									drawing,
									|value| match value {
										Some(item) => item.result
										None => ""
									},
								),
								"result",
							),
						],
					),
				],
			),
		],
	)
}

number_value : Config, NumberField -> Str
number_value = |config, field| match field {
	NodeGap => config.node_gap.to_str()
	LayerGap => config.layer_gap.to_str()
	RingGap => config.ring_gap.to_str()
	StartAngle => config.start_angle.to_str()
	Iterations => config.iterations.to_str()
	Tolerance => config.tolerance.to_str()
	Repulsion => config.repulsion.to_str()
	Gravity => config.gravity.to_str()
	Sweeps => config.sweeps.to_str()
	Seed => config.seed.to_str()
}

range_for = |field| match field {
	NodeGap => { min: "0", max: "120", step: "1" }
	LayerGap => { min: "0", max: "240", step: "1" }
	RingGap => { min: "0", max: "240", step: "1" }
	StartAngle => { min: "-3.15", max: "3.15", step: "0.05" }
	Iterations => { min: "10", max: "2000", step: "10" }
	Tolerance => { min: "0.001", max: "1", step: "0.001" }
	Repulsion => { min: "0", max: "5", step: "0.05" }
	Gravity => { min: "0", max: "1", step: "0.01" }
	Sweeps => { min: "0", max: "20", step: "1" }
	Seed => { min: "0", max: "1000", step: "1" }
}

number : Ui.State(Model), Signal(State), Str, NumberField -> Elem
number = |model, state, title, field| {
	input_value = Signal.map(state, |current_state| number_value(current_state.config, field))
	output_value = Signal.map(state, |current_state| number_value(current_state.config, field))
	range = range_for(field)
	html(
		"label",
		[Html.class_attr("control")],
		[
			panel("control-heading", [Html.text(title), html("output", [Html.class_attr("control-value")], [Html.text_s(output_value)])]),
			html("input", [Html.attr("type", "range"), Html.attr("role", "slider"), Html.aria_label(title), Html.attr("min", range.min), Html.attr("max", range.max), Html.attr("step", range.step), Html.attr_s("value", input_value), Html.on_custom("input", model.on_str(|current_model, raw| (update(current_model, SetNumber(field, raw)))))], []),
		],
	)
}

controls : Ui.State(Model), Signal(State) -> Elem
controls = |model, state| panel(
	"settings",
	[
		html("label", [Html.class_attr("control layout-control")], [Html.text("Layout algorithm"), Html.select("Layout", Signal.map(state, |value| mode_name(value.mode)), ["Layered", "Tree", "TreeRadial", "Circular", "Force", "Stress", "Radial", "Constrained"].map(|name| Html.option(name, name)), model.on_str(|value, raw| (update(value, ChooseMode(raw)))))]),
		Ui.switch(
			Signal.map(state, |value| value.mode),
			|mode| {
				fields : List((Str, NumberField))
				fields = match mode {
					LayeredMode => [("Node gap", NodeGap), ("Layer gap", LayerGap), ("Ordering sweeps", Sweeps)]
					TreeMode => [("Level gap", LayerGap)]
					TreeRadialMode => [("Ring gap", RingGap), ("Start angle", StartAngle)]
					CircularMode => [("Node gap", NodeGap), ("Start angle", StartAngle)]
					RadialMode => [("Node gap", NodeGap), ("Ring gap", RingGap), ("Start angle", StartAngle)]
					ForceMode => [("Node gap", NodeGap), ("Repulsion", Repulsion), ("Gravity", Gravity), ("Maximum iterations", Iterations), ("Tolerance", Tolerance), ("Seed", Seed)]
					StressMode | ConstrainedMode => [("Node gap", NodeGap), ("Maximum iterations", Iterations), ("Tolerance", Tolerance), ("Seed", Seed)]
					CompoundMode => []
				}
				direction = if mode == LayeredMode or mode == TreeMode [
					html("label", [Html.class_attr("control")], [Html.text("Direction"), Html.select("Direction", Signal.map(state, |value| direction_name(value.config.direction)), ["Down", "Up", "Left", "Right"].map(|name| Html.option(name, name)), model.on_str(|value, raw| (update(value, SetDirection(raw)))))]),
				] else []
				winding = if mode == TreeRadialMode or mode == CircularMode or mode == RadialMode [
					html("label", [Html.class_attr("check")], [Html.checkbox("Clockwise", Signal.map(state, |value| value.config.clockwise), model.on_bool(|value, on| (update(value, SetClockwise(on))))), Html.text("Clockwise")]),
				] else []
				exact = if mode == StressMode [
					html("label", [Html.class_attr("check")], [Html.checkbox("Exact stress", Signal.map(state, |value| value.config.exact), model.on_bool(|value, on| (update(value, SetExact(on))))), Html.text("Exact stress")]),
				] else []
				panel("controls", fields.map(|field| number(model, state, field.0, field.1)).concat(direction).concat(winding).concat(exact))
			},
		),
	],
)

drawing_view : [Some(Drawing), None] -> Elem
drawing_view = |drawing| match drawing {
	None => panel("preview", [Html.text("Enter valid graph data and settings to see its geometry.")])
	Some(result) => panel(
		"preview",
		[
			graph_svg(result),
			Html.paragraph_attrs("${result.nodes.len().to_str()} nodes · ${result.routes.len().to_str()} routes", [Html.test_id("geometry-summary")]),
		],
	)
}

graph_svg : Drawing -> Elem
graph_svg = |drawing| {
	pad = 32.0
	view_box = "${(drawing.bounds.x - pad).to_str()} ${(drawing.bounds.y - pad).to_str()} ${(drawing.bounds.width + pad * 2.0).to_str()} ${(drawing.bounds.height + pad * 2.0).to_str()}"
	groups = drawing.groups.map(|rect| Svg.element("rect", [Html.class_attr("group"), Html.attr("x", rect.x.to_str()), Html.attr("y", rect.y.to_str()), Html.attr("width", rect.width.to_str()), Html.attr("height", rect.height.to_str()), Html.attr("rx", "16")], []))
	routes = drawing.routes.map(route_svg)
	nodes = drawing.positions.map_with_index(
		|point, index| {
			size = drawing.nodes.get(index) ?? { width: 0, height: 0 }
			name = drawing.labels.get(index) ?? index.to_str()
			[Svg.element("rect", [Html.class_attr("node"), Html.attr("x", (point.x - size.width / 2.0).to_str()), Html.attr("y", (point.y - size.height / 2.0).to_str()), Html.attr("width", size.width.to_str()), Html.attr("height", size.height.to_str()), Html.attr("rx", "8")], []), Svg.element("text", [Html.class_attr("label"), Html.attr("x", point.x.to_str()), Html.attr("y", (point.y + 4.0).to_str()), Html.attr("text-anchor", "middle")], [Html.text(name)])]
		},
	).join()
	Svg.svg([Html.class_attr("graph"), Html.attr("viewBox", view_box), Html.attr("preserveAspectRatio", "xMidYMid meet"), Html.attr("role", "img"), Html.aria_label("Generated graph layout")], groups.concat(routes).concat(nodes))
}

route_svg : Route -> Elem
route_svg = |route| match route {
	Line(from, to) => Svg.element("line", [Html.class_attr("edge"), Html.attr("x1", from.x.to_str()), Html.attr("y1", from.y.to_str()), Html.attr("x2", to.x.to_str()), Html.attr("y2", to.y.to_str())], [])
	Polyline(points) => Svg.element("polyline", [Html.class_attr("edge"), Html.attr("points", Str.join_with(points.map(|point| "${point.x.to_str()},${point.y.to_str()}"), " "))], [])
	Curves(curves) => Svg.element("path", [Html.class_attr("edge"), Html.attr("d", Str.join_with(curves.map(|curve| "M ${curve.from.x.to_str()} ${curve.from.y.to_str()} C ${curve.ctl_a.x.to_str()} ${curve.ctl_a.y.to_str()}, ${curve.ctl_b.x.to_str()} ${curve.ctl_b.y.to_str()}, ${curve.to.x.to_str()} ${curve.to.y.to_str()}"), " "))], [])
}
