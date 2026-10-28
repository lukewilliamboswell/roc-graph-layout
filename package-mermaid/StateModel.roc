import Flowchart

## Index-aligned state-machine data shared by its reader and drawing phases.
StateModel :: {}.{
	Kind : [Normal, Initial, Final, Choice, Fork, Join]
	State : { id : Str, label : Str, descriptions : List(Str), kind : Kind, container : Flowchart.Container, classes : List(Str), styles : List(Str) }
	Transition : { from : Flowchart.Endpoint, to : Flowchart.Endpoint, label : Str }
	Note : { state : Flowchart.Endpoint, side : [Left, Right], text : Str }
	Diagram : { direction : Flowchart.Direction, states : List(State), transitions : List(Transition), groups : List(Flowchart.Group), classes : List(Flowchart.ClassDef), notes : List(Note) }
}
