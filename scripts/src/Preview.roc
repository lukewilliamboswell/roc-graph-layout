import cli.Duration
import cli.Path
import cli.Stdout
import cli.Tcp
import Release

## A small static file server for previewing the assembled site.
##
## It serves under the same base path GitHub Pages uses, because the API
## reference that `roc docs` writes links to pages from that root.
Preview := [].{

	## Serve the directory `site` on 127.0.0.1 at `port` until interrupted.
	## Port zero picks a free port.
	serve! = |site, port| {
		listener = Tcp.listen!("127.0.0.1", port, Duration.seconds(5))?
		bound = listener.local_port!()?
		Stdout.line!("Serving the site at http://127.0.0.1:${bound.to_str()}${Release.site_base_path}/ (Ctrl-C to stop)")?
		while Bool.True {
			match listener.accept!({ accept_timeout: After(Duration.seconds(1)), io_timeout: Duration.seconds(5) }) {
				Ok(stream) =>
				# A dropped connection must not stop the preview.
					match answer!(stream, site) {
						Ok(line) => Stdout.line!(line)?
						Err(_) => Stdout.line!("request failed")?
					}
				Err(TcpErr(TimedOut)) => {}
				Err(err) => return Err(PreviewServerFailed(err))
			}
		}
	}

	## Map the path of a preview request to what answers it: a file inside the
	## site, given as path segments, or a redirect. A path that could leave the
	## site, or names a hidden file, is not found.
	route : Str -> [File(List(Str)), Redirect(Str), NotFound]
	route = |path|
		if path == "/" or path == Release.site_base_path {
			Redirect("${Release.site_base_path}/")
		} else if !path.starts_with("${Release.site_base_path}/") {
			NotFound
		} else {
			relative = path.drop_prefix("${Release.site_base_path}/")
			segments = Str.split_on(if (relative == "" or relative.ends_with("/")) "${relative}index.html" else relative, "/")
			if segments.all(|segment| segment != "" and !segment.starts_with(".") and !segment.contains("\\")) {
				File(segments)
			} else {
				NotFound
			}
		}
}

answer! = |stream, site| {
	request = stream.read_line!()?.trim()
	skip_headers!(stream, 100)?
	target = match Str.split_on(request, " ") {
		["GET", value, ..] | ["HEAD", value, ..] => value
		_ => {
			send!(stream, "405 Method Not Allowed", "text/plain; charset=utf-8", [], Str.to_utf8("method not allowed\n"))?
			return Ok("405 ${request}")
		}
	}
	path = match Str.split_first(target, "?") {
		Ok({ before, .. }) => before
		Err(_) => target
	}
	match Preview.route(path) {
		Redirect(location) => {
			send!(stream, "302 Found", "text/plain; charset=utf-8", ["Location: ${location}"], [])?
			Ok("302 ${path}")
		}
		NotFound => not_found!(stream, path)
		File(relative) => {
			file = relative.fold(site, |parent, segment| Path.join(parent, segment))
			if Path.is_dir!(file)? {
				send!(stream, "302 Found", "text/plain; charset=utf-8", ["Location: ${path}/"], [])?
				Ok("302 ${path}")
			} else if Path.is_file!(file)? {
				send!(stream, "200 OK", content_type(Path.display(file)), [], Path.read_bytes!(file)?)?
				Ok("200 ${path}")
			} else {
				not_found!(stream, path)
			}
		}
	}
}

not_found! = |stream, path| {
	send!(stream, "404 Not Found", "text/plain; charset=utf-8", [], Str.to_utf8("not found\n"))?
	Ok("404 ${path}")
}

# Read to the blank line that ends the request headers, so the browser has
# nothing unread when the connection closes.
skip_headers! = |stream, remaining|
	if remaining == 0 {
		Ok({})
	} else {
		match stream.read_line!()?.trim() {
			"" => Ok({})
			_ => skip_headers!(stream, remaining - 1)
		}
	}

# HTTP separates header lines with CRLF.
send! = |stream, status, kind, extra_headers, body| {
	headers = ["HTTP/1.1 ${status}", "Content-Type: ${kind}", "Content-Length: ${body.len().to_str()}", "Connection: close"]
		.concat(extra_headers)
		.concat(["", ""])
	stream.write_bytes!(Str.to_utf8(Str.join_with(headers, "\r\n")))?
	stream.write_bytes!(body)
}

content_type = |file_name|
	if file_name.ends_with(".html") {
		"text/html; charset=utf-8"
	} else if file_name.ends_with(".css") {
		"text/css; charset=utf-8"
	} else if file_name.ends_with(".js") {
		"text/javascript; charset=utf-8"
	} else if file_name.ends_with(".svg") {
		"image/svg+xml"
	} else if file_name.ends_with(".png") {
		"image/png"
	} else if file_name.ends_with(".json") {
		"application/json"
	} else {
		"application/octet-stream"
	}

expect Preview.route("/") == Redirect("/roc-graph-layout/")
expect Preview.route("/roc-graph-layout") == Redirect("/roc-graph-layout/")
expect Preview.route("/roc-graph-layout/") == File(["index.html"])
expect Preview.route("/roc-graph-layout/docs/0.2.0/") == File(["docs", "0.2.0", "index.html"])
expect Preview.route("/roc-graph-layout/site.css") == File(["site.css"])
expect Preview.route("/roc-graph-layout/../etc/passwd") == NotFound
expect Preview.route("/roc-graph-layout/.nojekyll") == NotFound
expect Preview.route("/elsewhere/index.html") == NotFound
