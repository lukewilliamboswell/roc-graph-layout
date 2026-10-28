## Internal structural vocabulary. The public Sequence signatures check this
## representation against its documented types without creating import cycles.
SequenceData :: {}.{
	Participant : { id : Str, label : Str, actor : Bool, wrap : Bool, source_text : Str }
	Message : { from : U64, to : U64, text : Str, dotted : Bool, head : [None, Arrow, Open, Cross], both : Bool, activation : [Keep, Start, Stop], wrap : Bool, source_text : Str }
	Note : { from : U64, to : U64, text : Str, side : [Left, Right, Over], wrap : Bool, source_text : Str }
	Event : [Message(Message), Note(Note), Activate(U64), Deactivate(U64), StartBlock({ kind : Str, text : Str, wrap : Bool, source_text : Str }), Branch({ kind : Str, text : Str, wrap : Bool, source_text : Str }), Numbering({ visible : Bool, start : [None, Some(F64)], step : [None, Some(F64)] }), EndBlock]
	Diagram : { participants : List(Participant), events : List(Event), autonumber : Bool, title : Str }
}
