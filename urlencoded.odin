package main

import "base:intrinsics"
import "base:runtime"
import "core:log"
import "core:net"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "shared/odin-http/nbio"

import http "./shared/odin-http"

url_decode :: proc(
	$T: typeid,
	encoded: string,
	allocator := context.allocator,
  loc := #caller_location,
) -> (
	t: T,
	ok: bool,
) where intrinsics.type_is_struct(T) ||
	intrinsics.type_is_named(T) {
	context.allocator = allocator
	encoded := encoded

	t_bytes := (cast([^]byte)&t)[:size_of(T)]
	old := type_info_of(typeid_of(T))
	#partial switch e in old.variant {
	case runtime.Type_Info_Named:
		old = e.base
	}
	info := old.variant.(runtime.Type_Info_Struct)


	filled := 0
	for sp in strings.split_by_byte_iterator(&encoded, '&') {
		x := strings.index_rune(sp, '=')
		if x == -1 do return
		name, val := sp[:x], sp[x + 1:]
		col, found := slice.linear_search(info.names[:info.field_count], name)
		if !found do continue

		field_info := info.types[col]
		field_size := field_info.size
		field_offset := cast(int)info.offsets[col]

    #partial switch v in field_info.variant {
    case runtime.Type_Info_Dynamic_Array, runtime.Type_Info_Bit_Set:
    case:
      filled += 1
      log.debug("single", info.names[col])
    }

		#partial switch f in field_info.variant {
		// TODO check if int value is out of range for bit_set
		case runtime.Type_Info_Integer, runtime.Type_Info_Bit_Set:
			n, ok_n := strconv.parse_i64(val)
			if !ok_n do return
			src := (cast([^]byte)&n)[:field_size]
			dst := t_bytes[field_offset:]
			copy(dst, src)

		case runtime.Type_Info_Float:
			switch field_size {
			case 4:
				n, ok_n := strconv.parse_f32(val)
				if !ok_n do return
				src := (cast([^]byte)&n)[:field_size]
				dst := t_bytes[field_offset:]
				copy(dst, src)
			case 8:
				n, ok_n := strconv.parse_f64(val)
				if !ok_n do return
				src := (cast([^]byte)&n)[:field_size]
				dst := t_bytes[field_offset:]
				copy(dst, src)

			case:
				log.panic("invalid float byte count")
			}

		case runtime.Type_Info_String:
			decoded, ok_decoded := net.percent_decode(val)
			if !ok_decoded do return
			raw := transmute(runtime.Raw_String)decoded

			src := (cast([^]byte)&raw)[:field_size]

			dst := t_bytes[field_offset:]

			copy(dst, src) // ptr & len

		case runtime.Type_Info_Boolean:
			b, ok_b := strconv.parse_bool(val)
			if !ok_b do return
			src := (cast([^]byte)&b)[:field_size]
			dst := t_bytes[field_offset:]
			copy(dst, src)

    case runtime.Type_Info_Slice:
      log.panicf("use `[dynamic]%t` instead for %t", f.elem.id, typeid_of(T), location=loc)

    case runtime.Type_Info_Dynamic_Array:
      #partial switch idk in f.elem.variant {
      case runtime.Type_Info_Integer:
        if f.elem_size != size_of(i32) {
          log.panic("currently only supports i32 for integers")
        }
        dst := cast(^[dynamic]i32)raw_data(t_bytes[field_offset:])
        n, ok_n := strconv.parse_i64(val)
        if !ok_n do return
        append(dst, cast(i32)n)
      case runtime.Type_Info_String:
        dst := cast(^[dynamic]string)raw_data(t_bytes[field_offset:])

        decoded, ok_decoded := net.percent_decode(val)
        if !ok_decoded do return
        append(dst, decoded)
      }
   //  case runtime.Type_Info_Bit_Set:
   //    if f.underlying.size != size_of(u8) {
   //      log.panic("currently only supports u8 for bit_set's")
   //    }
			// n, ok_n := strconv.parse_i64(val)
			// if !ok_n do return
   //    dst := cast(^bit_set[0..<8;u8])raw_data(t_bytes[field_offset:])
   //    dst^ |= bit_set[0..<8;u8] {cast(int)n}

		case:
			log.panic("not implemented")
		}
	}

  for type, i in info.types[:info.field_count] {
    #partial switch v in type.variant {
    case runtime.Type_Info_Dynamic_Array, runtime.Type_Info_Bit_Set:
      filled += 1
      log.debug("multi", info.names[i])
    }
  }

  log.debug(filled, '/', info.field_count)
	if filled != cast(int)info.field_count do return

	return t, true
}

MAX_BODY_SIZE :: 5120

url_decode_body :: proc(
	$T: typeid,
	req: ^http.Request,
	allocator := context.allocator,
  loc := #caller_location,
) -> (
	t: T,
	ok: bool,
) {
	CheckedForm :: struct {
		using f: T,
		ok:      bool,
    loc: type_of(loc),
	}
	form: CheckedForm
  form.loc = loc
	http.body(
		req,
		MAX_BODY_SIZE,
		&form,
		proc(user_data: rawptr, body: http.Body, err: http.Body_Error) {
      // handle too big error better
			c := cast(^CheckedForm)user_data
			c.f, c.ok = url_decode(T, body, context.temp_allocator, loc=c.loc)
		},
	)
  nbio.tick(&http.td.io)

	return form.f, form.ok
}
