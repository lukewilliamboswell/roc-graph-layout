## Internal structural vocabulary. The public Sequence signatures check this
## representation against its documented types without creating import cycles.
SequenceData :: {}.{
	Participant : { id : Str, label : Str, actor : Bool }
	Message : { from : U64, to : U64, text : Str, dotted : Bool, head : [None, Arrow, Open, Cross], both : Bool, activation : [Keep, Start, Stop] }
	Note : { from : U64, to : U64, text : Str, side : [Left, Right, Over] }
	Event : [Message(Message), Note(Note), Activate(U64), Deactivate(U64), StartBlock({ kind : Str, text : Str }), Branch({ kind : Str, text : Str }), EndBlock]
	Diagram : { participants : List(Participant), events : List(Event), autonumber : Bool, title : Str }
}
