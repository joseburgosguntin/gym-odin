package main


import "core:log"
import "core:mem"
import "core:net"
import "core:os"

import http "./shared/odin-http"
import pq "./shared/odin-postgresql"


LOGGER_OPTIONS: log.Options : {
	.Level,
	.Terminal_Color,
	.Line,
	.Short_File_Path,
}
DEV :: #config(DEV, ODIN_DEBUG)
TRACK_LEAKS :: DEV
DOCKER :: !DEV
LOGGER_LEVEL: log.Level : .Debug when #config(DEBUG_LEVEL, DEV) else .Info
pool: Pg_Pool_Atomic


main :: proc() {
	logger := log.create_console_logger(LOGGER_LEVEL, LOGGER_OPTIONS)
	defer log.destroy_console_logger(logger)
	context.logger = logger

	when TRACK_LEAKS {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)
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



