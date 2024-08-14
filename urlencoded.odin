package main

import "base:builtin"
import "base:intrinsics"
import "base:runtime"
import "core:log"
import "core:net"
import "core:slice"
import "core:strconv"
import "core:strings"

url_decode :: proc(
	$T: typeid,
	encoded: string,
	allocator := context.allocator,
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

	count := len(info.names)

	filled := 0
	for sp in strings.split_by_byte_iterator(&encoded, '&') {
		x := strings.index_rune(sp, '=')
		if x == -1 do return
		name, val := sp[:x], sp[x + 1:]
		col, found := slice.linear_search(info.names, name)
		if !found do continue
		filled += 1

		field_info := info.types[col]
		field_size := field_info.size
		field_offset := cast(int)info.offsets[col]

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

		case:
			log.panic("not implemented")
		}
	}

	if filled != len(info.names) do return

	return t, true
}
