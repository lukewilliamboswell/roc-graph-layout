app [target] {
	font: "https://github.com/lukewilliamboswell/roc-font/releases/download/0.1.0-rc2/A14BmicBaf6dm4K9kdYH9j8Y6BoAZrpUmxWh9sojsFy5.tar.zst",
	fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.3/41NK5FShyGC9Z8HNpUdUeXMWwLmLNfFxsfmLvdPL4Fxb.tar.zst",
	layout: "../package/main.roc",
}

import fuzz.Fuzz
import Drawing
import Sequence
import SequenceDraw
import Svg
import Theme

target = Fuzz.target_with({ name: "sequence contract", generator: Fuzz.raw_bytes, test: verify, show: |bytes| Str.inspect(Str.from_utf8_lossy(bytes)) })

## Accepted source must draw deterministically with finite positions and
## one participant column and event row per source item. Invalid arbitrary
## bytes must produce ordinary parse problems, never a partial drawing.
verify : List(U8) -> Fuzz.Outcome
verify = |bytes| {
	source = Str.from_utf8_lossy(bytes)
	match Sequence.parse(source) {
		Err(_) => Fuzz.reject
		Ok(d) => {
			theme = Theme.Options.{}
			geometry = SequenceDraw.layout(d, theme)
			if geometry.centers.len() != d.participants.len() or geometry.rows.len() != d.events.len() {
				crash "sequence source alignment"
			}
			picture = Sequence.draw_diagram(d, theme)
			if !Drawing.is_finite(picture) {
				crash "sequence finite output"
			}
			if picture != Sequence.draw_diagram(d, theme) {
				crash "sequence determinism"
			}
			match Sequence.draw(source, theme) {
				Err(_) => crash "parsed sequence failed to draw"
				Ok(other) => if other != picture {
					crash "sequence one-call equivalence"
				}
			}
			svg = Svg.document(picture, "Inter")
			if !svg.starts_with("<svg ") or !svg.ends_with("</svg>\n") {
				crash "sequence SVG document"
			}
			Fuzz.keep
		}
	}
}
