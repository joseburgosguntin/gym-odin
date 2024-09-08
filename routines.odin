package main


import "core:fmt"
import "core:io"
import "core:log"
import "core:slice"
import "core:strings"
import "core:time"

import http "./shared/odin-http"
import pq "./shared/odin-postgresql"


routines :: proc(req: ^http.Request, res: ^http.Response) {
	conn := pool_get(&pool)
	defer pool_release(&pool, conn)

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
	// sort by weekday server timezone
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

	routines_data := Routines_Data{routines}
	layout_data := Layout_Data {
		Head_Data{title = "Routines", scripts = {"htmx@2.0.0.js"}},
		Top_Nav_Data {
			profile_picture = "https://lh3.googleusercontent.com/a/AAcHTtcIA7reOrDrtSslK5DfbBWfqLtWbqxx4O1TVMQA1yO7Pg=s96-c",
		},
		routines_templater(&routines_data),
		Bottom_Nav_Data{selection = .Home},
	}
	layout_templater := layout_templater(&layout_data)
	layout_templater.template(&layout_templater, w)

	http.respond_html(res, strings.to_string(b))
}

Routine_Id_Name_Weekdays :: struct {
	id:       i32,
	name:     string,
	weekdays: Weekdays,
}

Routines_Data :: struct {
	routines: []Routine_Id_Name_Weekdays,
}

routines_templater :: proc(routines_data: ^Routines_Data) -> Templater {
	t: Templater
	t.user_data = routines_data
	t.template = proc(t: ^Templater, w: io.Writer) {
		data := cast(^Routines_Data)t.user_data
		fmt.wprint(w, `<main class="px-8 pt-4 min-h-[80dvh] pb-20">`);{
			if len(data.routines) == 0 {
				html := get_template("no-routines")
				return
			}
			fmt.wprintf(w, `<ul hx-boost="true" class="grid gap-4 py-4">`);{
				for r in data.routines {
					fmt.wprintf(
						w,
						`
          <li>
            <a 
              href="/routine?routine_id=%[0]d" 
              class="btn btn-block btn-outline btn-accent"
            >
              %[1]s
            </a>
          </li> `,
						r.id,
						r.name,
					)
				}
			};fmt.wprintf(w, `</ul>`)
		};fmt.wprint(w, `</main>`)
	}
	return t
}

routine :: proc(req: ^http.Request, res: ^http.Response) {
	Form :: struct {
		routine_id: i32,
	}
	form, ok_form := url_decode(Form, req.url.query, context.temp_allocator)
	if !ok_form {
		http.respond_with_status(res, .Not_Found)
		return
	}

	conn := pool_get(&pool)
	defer pool_release(&pool, conn)

	user_id := local_user_id

	cmd := fmt.ctprintf(
		`
    SELECT name
    FROM routines
    WHERE id = %d AND user_id = %d`,
		form.routine_id,
		user_id,
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

	cmd_2 := fmt.ctprintf(
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
    ),
    sets_last_hour AS (
      -- Get sets where the last set for the exercise was done within the last hour
      SELECT
        s.exercise_id,
        s.id,
        s.reps,
        s.weight,
        s.end_datetime
      FROM
        sets s
      JOIN
        workouts w ON s.workout_id = w.id
      WHERE
        s.end_datetime >= NOW() - INTERVAL '1 hour'
    )
    SELECT
      e.id AS exercise_id,
      e.name AS exercise_name,
      COALESCE(most_recent_sets.weight, 0)::SMALLINT AS recent_weight,
      COALESCE(most_recent_sets.reps, 1)::SMALLINT AS recent_reps,
      -- Aggregate only sets within the last hour into an array of tuples (id, reps, weight)
      COALESCE(array_agg(ROW(s.id, s.reps, s.weight) 
                         ORDER BY s.end_datetime ASC), '{{}}') AS sets
    FROM
      exercises e
    JOIN
      routines_exercises re ON e.id = re.exercise_id
    LEFT JOIN
      most_recent_sets ON e.id = most_recent_sets.exercise_id
    LEFT JOIN
      sets_last_hour s ON e.id = s.exercise_id  -- Only include sets from the last hour
    WHERE
      re.routine_id = %[0]d
    GROUP BY
      e.id, e.name, most_recent_sets.weight, most_recent_sets.reps
    ORDER BY
      e.id;`,
		form.routine_id,
	)
	query_res_2 := exec_bin(conn, cmd_2)
	if pq.result_status(query_res_2) != .Tuples_OK {
		http.respond_with_status(res, .Internal_Server_Error)
		log.error(pq.error_message(conn))
		return
	}
	defer pq.clear(query_res_2)

	if pq.n_tuples(query_res_2) > 0 do assert(pq.n_fields(query_res_2) == 5)

	exercises := results(Exercise_Query, query_res_2, context.temp_allocator)

	log.debug(exercises)

	b := strings.builder_make(context.temp_allocator)
	w := strings.to_writer(&b)

	routine_data := Routine_Data{name, exercises}
	layout_data := Layout_Data {
		Head_Data{title = name, scripts = {"htmx@2.0.0.js"}},
		Top_Nav_Data {
			profile_picture = "https://lh3.googleusercontent.com/a/AAcHTtcIA7reOrDrtSslK5DfbBWfqLtWbqxx4O1TVMQA1yO7Pg=s96-c",
		},
		routine_templater(&routine_data),
		Bottom_Nav_Data{selection = .Home},
	}
	layout_templater := layout_templater(&layout_data)
	layout_templater.template(&layout_templater, w)

	http.respond_html(res, strings.to_string(b))
}

Set_Query :: struct {
	id:           i32,
	weight, reps: i16,
}

Exercise_Query :: struct {
	id:           i32,
	name:         string,
	weight, reps: i16,
	sets:         []Set_Query,
}

Routine_Data :: struct {
	name:      string,
	exercises: []Exercise_Query,
}

routine_templater :: proc(routine_data: ^Routine_Data) -> Templater {
	t: Templater
	t.user_data = routine_data
	t.template = proc(t: ^Templater, w: io.Writer) {
		data := cast(^Routine_Data)t.user_data
		fmt.wprint(w, `<main class="px-8 pt-4 min-h-[80dvh] pb-20">`);{
			fmt.wprintf(
				w,
				`
        <div hx-boost="true" class="breadcrumbs text-sm">
          <ul>
            <li><a href="/">Home</a></li>
            <li>%[0]s</li>
          </ul>
        </div>`,
				data.name,
			)
			if len(data.exercises) == 0 {
				html := get_template("no-exercises")
				fmt.wprint(w, html)
				return
			}
			fmt.wprintf(w, `<ul class="grid gap-4 py-4">`);{
				for e in data.exercises {
					fmt.wprintf(w, `<li class="flex">`);{
						fmt.wprintf(
							w,
							`
              <button
                type="button"
                onclick="start_set_%[0]d.showModal()"
                class="btn btn-block btn-primary btn-outline"
              >
                %[1]s
              </button>`,
							e.id,
							e.name,
						)

						fmt.wprintf(
							w,
							`<dialog id="start_set_%[0]d" class="modal">
                 <div class="modal-box flex flex-col h-[80.8dvh] bg-base-200">
              `,
							e.id,
						);{
							fmt.wprintf(
								w,
								`<h3 class="text-lg font-bold">%[1]s</h3>
                <div class="overflow-x-auto py-4">
                  <table class="table">
                    <thead>
                      <tr>
                        <th>Weigth</th>
                        <th>Reps</th>
                      </tr>
                    </thead>
                    <tbody id="exercises-%[0]d">
                `,
								e.id,
								e.name,
							);{
								for set in e.sets {
									if set == (Set_Query{}) {
										continue
									}
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
										set.reps,
										set.weight,
										set.id,
									)
								}
							};fmt.wprint(w, `</tbody> </table> </div>`)


							fmt.wprintf(
								w,
								`
                <form
                  hx-post="/set"
                  hx-target="#exercises-%[0]d"
                  hx-swap="beforeend"
                  class="join grid grid-cols-3 mt-auto"
                >
                  <span>weight</span>
                  <span>reps</span>
                  <span></span>

                  <!-- change these to actual dile scroll thign -->
                  <input
                    type="text"
                    name="weight"
                    value="%[1]d"
                    class="rounded-l-lg rounded-r-none input input-success"
                  />
                  <input type="hidden" name="workout_id" value="1" />
                  <input type="hidden" name="exercise_id" value="%[0]d" />
                  <input
                    type="text"
                    name="reps"
                    value="%[2]d"
                    class="join-item rounded-r-none input input-success"
                  />
                  <button
                    type="submit"
                    class="join-item btn btn-success btn-outline"
                    onclick="stopTimer(); clearTimer(); startTimer()"
                  >
                    Finish Set
                  </button>
                </form>

                <div class="modal-action pt-2">
                  <form method="dialog">
                    <button class="btn">Close</button>
                  </form>
                </div>
              `,
								e.id,
								e.weight,
								e.reps,
							)
						};fmt.wprint(w, `</div> </dialog>`)

					};fmt.wprint(w, `</li>`)
				}
			};fmt.wprint(w, `</ul>`)
		};fmt.wprint(w, `</main>`)
	}
	return t
}

earliest_weekday :: proc(weekdays: Weekdays) -> time.Weekday {
	for w in time.Weekday do if w in weekdays do return .Monday
	unreachable()
}

post_set :: proc(req: ^http.Request, res: ^http.Response) {
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

	conn := pool_get(&pool)
	defer pool_release(&pool, conn)
	// TODO: remove workout_id from form, currently we will fetch it per set

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
	Form :: struct {
		set_id: i32,
	}
	form, ok_form := url_decode(Form, req.url.query, context.temp_allocator)

	conn := pool_get(&pool)
	defer pool_release(&pool, conn)
	// TODO: auth set delete with the workout_id
	cmd := fmt.ctprintf(`
    DELETE FROM sets
    WHERE id = %d`, form.set_id)

	query_res := exec_bin(conn, cmd)
	if pq.result_status(query_res) != .Command_OK {
		log.error(pq.error_message(conn))
		http.respond_with_status(res, .Internal_Server_Error)
		return
	}
	defer pq.clear(query_res)

	http.respond_with_status(res, .OK)
}
