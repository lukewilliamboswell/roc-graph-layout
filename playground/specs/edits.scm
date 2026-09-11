(test "Graph edits, validation, and per-example state"
  (steps
    (fill (label "Graph data in RVN") "{ labels: [\"A\"], graph: { nodes: [{ width: 90, height: 40 }], edges: [] } }")
    (expect-text (test-id "geometry-summary") "1 nodes · 0 routes")
    (select-option (label "Example") "ring")
    (expect-text (test-id "geometry-summary") "8 nodes · 9 routes")
    (select-option (label "Example") "pipeline")
    (expect-text (test-id "geometry-summary") "1 nodes · 0 routes")
    (fill (label "Graph data in RVN") "invalid")
    (expect-text (test-id "errors") "The graph data is not valid RVN for labels, nodes, and edges.")
    (expect-absent (test-id "geometry-summary"))
    (click (role button :name "Reset"))
    (expect-text (test-id "errors") "")
    (expect-text (test-id "geometry-summary") "7 nodes · 8 routes")))
