package main


import "core:container/lru"
import "core:log"
import "core:mem"
import "core:net"
import "core:os"
import "core:path/filepath"
import "core:strings"

import http "./shared/odin-http"
import pq "./shared/odin-postgresql"


LOGGER_OPTIONS: log.Options : {
	.Level,
	.Terminal_Color,
	.Line,
	.Short_File_Path,
}
CACHE_TEMPLATE_CAP :: 10

DEV :: #config(DEV, ODIN_DEBUG)
TRACK_LEAKS :: DEV
DOCKER :: !DEV
HTTP_CACHE_CSS :: !DEV
HTTP_CACHE_HTML :: !DEV
HTTP_CACHE_JS :: !DEV
CACHE_STATIC :: !DEV // TODO
CACHE_TEMPLATE :: !DEV
LOGGER_LEVEL: log.Level : .Debug when #config(DEBUG_LEVEL, DEV) else .Info

pool: Pg_Pool_Atomic

when CACHE_TEMPLATE {
	cache_template: lru.Cache(string, string)
}

main :: proc() {
	logger := log.create_console_logger(LOGGER_LEVEL, LOGGER_OPTIONS)
	defer log.destroy_console_logger(logger)
	context.logger = logger

	when TRACK_LEAKS {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)
	}

	when CACHE_TEMPLATE {
		lru.init(&cache_template, CACHE_TEMPLATE_CAP)
		log.debug(cache_template)
		cache_template.on_remove = proc(key, value: string, _: rawptr) {
			delete(value)
		}
		defer lru.destroy(&cache_template, true)
	}

  core_count := os.processor_core_count()
	pool_init(&pool, core_count, 1 when DEV else core_count)
	defer pool_destroy(&pool)

	serve()

	when TRACK_LEAKS {
		for _, leak in track.allocation_map {
			log.warnf("%v leaked %v bytes\n", leak.location, leak.size)
		}
		for bad_free in track.bad_free_array {
			log.errorf(
				"%v allocation %p was freed badly\n",
				bad_free.location,
				bad_free.memory,
			)
		}
	}
}

serve :: proc() {
	s: http.Server
	// Register a graceful shutdown when the program receives a SIGINT signal.
	http.server_shutdown_on_interrupt(&s)

	unauthed: http.Router
	http.router_init(&unauthed)
	defer http.router_destroy(&unauthed)

	http.route_get(&unauthed, "/google_login", http.handler(google_login))
	http.route_get(
		&unauthed,
		"/google_callback",
		http.handler(google_callback),
	)
	http.route_get(&unauthed, "(.*)", http.handler(static))

	authed: http.Router
	http.router_init(&authed)
	defer http.router_destroy(&authed)

	routed := authed_unauthed_handler(
		&{authed = &authed, unauthed = &unauthed},
	)

	log.info("Listening on http://localhost:6969")

	traced := http.middleware_proc(&routed, trace_handler_proc)
	address := net.IP4_Address{0, 0, 0, 0} when DOCKER else net.IP4_Loopback
	err := http.listen_and_serve(&s, traced, net.Endpoint{address, 6969})
	log.assertf(err == nil, "server stopped with error: %v", err)
}

trace_handler_proc :: proc(
	handler: ^http.Handler,
	req: ^http.Request,
	res: ^http.Response,
) {
	log.info(req.url.raw)
	next, ok_next := handler.next.?
	if ok_next do next.handle(next, req, res)
}



static :: proc(req: ^http.Request, res: ^http.Response) {
	path := req.url.path
	ext := filepath.ext(req.url.path)
	switch ext {
	case "":
		path = strings.concatenate({path, ".html"}, context.temp_allocator)
		when HTTP_CACHE_HTML {
			cache_control :: "public, max-age=31536000"
			http.headers_set(&res.headers, "Cache-Control", cache_control)
		}
	case ".js":
		when HTTP_CACHE_JS {
			cache_control :: "public, max-age=31536000"
			http.headers_set(&res.headers, "Cache-Control", cache_control)
		}
	case ".css":
		when HTTP_CACHE_CSS {
			cache_control :: "public, max-age=31536000"
			http.headers_set(&res.headers, "Cache-Control", cache_control)
		}
	case ".png":
		cache_control :: "public, max-age=31536000"
		http.headers_set(&res.headers, "Cache-Control", cache_control)
	}
	http.respond_dir(res, "/", "./static", path)
}

get_template :: proc(path: string, loc := #caller_location) -> string {
	when CACHE_TEMPLATE {
		cached_bytes, ok_cache := lru.get(&cache_template, path)
		if ok_cache do return cached_bytes
	}
	template_path := strings.concatenate(
		{"./templates/", path, ".html"},
		context.temp_allocator,
	)
	bytes, ok := os.read_entire_file_from_filename(
		template_path,
		context.allocator when CACHE_TEMPLATE else context.temp_allocator,
		loc = loc,
	)
	log.assertf(ok, "%s template", path)
	when CACHE_TEMPLATE {
		lru.set(&cache_template, path, transmute(string)bytes)
	}
	return transmute(string)bytes
}
