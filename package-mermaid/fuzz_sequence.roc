app [target] {
	font: "https://github.com/lukewilliamboswell/roc-font/releases/download/0.1.0-rc2/A14BmicBaf6dm4K9kdYH9j8Y6BoAZrpUmxWh9sojsFy5.tar.zst",
	fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.3/41NK5FShyGC9Z8HNpUdUeXMWwLmLNfFxsfmLvdPL4Fxb.tar.zst",
	layout: "../package/main.roc",
}

import fuzz.Fuzz
import Drawing
import DiagramView
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
			themes = [
				Theme.Options.{},
				Theme.Options.{ font_size: 28, max_label_width: 100, line_height: 1.8 },
				Theme.Options.{ font_size: 128, max_label_width: 800 },
				Theme.Options.{ font_size: 64, line_height: 0.1, padding: 0, wrapping: Wrap, max_label_width: 80, corners: Square },
				Theme.Options.{ wrapping: NoWrap, corners: Rounded, corner_radius: 40 },
				Theme.Options.{ padding: 0, line_width: 0, corner_radius: 0 },
				Theme.Options.{ max_label_width: 500 },
				Theme.Options.{ shadow: Shadow({ dx: -80, dy: 120, opacity: 0.3 }), line_width: 20 },
			]
			theme = themes.get(bytes.len() % themes.len()) ?? Theme.Options.{}
			if !Theme.validate(theme).is_empty() {
				crash "fuzz theme must be valid"
			}
			geometry = SequenceDraw.layout(d, theme)
			if geometry.centers.len() != d.participants.len() or geometry.rows.len() != d.events.len() {
				crash "sequence source alignment"
			}
			picture = SequenceDraw.draw(d, theme)
			if !Drawing.is_finite(picture) {
				crash "sequence finite output"
			}
			if !SequenceDraw.contains(DiagramView.finish(picture, theme), theme) {
				crash "sequence exported bounds"
			}
			if picture != SequenceDraw.draw(d, theme) {
				crash "sequence determinism"
			}
			match Sequence.draw(source, theme) {
				Err(_) => crash "parsed sequence failed to draw"
				Ok(other) => if other != DiagramView.finish(picture, theme) {
					crash "sequence one-call equivalence"
				}
			}
			match Sequence.draw(source, Theme.Options.{ font_size: F64.nan, padding: -1, line_width: F64.infinity }) {
				Ok(_) => crash "invalid sequence theme accepted"
				Err(problems) => if problems.len() < 3 {
					crash "sequence theme problems not aggregated"
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
