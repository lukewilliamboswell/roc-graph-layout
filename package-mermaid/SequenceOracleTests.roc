import Sequence
import SequenceOracle
import SequenceLayout
import Theme

## Independent expectations extracted from pinned Mermaid 12.2.0 records.
SequenceOracleTests :: {}

## Oracle semantics: basic.oracle.json
expect
	match Sequence.parse("sequenceDiagram\n    participant A as Alice\n    participant B as Bob\n    A->>B: Hello\n    B-->>A: World\n") {
		Err(_) => False
		Ok(diagram) => SequenceOracle.semantic(diagram) == "{\"participants\":[{\"id\":\"A\",\"label\":\"Alice\",\"actor\":false,\"wrap\":false},{\"id\":\"B\",\"label\":\"Bob\",\"actor\":false,\"wrap\":false}],\"events\":[{\"kind\":\"message\",\"from\":\"A\",\"to\":\"B\",\"text\":\"Hello\",\"dotted\":false,\"head\":\"arrow\",\"both\":false,\"activate\":false,\"wrap\":false},{\"kind\":\"message\",\"from\":\"B\",\"to\":\"A\",\"text\":\"World\",\"dotted\":true,\"head\":\"arrow\",\"both\":false,\"activate\":false,\"wrap\":false}],\"autonumber\":false,\"title\":\"\"}"
	}

## Oracle allocated boxes and full route controls: basic.oracle.json
expect
	match Sequence.parse("sequenceDiagram\n    participant A as Alice\n    participant B as Bob\n    A->>B: Hello\n    B-->>A: World\n") {
		Err(_) => False
		Ok(diagram) => {
			g = SequenceLayout.layout(diagram, Theme.Options.{})
			g.view == { x: -50, y: -10, width: 450, height: 323 } and (g.headers.get(0) ?? SequenceLayout.zero_rect) == { x: 0, y: 0, width: 150, height: 76 } and (g.headers.get(1) ?? SequenceLayout.zero_rect) == { x: 200, y: 0, width: 150, height: 76 } and (g.message_points.keep_if(|points| !points.is_empty()).get(0) ?? []) == [{ x: 76, y: 126 }, { x: 268, y: 126 }] and (g.message_points.keep_if(|points| !points.is_empty()).get(1) ?? []) == [{ x: 274, y: 176 }, { x: 82, y: 176 }]
		}
	}

## Oracle semantics: checkout.oracle.json
expect
	match Sequence.parse("sequenceDiagram\n    title Checkout with payment retry\n    autonumber\n    actor Customer\n    participant Shop as Checkout service\n    participant Pay as Payment provider\n    Customer->>Shop: Place an order\n    activate Shop\n    Note over Shop,Pay: All requests carry an idempotency key\n    loop Until accepted or retries exhausted\n        Shop->>+Pay: Authorize the card payment\n        alt Approved\n            Pay-->>-Shop: Authorization reference\n            Shop->>Shop: Persist the order and reserve stock\n        else Temporary failure\n            Pay-->>Shop: Please retry later\n        end\n    end\n    Shop-->>Customer: Order confirmation\n    deactivate Shop\n") {
		Err(_) => False
		Ok(diagram) => SequenceOracle.semantic(diagram) == "{\"participants\":[{\"id\":\"Customer\",\"label\":\"Customer\",\"actor\":true,\"wrap\":false},{\"id\":\"Shop\",\"label\":\"Checkout service\",\"actor\":false,\"wrap\":false},{\"id\":\"Pay\",\"label\":\"Payment provider\",\"actor\":false,\"wrap\":false}],\"events\":[{\"kind\":\"numbering\",\"visible\":true,\"start\":null,\"step\":null},{\"kind\":\"message\",\"from\":\"Customer\",\"to\":\"Shop\",\"text\":\"Place an order\",\"dotted\":false,\"head\":\"arrow\",\"both\":false,\"activate\":false,\"wrap\":false},{\"kind\":\"activate\",\"participant\":\"Shop\"},{\"kind\":\"note\",\"from\":\"Shop\",\"to\":\"Pay\",\"side\":\"over\",\"text\":\"All requests carry an idempotency key\",\"wrap\":false},{\"kind\":\"start\",\"block\":\"loop\",\"text\":\"Until accepted or retries exhausted\",\"wrap\":false},{\"kind\":\"message\",\"from\":\"Shop\",\"to\":\"Pay\",\"text\":\"Authorize the card payment\",\"dotted\":false,\"head\":\"arrow\",\"both\":false,\"activate\":true,\"wrap\":false},{\"kind\":\"activate\",\"participant\":\"Pay\"},{\"kind\":\"start\",\"block\":\"alt\",\"text\":\"Approved\",\"wrap\":false},{\"kind\":\"message\",\"from\":\"Pay\",\"to\":\"Shop\",\"text\":\"Authorization reference\",\"dotted\":true,\"head\":\"arrow\",\"both\":false,\"activate\":false,\"wrap\":false},{\"kind\":\"deactivate\",\"participant\":\"Pay\"},{\"kind\":\"message\",\"from\":\"Shop\",\"to\":\"Shop\",\"text\":\"Persist the order and reserve stock\",\"dotted\":false,\"head\":\"arrow\",\"both\":false,\"activate\":false,\"wrap\":false},{\"kind\":\"branch\",\"branch\":\"else\",\"text\":\"Temporary failure\",\"wrap\":false},{\"kind\":\"message\",\"from\":\"Pay\",\"to\":\"Shop\",\"text\":\"Please retry later\",\"dotted\":true,\"head\":\"arrow\",\"both\":false,\"activate\":false,\"wrap\":false},{\"kind\":\"end\",\"block\":\"alt\"},{\"kind\":\"end\",\"block\":\"loop\"},{\"kind\":\"message\",\"from\":\"Shop\",\"to\":\"Customer\",\"text\":\"Order confirmation\",\"dotted\":true,\"head\":\"arrow\",\"both\":false,\"activate\":false,\"wrap\":false},{\"kind\":\"deactivate\",\"participant\":\"Shop\"}],\"autonumber\":true,\"title\":\"Checkout with payment retry\"}"
	}

## Oracle allocated boxes and full route controls: checkout.oracle.json
expect
	match Sequence.parse("sequenceDiagram\n    title Checkout with payment retry\n    autonumber\n    actor Customer\n    participant Shop as Checkout service\n    participant Pay as Payment provider\n    Customer->>Shop: Place an order\n    activate Shop\n    Note over Shop,Pay: All requests carry an idempotency key\n    loop Until accepted or retries exhausted\n        Shop->>+Pay: Authorize the card payment\n        alt Approved\n            Pay-->>-Shop: Authorization reference\n            Shop->>Shop: Persist the order and reserve stock\n        else Temporary failure\n            Pay-->>Shop: Please retry later\n        end\n    end\n    Shop-->>Customer: Order confirmation\n    deactivate Shop\n") {
		Err(_) => False
		Ok(diagram) => {
			g = SequenceLayout.layout(diagram, Theme.Options.{})
			g.view == { x: -50, y: -50, width: 744.5, height: 798 } and (g.headers.get(0) ?? SequenceLayout.zero_rect) == { x: 0, y: 0, width: 150, height: 76 } and (g.headers.get(1) ?? SequenceLayout.zero_rect) == { x: 212, y: 0, width: 152, height: 76 } and (g.headers.get(2) ?? SequenceLayout.zero_rect) == { x: 491.5, y: 0, width: 153, height: 76 } and (g.message_points.keep_if(|points| !points.is_empty()).get(0) ?? []) == [{ x: 82, y: 126 }, { x: 281, y: 126 }] and (g.message_points.keep_if(|points| !points.is_empty()).get(1) ?? []) == [{ x: 299, y: 271 }, { x: 557, y: 271 }] and (g.message_points.keep_if(|points| !points.is_empty()).get(2) ?? []) == [{ x: 569, y: 366 }, { x: 299, y: 366 }] and (g.message_points.keep_if(|points| !points.is_empty()).get(3) ?? []) == [{ x: 293, y: 416 }, { x: 353, y: 406 }, { x: 353, y: 446 }, { x: 293, y: 436 }] and (g.message_points.keep_if(|points| !points.is_empty()).get(4) ?? []) == [{ x: 573, y: 541 }, { x: 299, y: 541 }] and (g.message_points.keep_if(|points| !points.is_empty()).get(5) ?? []) == [{ x: 289, y: 611 }, { x: 82, y: 611 }]
		}
	}

## Oracle semantics: nested-blocks.oracle.json
expect
	match Sequence.parse("sequenceDiagram\n    autonumber\n    par First operation\n        A->>B: Request\n        opt Cached\n            B-->>A: Cached response\n        end\n    and Second operation\n        A->>C: Other request\n        critical Reserve resource\n            C->>C: Acquire lock\n        option Resource unavailable\n            C-->>A: Retry\n        end\n    end\n") {
		Err(_) => False
		Ok(diagram) => SequenceOracle.semantic(diagram) == "{\"participants\":[{\"id\":\"A\",\"label\":\"A\",\"actor\":false,\"wrap\":false},{\"id\":\"B\",\"label\":\"B\",\"actor\":false,\"wrap\":false},{\"id\":\"C\",\"label\":\"C\",\"actor\":false,\"wrap\":false}],\"events\":[{\"kind\":\"numbering\",\"visible\":true,\"start\":null,\"step\":null},{\"kind\":\"start\",\"block\":\"par\",\"text\":\"First operation\",\"wrap\":false},{\"kind\":\"message\",\"from\":\"A\",\"to\":\"B\",\"text\":\"Request\",\"dotted\":false,\"head\":\"arrow\",\"both\":false,\"activate\":false,\"wrap\":false},{\"kind\":\"start\",\"block\":\"opt\",\"text\":\"Cached\",\"wrap\":false},{\"kind\":\"message\",\"from\":\"B\",\"to\":\"A\",\"text\":\"Cached response\",\"dotted\":true,\"head\":\"arrow\",\"both\":false,\"activate\":false,\"wrap\":false},{\"kind\":\"end\",\"block\":\"opt\"},{\"kind\":\"branch\",\"branch\":\"and\",\"text\":\"Second operation\",\"wrap\":false},{\"kind\":\"message\",\"from\":\"A\",\"to\":\"C\",\"text\":\"Other request\",\"dotted\":false,\"head\":\"arrow\",\"both\":false,\"activate\":false,\"wrap\":false},{\"kind\":\"start\",\"block\":\"critical\",\"text\":\"Reserve resource\",\"wrap\":false},{\"kind\":\"message\",\"from\":\"C\",\"to\":\"C\",\"text\":\"Acquire lock\",\"dotted\":false,\"head\":\"arrow\",\"both\":false,\"activate\":false,\"wrap\":false},{\"kind\":\"branch\",\"branch\":\"option\",\"text\":\"Resource unavailable\",\"wrap\":false},{\"kind\":\"message\",\"from\":\"C\",\"to\":\"A\",\"text\":\"Retry\",\"dotted\":true,\"head\":\"arrow\",\"both\":false,\"activate\":false,\"wrap\":false},{\"kind\":\"end\",\"block\":\"critical\"},{\"kind\":\"end\",\"block\":\"par\"}],\"autonumber\":true,\"title\":\"\"}"
	}

## Oracle allocated boxes and full route controls: nested-blocks.oracle.json
expect
	match Sequence.parse("sequenceDiagram\n    autonumber\n    par First operation\n        A->>B: Request\n        opt Cached\n            B-->>A: Cached response\n        end\n    and Second operation\n        A->>C: Other request\n        critical Reserve resource\n            C->>C: Acquire lock\n        option Resource unavailable\n            C-->>A: Retry\n        end\n    end\n") {
		Err(_) => False
		Ok(diagram) => {
			g = SequenceLayout.layout(diagram, Theme.Options.{})
			g.view == { x: -50, y: -10, width: 674, height: 758 } and (g.headers.get(0) ?? SequenceLayout.zero_rect) == { x: 0, y: 0, width: 150, height: 76 } and (g.headers.get(1) ?? SequenceLayout.zero_rect) == { x: 203, y: 0, width: 150, height: 76 } and (g.headers.get(2) ?? SequenceLayout.zero_rect) == { x: 403, y: 0, width: 150, height: 76 } and (g.message_points.keep_if(|points| !points.is_empty()).get(0) ?? []) == [{ x: 82, y: 171 }, { x: 271, y: 171 }] and (g.message_points.keep_if(|points| !points.is_empty()).get(1) ?? []) == [{ x: 283, y: 266 }, { x: 82, y: 266 }] and (g.message_points.keep_if(|points| !points.is_empty()).get(2) ?? []) == [{ x: 82, y: 371 }, { x: 471, y: 371 }] and (g.message_points.keep_if(|points| !points.is_empty()).get(3) ?? []) == [{ x: 479, y: 466 }, { x: 539, y: 456 }, { x: 539, y: 496 }, { x: 479, y: 486 }] and (g.message_points.keep_if(|points| !points.is_empty()).get(4) ?? []) == [{ x: 483, y: 591 }, { x: 82, y: 591 }]
		}
	}

## Oracle semantics: notes-and-arrows.oracle.json
expect
	match Sequence.parse("sequenceDiagram\n    actor User as System operator\n    participant API as Very long API participant name that should wrap cleanly\n    participant Worker\n    Note left of User: A note outside the first column\n    User->>API: Start a very long operation with a request label that wraps into several lines\n    API-)Worker: Asynchronous job\n    Worker-->>API: Completed\n    API<<-->>Worker: Synchronize\n    API--xWorker: Cancel obsolete work\n    Worker->>Worker: Persist retry state\n    Note right of Worker: A note outside the last column\n    Note over User,Worker: Shared context across the conversation\n    API-->>User: Result\n") {
		Err(_) => False
		Ok(diagram) => SequenceOracle.semantic(diagram) == "{\"participants\":[{\"id\":\"User\",\"label\":\"System operator\",\"actor\":true,\"wrap\":false},{\"id\":\"API\",\"label\":\"Very long API participant name that should wrap cleanly\",\"actor\":false,\"wrap\":false},{\"id\":\"Worker\",\"label\":\"Worker\",\"actor\":false,\"wrap\":false}],\"events\":[{\"kind\":\"note\",\"from\":\"User\",\"to\":\"User\",\"side\":\"left\",\"text\":\"A note outside the first column\",\"wrap\":false},{\"kind\":\"message\",\"from\":\"User\",\"to\":\"API\",\"text\":\"Start a very long operation with a request label that wraps into several lines\",\"dotted\":false,\"head\":\"arrow\",\"both\":false,\"activate\":false,\"wrap\":false},{\"kind\":\"message\",\"from\":\"API\",\"to\":\"Worker\",\"text\":\"Asynchronous job\",\"dotted\":false,\"head\":\"open\",\"both\":false,\"activate\":false,\"wrap\":false},{\"kind\":\"message\",\"from\":\"Worker\",\"to\":\"API\",\"text\":\"Completed\",\"dotted\":true,\"head\":\"arrow\",\"both\":false,\"activate\":false,\"wrap\":false},{\"kind\":\"message\",\"from\":\"API\",\"to\":\"Worker\",\"text\":\"Synchronize\",\"dotted\":true,\"head\":\"arrow\",\"both\":true,\"activate\":false,\"wrap\":false},{\"kind\":\"message\",\"from\":\"API\",\"to\":\"Worker\",\"text\":\"Cancel obsolete work\",\"dotted\":true,\"head\":\"cross\",\"both\":false,\"activate\":false,\"wrap\":false},{\"kind\":\"message\",\"from\":\"Worker\",\"to\":\"Worker\",\"text\":\"Persist retry state\",\"dotted\":false,\"head\":\"arrow\",\"both\":false,\"activate\":false,\"wrap\":false},{\"kind\":\"note\",\"from\":\"Worker\",\"to\":\"Worker\",\"side\":\"right\",\"text\":\"A note outside the last column\",\"wrap\":false},{\"kind\":\"note\",\"from\":\"User\",\"to\":\"Worker\",\"side\":\"over\",\"text\":\"Shared context across the conversation\",\"wrap\":false},{\"kind\":\"message\",\"from\":\"API\",\"to\":\"User\",\"text\":\"Result\",\"dotted\":true,\"head\":\"arrow\",\"both\":false,\"activate\":false,\"wrap\":false}],\"autonumber\":false,\"title\":\"\"}"
	}

## Oracle allocated boxes and full route controls: notes-and-arrows.oracle.json
expect
	match Sequence.parse("sequenceDiagram\n    actor User as System operator\n    participant API as Very long API participant name that should wrap cleanly\n    participant Worker\n    Note left of User: A note outside the first column\n    User->>API: Start a very long operation with a request label that wraps into several lines\n    API-)Worker: Asynchronous job\n    Worker-->>API: Completed\n    API<<-->>Worker: Synchronize\n    API--xWorker: Cancel obsolete work\n    Worker->>Worker: Persist retry state\n    Note right of Worker: A note outside the last column\n    Note over User,Worker: Shared context across the conversation\n    API-->>User: Result\n") {
		Err(_) => False
		Ok(diagram) => {
			g = SequenceLayout.layout(diagram, Theme.Options.{})
			g.view == { x: -252, y: -10, width: 1635.5, height: 753 } and (g.headers.get(0) ?? SequenceLayout.zero_rect) == { x: 0, y: 0, width: 150, height: 76 } and (g.headers.get(1) ?? SequenceLayout.zero_rect) == { x: 491.5, y: 0, width: 443, height: 76 } and (g.headers.get(2) ?? SequenceLayout.zero_rect) == { x: 984.5, y: 0, width: 150, height: 76 } and (g.message_points.keep_if(|points| !points.is_empty()).get(0) ?? []) == [{ x: 76, y: 176 }, { x: 706, y: 176 }] and (g.message_points.keep_if(|points| !points.is_empty()).get(1) ?? []) == [{ x: 714, y: 226 }, { x: 1052.5, y: 226 }] and (g.message_points.keep_if(|points| !points.is_empty()).get(2) ?? []) == [{ x: 1058.5, y: 276 }, { x: 720, y: 276 }] and (g.message_points.keep_if(|points| !points.is_empty()).get(3) ?? []) == [{ x: 720, y: 326 }, { x: 1052.5, y: 326 }] and (g.message_points.keep_if(|points| !points.is_empty()).get(4) ?? []) == [{ x: 714, y: 376 }, { x: 1052.5, y: 376 }] and (g.message_points.keep_if(|points| !points.is_empty()).get(5) ?? []) == [{ x: 1060.5, y: 426 }, { x: 1120.5, y: 416 }, { x: 1120.5, y: 456 }, { x: 1060.5, y: 446 }] and (g.message_points.keep_if(|points| !points.is_empty()).get(6) ?? []) == [{ x: 712, y: 606 }, { x: 82, y: 606 }]
		}
	}

## Oracle semantics: numbering.oracle.json
expect
	match Sequence.parse("sequenceDiagram\n    A->>B: Before numbering\n    autonumber 3 0.5\n    A->>B: First numbered call\n    autonumber off\n    B-->>A: Hidden number\n    autonumber\n    A->>B: Numbering resumes\n") {
		Err(_) => False
		Ok(diagram) => SequenceOracle.semantic(diagram) == "{\"participants\":[{\"id\":\"A\",\"label\":\"A\",\"actor\":false,\"wrap\":false},{\"id\":\"B\",\"label\":\"B\",\"actor\":false,\"wrap\":false}],\"events\":[{\"kind\":\"message\",\"from\":\"A\",\"to\":\"B\",\"text\":\"Before numbering\",\"dotted\":false,\"head\":\"arrow\",\"both\":false,\"activate\":false,\"wrap\":false},{\"kind\":\"numbering\",\"visible\":true,\"start\":3,\"step\":0.5},{\"kind\":\"message\",\"from\":\"A\",\"to\":\"B\",\"text\":\"First numbered call\",\"dotted\":false,\"head\":\"arrow\",\"both\":false,\"activate\":false,\"wrap\":false},{\"kind\":\"numbering\",\"visible\":false,\"start\":null,\"step\":null},{\"kind\":\"message\",\"from\":\"B\",\"to\":\"A\",\"text\":\"Hidden number\",\"dotted\":true,\"head\":\"arrow\",\"both\":false,\"activate\":false,\"wrap\":false},{\"kind\":\"numbering\",\"visible\":true,\"start\":null,\"step\":null},{\"kind\":\"message\",\"from\":\"A\",\"to\":\"B\",\"text\":\"Numbering resumes\",\"dotted\":false,\"head\":\"arrow\",\"both\":false,\"activate\":false,\"wrap\":false}],\"autonumber\":true,\"title\":\"\"}"
	}

## Oracle allocated boxes and full route controls: numbering.oracle.json
expect
	match Sequence.parse("sequenceDiagram\n    A->>B: Before numbering\n    autonumber 3 0.5\n    A->>B: First numbered call\n    autonumber off\n    B-->>A: Hidden number\n    autonumber\n    A->>B: Numbering resumes\n") {
		Err(_) => False
		Ok(diagram) => {
			g = SequenceLayout.layout(diagram, Theme.Options.{})
			g.view == { x: -50, y: -10, width: 473, height: 423 } and (g.headers.get(0) ?? SequenceLayout.zero_rect) == { x: 0, y: 0, width: 150, height: 76 } and (g.headers.get(1) ?? SequenceLayout.zero_rect) == { x: 223, y: 0, width: 150, height: 76 } and (g.message_points.keep_if(|points| !points.is_empty()).get(0) ?? []) == [{ x: 76, y: 126 }, { x: 291, y: 126 }] and (g.message_points.keep_if(|points| !points.is_empty()).get(1) ?? []) == [{ x: 82, y: 176 }, { x: 291, y: 176 }] and (g.message_points.keep_if(|points| !points.is_empty()).get(2) ?? []) == [{ x: 297, y: 226 }, { x: 82, y: 226 }] and (g.message_points.keep_if(|points| !points.is_empty()).get(3) ?? []) == [{ x: 82, y: 276 }, { x: 291, y: 276 }]
		}
	}

## Oracle semantics: semicolon-entities.oracle.json
expect
	match Sequence.parse("sequenceDiagram;A->>B: hello#59; world;B-->>A: #35;42 and #quot;yes#quot;;\n") {
		Err(_) => False
		Ok(diagram) => SequenceOracle.semantic(diagram) == "{\"participants\":[{\"id\":\"A\",\"label\":\"A\",\"actor\":false,\"wrap\":false},{\"id\":\"B\",\"label\":\"B\",\"actor\":false,\"wrap\":false}],\"events\":[{\"kind\":\"message\",\"from\":\"A\",\"to\":\"B\",\"text\":\"hello; world\",\"dotted\":false,\"head\":\"arrow\",\"both\":false,\"activate\":false,\"wrap\":false},{\"kind\":\"message\",\"from\":\"B\",\"to\":\"A\",\"text\":\"#42 and \\\"yes\\\"\",\"dotted\":true,\"head\":\"arrow\",\"both\":false,\"activate\":false,\"wrap\":false}],\"autonumber\":false,\"title\":\"\"}"
	}

## Oracle semantics: source-wrap.oracle.json
expect
	match Sequence.parse("sequenceDiagram\n    participant A as wrap: A participant whose descriptive name needs several lines\n    participant B as nowrap: A participant kept on one line\n    A->>B: wrap: A long operation label whose words must wrap into the available message width without changing the text\n    Note right of B: wrap: A note with enough descriptive text to wrap into a narrow note box\n    B-->>A: nowrap: An explicit one line response\n") {
		Err(_) => False
		Ok(diagram) => SequenceOracle.semantic(diagram) == "{\"participants\":[{\"id\":\"A\",\"label\":\"A participant whose descriptive name needs several lines\",\"actor\":false,\"wrap\":true},{\"id\":\"B\",\"label\":\"A participant kept on one line\",\"actor\":false,\"wrap\":false}],\"events\":[{\"kind\":\"message\",\"from\":\"A\",\"to\":\"B\",\"text\":\"A long operation label whose words must wrap into the available message width without changing the text\",\"dotted\":false,\"head\":\"arrow\",\"both\":false,\"activate\":false,\"wrap\":true},{\"kind\":\"note\",\"from\":\"B\",\"to\":\"B\",\"side\":\"right\",\"text\":\"A note with enough descriptive text to wrap into a narrow note box\",\"wrap\":true},{\"kind\":\"message\",\"from\":\"B\",\"to\":\"A\",\"text\":\"An explicit one line response\",\"dotted\":true,\"head\":\"arrow\",\"both\":false,\"activate\":false,\"wrap\":false}],\"autonumber\":false,\"title\":\"\"}"
	}

## Oracle allocated boxes and full route controls: source-wrap.oracle.json
expect
	match Sequence.parse("sequenceDiagram\n    participant A as wrap: A participant whose descriptive name needs several lines\n    participant B as nowrap: A participant kept on one line\n    A->>B: wrap: A long operation label whose words must wrap into the available message width without changing the text\n    Note right of B: wrap: A note with enough descriptive text to wrap into a narrow note box\n    B-->>A: nowrap: An explicit one line response\n") {
		Err(_) => False
		Ok(diagram) => {
			g = SequenceLayout.layout(diagram, Theme.Options.{})
			g.view == { x: -50, y: -10, width: 637, height: 653 } and (g.headers.get(0) ?? SequenceLayout.zero_rect) == { x: 0, y: 0, width: 150, height: 156 } and (g.headers.get(1) ?? SequenceLayout.zero_rect) == { x: 241.5, y: 0, width: 241, height: 156 } and (g.message_points.keep_if(|points| !points.is_empty()).get(0) ?? []) == [{ x: 76, y: 246 }, { x: 355, y: 246 }] and (g.message_points.keep_if(|points| !points.is_empty()).get(1) ?? []) == [{ x: 361, y: 426 }, { x: 82, y: 426 }]
		}
	}

## Injected widths are real participant input sizes, including narrow boxes.
expect
	match Sequence.parse("sequenceDiagram\nA->>B: Hi\n") {
		Err(_) => False
		Ok(diagram) => {
			g = SequenceLayout.layout_with_sizes(diagram, Theme.Options.{}, [{ kind: "node", id: "A", width: 240, height: 120 }, { kind: "node", id: "B", width: 100, height: 70 }])
			g.widths == [240, 100] and g.header_height == 120 and g.centers == [120, 340]
		}
	}

## Unsupported size kinds and output-only label roles are reported explicitly.
expect {
	source = "sequenceDiagram\nA->>B: Hi\n"
	SequenceOracle.inspect_sized(source, Theme.Options.{}, [{ kind: "route", id: "message-0", width: 10, height: 10 }]).contains("size_problems") and SequenceOracle.inspect_sized(source, Theme.Options.{}, [{ kind: "label", id: "participant-footer-A", width: 10, height: 10 }]).contains("unconsumed label:participant-footer-A")
}
