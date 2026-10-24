import cli.Cmd
import cli.Duration
import cli.Path
import cli.Tcp
import Script

## Serves package bundles from 127.0.0.1.
##
## Roc fetches a package dependency by URL while it compiles. Serving the exact
## archives a release would publish lets the examples be tested against them
## before any release exists.
Loopback := [].{

	## A listening server, what `start!` returns and `run!` and `stop!` take.
	## Each bundle is served at `base` followed by `/` and its file name.
	Server : { listener : Tcp.Listener, files : List({ name : Str, bytes : List(U8) }), base : Str }

	## Read `bundles` and start listening on a free port.
	start! : List(Path) => Try(Server, _)
	start! = |bundles| {
		var $files = []
		for bundle in bundles {
			$files = $files.append({ name: Script.file_name(bundle)?, bytes: Path.read_bytes!(bundle)? })
		}
		listener = Tcp.listen!("127.0.0.1", 0, Duration.seconds(5))?
		port = listener.local_port!()?
		Ok({ listener, files: $files, base: "http://127.0.0.1:${port.to_str()}" })
	}

	## The URL `server` answers with `bundle`, to put in place of its release URL.
	url : Server, Path -> Try(Str, _)
	url = |server, bundle| Ok("${server.base}/${Script.file_name(bundle)?}")

	## Run `command` to completion with captured output, answering every
	## connection made in the meantime with the bundle its request names.
	run! = |server, command| {
		child = command
			.stdout(Capture)
			.stderr(Capture)
			.spawn!()
			.map_err(|err| CommandSpawnFailed(err))?
		serve_until_exit!(child, server)
	}

	## Stop listening.
	stop! = |server| server.listener.close!()
}

# This process must answer the child's request and notice the child exiting,
# without threads. A short accept timeout alternates between the two.
serve_until_exit! = |child, server|
	match child.poll!().map_err(|err| CommandWaitFailed(err))? {
		Finished(output) => Ok(output)
		Running =>
			match server.listener.accept!({ accept_timeout: After(Duration.millis(100)), io_timeout: Duration.seconds(30) }) {
				Ok(stream) => {
					request = stream.read_until!('\n')?
					match server.files.keep_if(|file| requested(request) == file.name) {
						[file, ..] => {
							stream.write_bytes!(Str.to_utf8(response_headers("200 OK", file.bytes.len())))?
							stream.write_bytes!(file.bytes)?
						}
						[] => stream.write_bytes!(Str.to_utf8(response_headers("404 Not Found", 0)))?
					}
					serve_until_exit!(child, server)
				}
				Err(TcpErr(TimedOut)) => serve_until_exit!(child, server)
				Err(err) => Err(BundleServerFailed(err))
			}
	}

# The file name a request line such as `GET /<file> HTTP/1.1` asks for.
requested : List(U8) -> Str
requested = |line|
	match Str.split_on(Str.from_utf8_lossy(line), " ") {
		[_, target, ..] => target.drop_prefix("/")
		_ => ""
	}

# HTTP separates header lines with CRLF.
response_headers = |status, content_length|
	Str.join_with(
		[
			"HTTP/1.1 ${status}",
			"Content-Type: application/octet-stream",
			"Content-Length: ${content_length.to_str()}",
			"Connection: close",
			"",
			"",
		],
		"\r\n",
	)

expect requested(Str.to_utf8("GET /Abc123.tar.zst HTTP/1.1\r\n")) == "Abc123.tar.zst"
expect requested(Str.to_utf8("\r\n")) == ""
