package main


import "core:container/lru"
import "core:encoding/ini"
import "core:io"
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
	dotenv()

	when TRACK_LEAKS {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		defer mem.tracking_allocator_destroy(&track)
		context.allocator = mem.tracking_allocator(&track)
		defer {
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

	when CACHE_TEMPLATE {
		lru.init(&cache_template, CACHE_TEMPLATE_CAP)
		log.debug(cache_template)
		cache_template.on_remove = proc(key, value: string, _: rawptr) {
			delete(value)
		}
		defer lru.destroy(&cache_template, true)
	}

	conn_count := os.processor_core_count()
	when DEV {conn_count = min(4, conn_count)}
	pool_init(&pool, conn_count, 1 when DEV else conn_count)
	defer pool_destroy(&pool)

	serve()
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

	// Routes are tried in order.
	// Route matching is implemented using an implementation of Lua patterns, see the docs on them here:
	// https://www.lua.org/pil/20.2.html
	// They are very similar to regex patterns but a bit more limited, which makes them much easier to implement since Odin does not have a regex implementation.

	// TODO: merge routine and exercises to a single route
	http.route_get(&authed, "/", http.handler(routines))
	http.route_get(&authed, "/edit", http.handler(edit))
	http.route_get(&authed, "/routine", http.handler(routine))
	http.route_get(&authed, "/logout", http.handler(logout))
	http.route_get(&authed, "/stats", http.handler(stats))

	http.route_post(
		&authed,
		"/routine_exercise",
		http.handler(post_routine_exercise),
	)
	http.route_post(&authed, "/routine", http.handler(post_routine))
	http.route_post(&authed, "/set", http.handler(post_set))

	http.route_delete(
		&authed,
		"/routine_exercise",
		http.handler(delete_routine_exercise),
	)
	http.route_delete(&authed, "/routine", http.handler(delete_routine))
	http.route_delete(&authed, "/set", http.handler(delete_set))

	http.route_patch(&authed, "/weekday", http.handler(toggle_weekday))

	routed := authed_unauthed_handler(
		&{authed = &authed, unauthed = &unauthed},
	)


	traced := http.middleware_proc(&routed, trace_handler_proc)
	ADDRESS :: net.IP4_Address{0, 0, 0, 0} when DOCKER else net.IP4_Loopback
	PORT :: 1318
	log.infof("Listening on %v:%v", ADDRESS, PORT)
	opts := http.Default_Server_Opts
	when DEV {opts.thread_count = min(4, opts.thread_count)}
	err := http.listen_and_serve(&s, traced, net.Endpoint{ADDRESS, PORT}, opts)
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
			cache_control :: "public, max-age=31536000, immutable"
			http.headers_set(&res.headers, "Cache-Control", cache_control)
		}
	case ".js":
		when HTTP_CACHE_JS {
			cache_control :: "public, max-age=31536000, immutable"
			http.headers_set(&res.headers, "Cache-Control", cache_control)
		}
	case ".css":
		when HTTP_CACHE_CSS {
			cache_control :: "public, max-age=31536000, immutable"
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

dotenv :: proc() {
	if os.exists(".env") {
		log.info("using .env file")
		data, data_ok := os.read_entire_file(".env", context.temp_allocator)
		log.assert(data_ok, "missing .env file")
		it := ini.iterator_from_string(transmute(string)data, {comment = "#"})
		for key, value in ini.iterate(&it) {
			unquoted := value
			if value[0] == '"' && value[len(value) - 1] == '"' {
				unquoted = value[1:len(value) - 1]
			}
			_, set := os.lookup_env(key)
			if !set do os.set_env(key, unquoted)
		}
	} else {
		log.warn("no .env file found")
	}

	DATABASE_URL_ENV :: "DATABASE_URL"
	database_url, ok_database_url := os.lookup_env(
		DATABASE_URL_ENV,
		context.temp_allocator,
	)
	log.assertf(ok_database_url, "missing env var %s", DATABASE_URL_ENV)
	CONNINFO = strings.clone_to_cstring(database_url)

	GOOGLE_CLIENT_ID_ENV :: "GOOGLE_CLIENT_ID"
	google_client_id, ok_google_client_id := os.lookup_env(
		GOOGLE_CLIENT_ID_ENV,
		context.temp_allocator,
	)
	log.assertf(
		ok_google_client_id,
		"missing env var %s",
		GOOGLE_CLIENT_ID_ENV,
	)
	GOOGLE_CLIENT_ID = google_client_id

	GOOGLE_CLIENT_SECRET_ENV :: "GOOGLE_CLIENT_SECRET"
	google_client_secret, ok_google_client_secret := os.lookup_env(
		GOOGLE_CLIENT_SECRET_ENV,
		context.temp_allocator,
	)
	log.assertf(
		ok_google_client_id,
		"missing env var %s",
		GOOGLE_CLIENT_SECRET_ENV,
	)
	GOOGLE_CLIENT_SECRET = google_client_secret
}
