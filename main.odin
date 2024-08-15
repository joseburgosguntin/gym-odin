package main


import "core:container/lru"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:net"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"

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

	// Routes are tried in order.
	// Route matching is implemented using an implementation of Lua patterns, see the docs on them here:
	// https://www.lua.org/pil/20.2.html
	// They are very similar to regex patterns but a bit more limited, which makes them much easier to implement since Odin does not have a regex implementation.

	// TODO: merge routine and exercises to a single route
	http.route_get(&authed, "/", http.handler(index))
	http.route_get(&authed, "/edit", http.handler(edit))
	http.route_get(&authed, "/exercises", http.handler(exercises))
	http.route_get(&authed, "/routine", http.handler(routine))
	http.route_get(&authed, "/edit/routines", http.handler(edit_routines))
	http.route_get(&authed, "/routines", http.handler(routines))
	http.route_get(&authed, "/sets", http.handler(sets))
	http.route_get(&authed, "/logout", http.handler(logout))

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


sets :: proc(req: ^http.Request, res: ^http.Response) {
	conn := pool_get(&pool)
	defer pool_release(&pool, conn)
	// TODO: remove workout_id from form, currently we will fetch it per set
	// TODO: how will this figure out we are not in an old workout?
	// TODO: maybe add chache for this
	Form :: struct {
		exercise_id: i32,
	}
	form, ok_form := url_decode(Form, req.url.query, context.temp_allocator)
	log.debug(form)
	if !ok_form {
		http.respond_with_status(res, .Not_Found)
		return
	}
	user_id := local_user_id

	cmd := fmt.ctprintf(
		`
    WITH recent_workout AS (
        SELECT w.id AS workout_id
        FROM workouts w
        JOIN sets s ON w.id = s.workout_id
        WHERE s.exercise_id = %[0]d
        ORDER BY s.end_datetime DESC
        LIMIT 1
    ),
    chosen_workout AS (
        SELECT workout_id
        FROM recent_workout
        WHERE EXISTS (
            SELECT 1
            FROM sets s
            WHERE s.workout_id = recent_workout.workout_id
            AND s.end_datetime >= NOW() - INTERVAL '1 hour'
        )
        UNION ALL
        SELECT NULL -- This will be used for cases when no recent workout is found
        LIMIT 1
    ),
    existing_sets AS (
        SELECT s.id, s.weight, s.reps
        FROM sets s
        JOIN chosen_workout cw ON s.workout_id = cw.workout_id
        WHERE s.exercise_id = %[0]d
    )
    SELECT es.id, es.weight, es.reps
    FROM existing_sets es

    UNION ALL

    SELECT
        NULL::INTEGER AS id,
        NULL::SMALLINT AS weight,
        NULL::SMALLINT AS reps
    WHERE FALSE;`,
		form.exercise_id,
	)

	query_res := exec_bin(conn, cmd)
	if pq.result_status(query_res) != .Tuples_OK {
		log.error(pq.error_message(conn))
		http.respond_with_status(res, .Internal_Server_Error)
		return
	}
	defer pq.clear(query_res)

	Id_Weight_Reps :: struct {
		id:           i32,
		weight, reps: i16,
	}
	sets := results(Id_Weight_Reps, query_res, context.temp_allocator)

	b := strings.builder_make(context.temp_allocator)
	w := strings.to_writer(&b)
	for set in sets {
		fmt.wprintf(
			w,
			`
      <tr>
        <td>%[0]d</td>
        <td>%[1]d</td>
        <td>
          <button
            hx-target="closest tr"
            hx-swap="delete"
            hx-delete="/set?set_id=%[2]d"
            class="btn btn-sm btn-block btn-error btn-outline"
          >
            X
          </button>
        </td>
      </tr>`,
			set.weight,
			set.reps,
			set.id,
		)
	}
	http.respond_html(res, strings.to_string(b), .Created)
}

post_set :: proc(req: ^http.Request, res: ^http.Response) {
	conn := pool_get(&pool)
	defer pool_release(&pool, conn)
	// TODO: remove workout_id from form, currently we will fetch it per set
	Form :: struct {
		workout_id, exercise_id: i32,
		weight, reps:            i16,
	}
	CheckedForm :: struct {
		using f: Form,
		ok:      bool,
	}
	form: CheckedForm
	http.body(
		req,
		0x200,
		&form,
		proc(user_data: rawptr, body: http.Body, err: http.Body_Error) {
			c := cast(^CheckedForm)user_data
			c.f, c.ok = url_decode(Form, body, context.temp_allocator)
		},
	)
	log.debug(form)
	if !form.ok {
		http.respond_with_status(res, .Not_Found)
		return
	}

	user_id := local_user_id

	cmd := fmt.ctprintf(
		`
    WITH recent_workout AS (
        SELECT w.id AS workout_id, MAX(s.end_datetime) AS last_set_time
        FROM workouts w
        JOIN sets s ON w.id = s.workout_id
        WHERE s.exercise_id = %[0]d
        GROUP BY w.id
        ORDER BY last_set_time DESC
        LIMIT 1
    ),
    new_workout AS (
        INSERT INTO workouts (user_id, start_datetime)
        SELECT %[3]d, NOW() -- Replace %[3]d with the user_id parameter
        WHERE NOT EXISTS (
            SELECT 1
            FROM recent_workout rw
            WHERE rw.last_set_time >= NOW() - INTERVAL '1 hour'
        )
        RETURNING id AS workout_id
    ),
    chosen_workout AS (
        SELECT workout_id FROM recent_workout
        WHERE last_set_time >= NOW() - INTERVAL '1 hour'
        UNION ALL
        SELECT workout_id FROM new_workout
        LIMIT 1
    )
    -- Perform the insert here
    INSERT INTO sets (workout_id, exercise_id, weight, reps, end_datetime)
    SELECT
        cw.workout_id,
        %[0]d,
        %[1]d,
        %[2]d,
        CURRENT_TIMESTAMP
    FROM chosen_workout cw
    RETURNING id;
    `,
		form.exercise_id,
		form.weight,
		form.reps,
		user_id,
	)

	query_res := exec_bin(conn, cmd)
	if pq.result_status(query_res) != .Tuples_OK {
		log.error(pq.error_message(conn))
		http.respond_with_status(res, .Internal_Server_Error)
		return
	}
	defer pq.clear(query_res)

	set_id := result(i32, query_res, 0, 0)

	html := fmt.tprintf(
		`
    <tr>
      <td>%[0]d</td>
      <td>%[1]d</td>
      <td>
        <button
          hx-target="closest tr"
          hx-swap="delete"
          hx-delete="/set?set_id=%[2]d"
          class="btn btn-sm btn-block btn-error btn-outline"
        >
          X
        </button>
      </td>
    </tr>`,
		form.weight,
		form.reps,
		set_id,
	)
	http.respond_html(res, html, .Created)
}

delete_set :: proc(req: ^http.Request, res: ^http.Response) {
	conn := pool_get(&pool)
	defer pool_release(&pool, conn)
	Form :: struct {
		set_id: i32,
	}
	form, ok_form := url_decode(Form, req.url.query, context.temp_allocator)
	cmd := fmt.ctprintf(
		`
    DELETE FROM sets
    WHERE id = %d`,
		form.set_id,
	)

	query_res := exec_bin(conn, cmd)
	if pq.result_status(query_res) != .Command_OK {
		log.error(pq.error_message(conn))
		http.respond_with_status(res, .Internal_Server_Error)
		return
	}
	defer pq.clear(query_res)

	http.respond_with_status(res, .OK)
}

routine :: proc(req: ^http.Request, res: ^http.Response) {
	conn := pool_get(&pool)
	defer pool_release(&pool, conn)
	Form :: struct {
		routine_id: i32,
	}
	form, ok_form := url_decode(Form, req.url.query, context.temp_allocator)
	if !ok_form {
		http.respond_with_status(res, .Not_Found)
		return
	}

	cmd := fmt.ctprintf(
		`
    SELECT name
    FROM routines
    WHERE id = %d`,
		form.routine_id,
	)

	query_res := exec_bin(conn, cmd)
	if pq.result_status(query_res) != .Tuples_OK {
		log.error(pq.error_message(conn))
		http.respond_with_status(res, .Internal_Server_Error)
		return
	}
	defer pq.clear(query_res)

	if pq.n_tuples(query_res) != 1 do return
	assert(pq.n_fields(query_res) == 1)

	name := result(string, query_res, 0, 0, context.temp_allocator)

	template := get_template("routine")

	html := fmt.aprintf(template, name, form.routine_id)
	defer delete(html)

	http.respond_html(res, html)
}


exercises :: proc(req: ^http.Request, res: ^http.Response) {
	conn := pool_get(&pool)
	defer pool_release(&pool, conn)
	Form :: struct {
		routine_id: i32,
	}
	form, ok_form := url_decode(Form, req.url.query, context.temp_allocator)
	if !ok_form {
		http.respond_with_status(res, .Not_Found)
		return
	}

	cmd := fmt.ctprintf(
		`
    WITH most_recent_sets AS (
      SELECT DISTINCT ON (s.exercise_id)
        s.exercise_id,
        s.weight,
        s.reps,
        s.end_datetime
      FROM
        sets s
      JOIN
        workouts w ON s.workout_id = w.id
      JOIN
        routines_exercises re ON re.exercise_id = s.exercise_id
      WHERE
        re.routine_id = %[0]d
      ORDER BY
        s.exercise_id, s.end_datetime DESC
    )
    SELECT
      e.id AS exercise_id,
      e.name AS exercise_name,
      COALESCE(most_recent_sets.weight, 0)::SMALLINT AS recent_weight,
      COALESCE(most_recent_sets.reps, 1)::SMALLINT AS recent_reps
    FROM
      exercises e
    JOIN
      routines_exercises re ON e.id = re.exercise_id
    LEFT JOIN
      most_recent_sets ON e.id = most_recent_sets.exercise_id
    WHERE
      re.routine_id = %[0]d
    ORDER BY
        e.id; `,
		form.routine_id,
	)

	query_res := exec_bin(conn, cmd)
	if pq.result_status(query_res) != .Tuples_OK {
		http.respond_with_status(res, .Internal_Server_Error)
		log.error(pq.error_message(conn))
		return
	}
	defer pq.clear(query_res)

	n_tuples := pq.n_tuples(query_res)
	if n_tuples > 0 do assert(pq.n_fields(query_res) == 4)

	Exercise_Query :: struct {
		id:           i32,
		name:         string,
		weight, reps: i16,
	}
	exercises := results(Exercise_Query, query_res, context.temp_allocator)

	log.debug(exercises)

	if len(exercises) == 0 {
		html := get_template("no-exercises")
		http.respond_html(res, html)
		return
	}
	b := strings.builder_make(context.temp_allocator)
	w := strings.to_writer(&b)
	template := get_template("exercise-with-sets")
	for exercise in exercises {
		using exercise
		fmt.wprintf(w, template, id, name, weight, reps)
	}

	http.respond_html(res, strings.to_string(b))
}


// TODO: I should make these just completly server rendered
index :: proc(req: ^http.Request, res: ^http.Response) {
	when HTTP_CACHE_HTML {
		cache_control :: "public, max-age=31536000"
		http.headers_set(&res.headers, "Cache-Control", cache_control)
	}
	http.respond_file(res, "./static/index.html")
}

Routine_Id_Name_Weekdays :: struct {
	id:       i32,
	name:     string,
	weekdays: Weekdays,
}


earliest_weekday :: proc(weekdays: Weekdays) -> time.Weekday {
	for w in time.Weekday do if w in weekdays do return .Monday
	unreachable()
}

routines :: proc(req: ^http.Request, res: ^http.Response) {
	// conn := pg_local_get()
	conn := pool_get(&pool)
	defer pool_release(&pool, conn)
	Form :: struct {
		weekday: u16,
	}
	form, ok_form := url_decode(Form, req.url.query, context.temp_allocator)
	log.debug(form)
	if !ok_form {
		http.respond_with_status(res, .Not_Found)
		return
	}
	user_id := local_user_id
	cmd := fmt.ctprintf(
		`
    SELECT id, name, weekdays
    FROM routines
    WHERE user_id = %[0]d;`,
		user_id,
	)
	rs_res := exec_bin(conn, cmd)
	if pq.result_status(rs_res) != .Tuples_OK {
		log.error(pq.error_message(conn))
		http.respond_with_status(res, .Internal_Server_Error)
		return
	}
	defer pq.clear(rs_res)
	// TODO: results should return an ok
	b := strings.builder_make(context.temp_allocator)
	w := strings.to_writer(&b)
	routines := results(
		Routine_Id_Name_Weekdays,
		rs_res,
		context.temp_allocator,
	)
	// user_ptr := context.user_ptr
	// context.user_ptr = &form.weekday
	slice.sort_by_key(
		routines,
		proc(using r: Routine_Id_Name_Weekdays) -> u16 {
			//     // weekday := (cast(^time.Weekday)context.user_ptr)^
			//     weekday := time.Weekday.Wednesday
			//     earliest := earliest_weekday(r.weekdays)
			//     x := transmute(u16)r.weekdays +
			//       (7 if cast(u8)weekday > cast(u8)earliest else 0)
			//     log.debugf(
			//       "ws: %v, w: %d, e: %d n0: %d, n1: %d",
			//       r.weekdays,
			//       cast(u8)weekday,
			//       cast(u8)earliest,
			//       transmute(u16)r.weekdays,
			//       x,
			//     )
			//     return x
			return transmute(u16)weekdays
		},
	)
	// context.user_ptr = user_ptr
	// fmt.wprintf(w, `<ul hx-boost="true" class="grid gap-4 py-4">`)
	if len(routines) == 0 {
		html := get_template("no-routines")
		http.respond_html(res, html)
		return
	}
	for r in routines {
		fmt.wprintf(
			w,
			`
      <li>
        <a href="/routine?routine_id=%[0]d" class="btn btn-block btn-outline btn-accent">
          %[1]s
        </a>
      </li> `,
			r.id,
			r.name,
		)
	}
	// fmt.wprintf(w, `</ul>`)
	http.respond_html(res, strings.to_string(b), .OK)
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
