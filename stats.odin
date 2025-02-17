package main

import "core:fmt"
import "core:io"
import "core:strings"

import http "./shared/odin-http"
import pq "./shared/odin-postgresql"

stats :: proc(req: ^http.Request, res: ^http.Response) {
	conn := pool_get(&pool)
	defer pool_release(&pool, conn)

	b := strings.builder_make(context.temp_allocator)
	w := strings.to_writer(&b)

	stats_data := Stats_Data{}
	layout_data := Layout_Data {
		Head_Data{title = "Statistics", scripts = {"htmx@2.0.0.js"}},
		Top_Nav_Data {
			profile_picture = "/web/android-chrome-512x512.png",
		},
		stats_templater(&stats_data),
		Bottom_Nav_Data{selection = .Stats},
	}
	layout_templater := layout_templater(&layout_data)
	layout_templater.template(&layout_templater, w)

	http.respond_html(res, strings.to_string(b))
}

Stats_Data :: struct {}

stats_templater :: proc(stats_data: ^Stats_Data) -> Templater {
	t: Templater
	t.user_data = stats_data
	t.template = proc(t: ^Templater, w: io.Writer) {
		data := cast(^Stats_Data)t.user_data
		html := get_template("stats")
		fmt.wprint(w, html)
	}
	return t
}
