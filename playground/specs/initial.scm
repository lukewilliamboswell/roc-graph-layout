(test "Playground initial pipeline"
  (steps
    (expect-visible (role heading :name "Graph layout playground"))
    (expect-value (label "Example") "pipeline")
    (expect-value (label "Layout") "Layered")
    (expect-text (test-id "errors") "")
    (expect-text (test-id "geometry-summary") "7 nodes · 8 routes")))
