import Flowchart

## Index-aligned state-machine data shared by its reader and drawing phases.
StateModel :: {}.{
	Kind : [Normal, Initial, Final, Choice, Fork, Join]
	State : { id : Str, label : Str, descriptions : List(Str), kind : Kind, effective_kind : Kind, container : Flowchart.Container, classes : List(Str), styles : List(Str) }
	Group : { id : Str, title : Str, descriptions : List(Str), container : Flowchart.Container, direction : [Inherit, Set(Flowchart.Direction)], classes : List(Str), styles : List(Str) }
	Transition : { from : Flowchart.Endpoint, to : Flowchart.Endpoint, label : Str }
	Note : { state : Flowchart.Endpoint, side : [Left, Right], text : Str, after_transition : U64 }
	Declaration : [State(Str), Composite(Str), Note(U64)]
	Diagram : { declarations : List(Declaration), direction : Flowchart.Direction, states : List(State), transitions : List(Transition), groups : List(Group), classes : List(Flowchart.ClassDef), notes : List(Note) }
	state_id : Diagram, State -> Str
	state_id = |diagram, state| match state.kind {
		Initial | Final => {
			scope = match state.container {
				Root => "root"
				Group(i) => (diagram.groups.get(i) ?? { id: "", title: "", descriptions: [], container: Root, direction: Inherit, classes: [], styles: [] }).id
			}
			"${scope}_${if (state.kind == Initial) "start" else "end"}"
		}
		_ => state.id
	}

	endpoint_id : Diagram, Flowchart.Endpoint -> Str
	endpoint_id = |diagram, endpoint| match endpoint {
		Node(i) => match diagram.states.get(i) {
			Ok(state) => StateModel.state_id(diagram, state)
			Err(_) => ""
		}
		Group(i) => (diagram.groups.get(i) ?? { id: "", title: "", descriptions: [], container: Root, direction: Inherit, classes: [], styles: [] }).id
	}

}
