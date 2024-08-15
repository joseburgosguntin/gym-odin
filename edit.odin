package main

import "core:fmt"
import "core:io"
import "core:log"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

import http "./shared/odin-http"
import pq "./shared/odin-postgresql"

// TODO: I should make these just completly server rendered
edit :: proc(req: ^http.Request, res: ^http.Response) {
	when HTTP_CACHE_HTML {
		cache_control :: "public, max-age=31536000"
		http.headers_set(&res.headers, "Cache-Control", cache_control)
	}
	http.respond_file(res, "./static/edit.html")
}

edit_routines :: proc(req: ^http.Request, res: ^http.Response) {
	user_id := local_user_id

  conn := pool_get(&pool)
  defer pool_release(&pool, conn)
	routines, ok_routines := edit_routines_query(conn, user_id)
	if !ok_routines {
		http.respond_with_status(res, .Internal_Server_Error)
		return
	}
	slice.sort_by(routines, proc(lhs, rhs: Routine_Template) -> bool {
		return lhs.id < rhs.id
	})
	b := strings.builder_make(context.temp_allocator)
	w := strings.to_writer(&b)
	// user_ptr := context.user_ptr
	// context.user_ptr = &form.weekday
	slice.sort_by_key(
		routines,
		proc(using r: Routine_Template) -> u16 {
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
	for routine in routines {
		edit_routine_template(w, routine, routines)
	}
	template := get_template("post-routine")
	fmt.wprint(w, template)
	http.respond_html(res, strings.to_string(b))
}

edit_routine_template :: proc(
	w: io.Writer,
	using r: Routine_Template,
	rs: []Routine_Template,
) {
  conn := pool_get(&pool)
  defer pool_release(&pool, conn)
	fmt.wprintf(w, `<div class="grid gap-2 bg-base-100 rounded-md">`)
	fmt.wprintf(
		w,
		`
    <h2 class="text-xl text-accent">
      <form 
        hx-delete="/routine" 
        hx-target="closest div"
        hx-swap="outerHTML"
        class="btn btn-sm btn-square btn-outline btn-error"
      >
        <input type="hidden" name="routine_id" value="%[0]d"/>
        <button>
          ✕
        </button>
      </form>
      %[1]s
    </h2>`,
		id,
		name,
	)
	fmt.wprintf(w, `<div id="weekdays" class="join">`)
	single_letter_weekdays := SINGLE_LETTER_WEEKDAYS
	toggle_weekday_template := get_template("toggle-weekday")
	for weekday in time.Weekday {
		in_routine := weekday in weekdays
		fmt.wprintf(
			w,
			toggle_weekday_template,
			"btn-active" if in_routine else "",
			id,
			weekday,
			in_routine,
			weekdays,
			single_letter_weekdays[weekday],
		)
	}
	fmt.wprintf(w, `</div>`)
	fmt.wprintf(w, `<ul class="grid gap-2">`)
	template := get_template("delete-routine-exercise")
	for e in exercises do fmt.wprintf(w, template, e.name, id, e.id)
	fmt.wprintf(
		w,
		`
    <li>
      <form 
        hx-post="routine_exercise" 
        hx-target="closest li"
        hx-swap="beforebegin" 
        x-data="{{ inputValue: '' }}"
        class="flex gap-2"
      >
        <button 
          class="group-item btn btn-square btn-success btn-outline"
          :disabled="!inputValue"
        >
          +
        </button>
        <input type="hidden" name="routine_id" value="%[0]d"/>
        <input
          class="input input-success input-bordered"
          placeholder="Type New Exercise..."
          name="exercise_name"
          x-model="inputValue"
          type="text"
          list="existing-exercises"
        />
        <datalist id="existing-exercises">`,
		id,
	)
	for rh in rs {
		if rh.id == r.id do continue
		for e in rh.exercises do fmt.wprintf(w, `
          <option value="%s"/>`, e.name)
	}
	fmt.wprint(w, `
        </datalist>
      </form>
    </li>`)
	fmt.wprint(w, `</ul>`)
	fmt.wprint(w, `</div>`)
}

Routine_Template :: struct {
	id:        i32,
	name:      string,
	weekdays:  Weekdays,
	exercises: []Exercise_Id_Name,
}

Exercise_Id_Name :: struct {
	id:   i32,
	name: string,
}

// TODO: can use mem.Scratch_Allocator if I want to use a [dynamic]
// remeber u can nest em
edit_routines_query :: proc(
	conn: pq.Conn,
	user_id: i32,
	allocator := context.temp_allocator,
) -> (
	[]Routine_Template,
	bool,
) {
	context.allocator = allocator
  cmd := fmt.ctprintf(
      `
      SELECT 
          r.id AS routine_id,
          r.name AS routine_name,
          r.weekdays AS routine_weekdays,
          array_agg(row(e.id, e.name)) AS exercises
      FROM 
          routines r
      LEFT JOIN 
          routines_exercises re ON r.id = re.routine_id
      LEFT JOIN 
          exercises e ON re.exercise_id = e.id
      WHERE 
          r.user_id = %[0]d
      GROUP BY 
          r.id, r.name
      ORDER BY 
          r.id;`,
      user_id,
  )
	// cmd := fmt.ctprintf(
	// 	`
 //    SELECT 
 //        r.id AS routine_id,
 //        r.name AS routine_name,
 //        r.weekdays AS routine_weekdays,
 //        array_agg(row(e.id, e.name)) AS exercises
 //    FROM 
 //        routines r
 //    JOIN 
 //        routines_exercises re ON r.id = re.routine_id
 //    JOIN 
 //        exercises e ON re.exercise_id = e.id
 //    WHERE 
 //        r.user_id = %[0]d
 //    GROUP BY 
 //        r.id, r.name
 //    ORDER BY 
 //        r.id;`,
	// 	user_id,
	// )
	query_res := exec_bin(conn, cmd)
	if pq.result_status(query_res) != .Tuples_OK do return nil, false
	// this is malloc'ed should we just point to this memory instead
	defer pq.clear(query_res)
	routines := results(Routine_Template, query_res, context.temp_allocator)
	for r in routines {
		log.infof("%#v", r)
	}
	return routines, true
}


SINGLE_LETTER_WEEKDAYS :: [time.Weekday]rune {
	.Sunday    = 'S',
	.Monday    = 'M',
	.Tuesday   = 'T',
	.Wednesday = 'W',
	.Thursday  = 'T',
	.Friday    = 'F',
	.Saturday  = 'S',
}


Weekdays :: bit_set[time.Weekday;u16]

toggle_weekday :: proc(req: ^http.Request, res: ^http.Response) {
  conn := pool_get(&pool)
  defer pool_release(&pool, conn)
	Form :: struct {
		routine_id: i32,
		weekday:    int,
		toggled:    bool,
		weekdays:   Weekdays,
	}
	form, ok_form := url_decode(Form, req.url.query, context.temp_allocator)
	if !ok_form {
		http.respond_with_status(res, .Not_Found)
		return
	}

	weekday := transmute(time.Weekday)form.weekday
	if !form.toggled {
		form.weekdays += Weekdays{weekday}
	} else {
		form.weekdays -= Weekdays{weekday}
	}

	cmd := fmt.ctprintf(
		`
    UPDATE routines
    SET weekdays = %d
    WHERE id = %d;`,
		transmute(u16)form.weekdays,
		form.routine_id,
	)

	query_res := exec_bin(conn, cmd)
	if pq.result_status(query_res) != .Command_OK {
		log.error(pq.error_message(conn))
		http.respond_with_status(res, .Internal_Server_Error)
		return
	}
	defer pq.clear(query_res)

	single_letter_weekdays := SINGLE_LETTER_WEEKDAYS


	b := strings.builder_make(context.temp_allocator)
	w := strings.to_writer(&b)
	toggle_weekday_template := get_template("toggle-weekday")
	for weekday in time.Weekday {
		in_routine := weekday in form.weekdays

		fmt.wprintf(
			w,
			toggle_weekday_template,
			"btn-active" if in_routine else "",
			form.routine_id,
			weekday,
			in_routine,
			form.weekdays,
			single_letter_weekdays[weekday],
		)
	}

	http.respond_html(res, strings.to_string(b), .OK)
}

post_routine :: proc(req: ^http.Request, res: ^http.Response) {
  conn := pool_get(&pool)
  defer pool_release(&pool, conn)
	Form :: struct {
		routine_name: string,
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

	cstr := strings.clone_to_cstring(form.routine_name, context.temp_allocator)
	length := cast(uint)len(form.routine_name)
	routine_name := pq.escape_literal(conn, cstr, length)
	defer pq.free_mem(transmute(rawptr)routine_name)

	r_cmd := fmt.ctprintf(
		`
      INSERT INTO routines (name, user_id, weekdays)
      VALUES (%[0]s, %[1]d, 0)
      RETURNING id;
    `,
		routine_name,
		user_id,
	)
	r_res := exec_bin(conn, r_cmd)

	if pq.result_status(r_res) != .Tuples_OK {
		log.error(pq.error_message(conn))
		http.respond_with_status(res, .Conflict)
		return
	}
	defer pq.clear(r_res)
	assert(pq.n_tuples(r_res) == 1)
	assert(pq.n_fields(r_res) == 1)

	b := strings.builder_make(context.temp_allocator)
	w := strings.to_writer(&b)

	routine_id := result(i32, r_res, cast(i32)0, cast(i32)0)

	name := strings.clone_from_cstring(routine_name, context.temp_allocator)
	edit_routine_template(
		w,
		Routine_Template {
			id = routine_id,
			name = name[1:len(name) - 1],
			weekdays = {},
			exercises = {},
		},
		{}, // <- this thing
	)
	// TODO oob
	// - get the list of exercises to add
	// maybe don't oob it, maybe just the client (javascript) 
	// remebers all the exercises that have entered and left
	http.respond_html(res, strings.to_string(b), .Created)
}

delete_routine :: proc(req: ^http.Request, res: ^http.Response) {
  conn := pool_get(&pool)
  defer pool_release(&pool, conn)
	Form :: struct {
		routine_id: int,
	}
	form, ok_form := url_decode(Form, req.url.query, context.temp_allocator)
	log.debug(form)
	if !ok_form {
		log.warn("form not ok")
		http.respond_with_status(res, .Not_Found)
		return
	}

	cmd := fmt.ctprintf(
		`
    DELETE FROM routines
    WHERE id = %d;`,
		form.routine_id,
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


post_routine_exercise :: proc(req: ^http.Request, res: ^http.Response) {
  conn := pool_get(&pool)
  defer pool_release(&pool, conn)
	Form :: struct {
		routine_id:    i32,
		exercise_name: string,
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

	// TODO
	user_id := local_user_id

	cstr := strings.clone_to_cstring(
		form.exercise_name,
		context.temp_allocator,
	)
	length := cast(uint)len(form.exercise_name)
	exercise_name := pq.escape_literal(conn, cstr, length)
	defer pq.free_mem(transmute(rawptr)exercise_name)

	e_cmd := fmt.ctprintf(
		`
    WITH ins AS (
      INSERT INTO exercises (name, user_id)
      VALUES (%[0]s, %[1]d)
      ON CONFLICT (user_id, name) DO NOTHING
      RETURNING id
    )
    SELECT id FROM ins
    UNION ALL
      SELECT id FROM exercises 
      WHERE name = %[0]s AND user_id = %[1]d
    LIMIT 1;
    `,
		exercise_name,
		user_id,
	)
	e_res := exec_bin(conn, e_cmd)
	if pq.result_status(e_res) != .Tuples_OK {
		log.error(pq.error_message(conn))
		http.respond_with_status(res, .Internal_Server_Error)
		return
	}
	defer pq.clear(e_res)

	assert(pq.n_tuples(e_res) == 1)
	exercise_id := result_number(i32, e_res, cast(i32)0, cast(i32)0)

	re_cmd := fmt.ctprintf(
		`
    INSERT INTO routines_exercises (routine_id, exercise_id)
    VALUES (%d, %d);`,
		form.routine_id,
		exercise_id,
	)

	re_res := exec_bin(conn, re_cmd)
	if pq.result_status(re_res) != .Command_OK {
		log.error(pq.error_message(conn))
		http.respond_with_status(res, .Conflict)
		return
	}
	defer pq.clear(re_res)

	// TODO oob
	// - all the add exercises inputs (to get the new auto_complete)
	name := strings.clone_from_cstring(exercise_name, context.temp_allocator)
	template := get_template("delete-routine-exercise")
	html := fmt.tprintf(
		template,
		name[1:len(name) - 1],
		form.routine_id,
		exercise_id,
	)
	http.respond_html(res, html, .Created)
}

delete_routine_exercise :: proc(req: ^http.Request, res: ^http.Response) {
  conn := pool_get(&pool)
  defer pool_release(&pool, conn)
	Form :: struct {
		routine_id:  i32,
		exercise_id: i32,
	}
	form, ok_form := url_decode(Form, req.url.query, context.temp_allocator)
	log.debug(form)
	if !ok_form {
		log.warn("form not ok")
		http.respond_with_status(res, .Not_Found)
		return
	}

	cmd := fmt.ctprintf(
		`
    DELETE FROM routines_exercises
    WHERE routine_id = %d
    AND exercise_id = %d;`,
		form.routine_id,
		form.exercise_id,
	)

	query_res := exec_bin(conn, cmd)
	defer pq.clear(query_res)
	if pq.result_status(query_res) != .Command_OK {
		log.error(pq.error_message(conn))
		http.respond_with_status(res, .Internal_Server_Error)
    return
	}
	http.respond_with_status(res, .OK)
}
