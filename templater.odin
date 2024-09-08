package main

import "core:fmt"
import "core:io"

import http "./shared/odin-http"
import pq "./shared/odin-postgresql"

Templater_Proc :: proc(templater: ^Templater, w: io.Writer)
Templater :: struct {
	user_data: rawptr,
	template:  Templater_Proc,
}

Head_Data :: struct {
	title:   string,
	scripts: []string,
}

head_templater :: proc(head_data: ^Head_Data) -> Templater {
	t: Templater
	t.user_data = head_data
	t.template = proc(t: ^Templater, w: io.Writer) {
		data := cast(^Head_Data)t.user_data
		fmt.wprint(w, "<head>");{
			fmt.wprint(
				w,
				`
        <meta charset="UTF-8" />

        <link rel="icon" href="/web/favicon.png" />
        <link rel="apple-touch-icon" sizes="180x180" href="/web/apple-touch-icon.png" />
        <link rel="icon" type="image/png" sizes="32x32" href="/web/favicon-32x32.png" />
        <link rel="icon" type="image/png" sizes="16x16" href="web//favicon-16x16.png" />
        <link rel="manifest" href="/web/site.webmanifest" />
        <link rel="mask-icon" href="/web/safari-pinned-tab.svg" color="#dfae67" />
        <meta name="msapplication-TileColor" content="#11121d" />
        <meta name="theme-color" content="#11121d" />

        <meta name="viewport" content="width=device-width, initial-scale=1" />
        `,
			)

        // <meta name="viewport" content="viewport-fit=cover">
			fmt.wprintf(w, `<title>%s - Gym</title>`, data.title)
			fmt.wprint(w, `<link href="output.css" rel="stylesheet" />`)
			for script in data.scripts {
				fmt.wprintf(w, `<script src="%s"></script>`, script)
			}
		};fmt.wprint(w, "</head>")
	}
	return t
}


Top_Nav_Data :: struct {
	profile_picture: string,
}

top_nav_templater :: proc(top_nav_data: ^Top_Nav_Data) -> Templater {
	t: Templater
	t.user_data = top_nav_data
	t.template = proc(t: ^Templater, w: io.Writer) {
		data := cast(^Top_Nav_Data)t.user_data
		html := get_template("top-nav")
		fmt.wprintf(w, html, data.profile_picture)
	}
	return t
}

Bottom_Nav_Selection :: enum {
	Home,
	Edit,
	Stats,
}
Bottom_Nav_Data :: struct {
	selection: Bottom_Nav_Selection,
}

bottom_nav_templater :: proc(bottom_nav_data: ^Bottom_Nav_Data) -> Templater {
	t: Templater
	t.user_data = bottom_nav_data
	t.template = proc(t: ^Templater, w: io.Writer) {
		data := cast(^Bottom_Nav_Data)t.user_data
		a, b, c: string
		switch data.selection {
		case .Home:
			a = "active text-primary bg-base-300"
		case .Edit:
			b = "active text-primary bg-base-300"
		case .Stats:
			c = "active text-primary bg-base-300"
		}
		html := get_template("bottom-nav")
		fmt.wprintf(w, html, a, b, c)
	}
	return t
}

Layout_Data :: struct {
	head_data:       Head_Data,
	top_nav_data:    Top_Nav_Data,
	main:            Templater,
	bottom_nav_data: Bottom_Nav_Data,
}

layout_templater :: proc(layout_data: ^Layout_Data) -> Templater {
	t: Templater
	t.user_data = layout_data
	t.template = proc(t: ^Templater, w: io.Writer) {
		data := cast(^Layout_Data)t.user_data
		fmt.wprintf(w, "<!doctype html><html>");{
			head := head_templater(&data.head_data)
			head.template(&head, w)
			fmt.wprintf(w, `<body>`);{
				top_nav := top_nav_templater(&data.top_nav_data)
				top_nav.template(&top_nav, w)
				data.main.template(&data.main, w)
				bottom_nav := bottom_nav_templater(&data.bottom_nav_data)
				bottom_nav.template(&bottom_nav, w)
			};fmt.wprintf(w, `</body>`)
		};fmt.wprintf(w, "</html>")
	}
	return t
}
