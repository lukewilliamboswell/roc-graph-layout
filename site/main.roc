app [main!] { pf: platform "https://github.com/lukewilliamboswell/basic-ssg/releases/download/0.11.0/3vqgmE9dzxoPRNgCbUYrfJhcsyV1DKpi8Q8qKAsSt1Br.tar.zst" }

import pf.SSG
import pf.Path
import pf.OsStr exposing [OsStr]
import pf.Html
import pf.HtmlAttributes exposing [href, lang, name, content, rel, http_equiv, class]

main! : List(OsStr) => Try({}, [Exit(I32), PagesError(Str), ParseError(Str), WriteError(Str), ..])
main! = |args| match args.drop_first(1) {
	[input, output] => {
		pages = SSG.markdown_pages!(Path.from_os_str(input))?
		write_pages!(pages, Path.from_os_str(output))
	}
	_ => Err(Exit(1))
}

write_pages! : List(SSG.Page), Path.Path => Try({}, [ParseError(Str), WriteError(Str), ..])
write_pages! = |pages, output_dir| match pages {
	[] => Ok({})
	[page, .. as rest] => {
		body = SSG.parse_markdown!(page.source_path)?
		SSG.write_file!({ output_dir, output_path: page.output_path, content: document(body) })?
		write_pages!(rest, output_dir)
	}
}

document : Str -> Str
document = |body| Html.render_document(Html.html([lang("en")], [head(), page_body(body)]))

head : () -> Html.Node
head = || Html.head(
	[],
	[
		Html.meta([http_equiv("content-type"), content("text/html; charset=utf-8")]),
		Html.meta([name("viewport"), content("width=device-width, initial-scale=1")]),
		Html.link([rel("stylesheet"), href("site.css")]),
		Html.title([], [Html.text("roc-graph-layout — deterministic graph geometry")]),
	],
)

page_body : Str -> Html.Node
page_body = |body| Html.body(
	[],
	[
		Html.header(
			[class("site-header")],
			[
				Html.a([href("index.html"), class("brand")], [Html.text("roc-graph-layout")]),
				Html.nav(
					[],
					[
						Html.a([href("choosing-a-layout.html")], [Html.text("Choosing a layout")]),
						Html.a([href("playground/")], [Html.text("Playground")]),
						Html.a([href("docs/")], [Html.text("API reference")]),
					],
				),
			],
		),
		# Only repository-authored Markdown is rendered as raw HTML.
		Html.main([], [Html.p([class("eyebrow")], [Html.text("ROC GRAPH LAYOUT / FIELD GUIDE")]), Html.raw(body)]),
	],
)
