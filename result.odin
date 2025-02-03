package main

import "base:intrinsics"
import "base:runtime"
import "core:log"
import "core:slice"
import "core:time"

import pq "./shared/odin-postgresql"

exec_bin :: proc(conn: pq.Conn, cmd: cstring) -> pq.Result {
	return pq.exec_params(conn, cmd, 0, nil, nil, nil, nil, .Binary)
}

results :: proc(
	$T: typeid,
	res: pq.Result,
	allocator := context.allocator,
	loc := #caller_location,
) -> []T {
	context.allocator = allocator
	row_info := type_info_of(typeid_of(T))
	#partial switch row_variant in row_info.variant {
	case runtime.Type_Info_Named:
		row_info = row_variant.base
	}
	rows := pq.n_tuples(res)
	cols, ok_cols := row_info.variant.(runtime.Type_Info_Struct)
	if !ok_cols do log.panicf("`%s` is not a struct", typeid_of(T), location = loc)
	if pq.n_fields(res) != cols.field_count {
		log.panicf(
			"query contained %d cols, expected %d (%v)",
			cast(int)pq.n_fields(res),
			cols.field_count,
			cols.names,
			location = loc,
		)
	}

	items := make([]T, rows, loc = loc)
	for &item, row in items {
		item_bytes := cast([^]byte)&item
		for col in 0 ..< cols.field_count {
			col_info := cols.types[col]
			col_size := col_info.size
			col_offset := cast(int)cols.offsets[col]
			col_bytes_len := pq.get_length(res, cast(i32)row, cast(i32)col)
			col_src := pq.get_value(
				res,
				cast(i32)row,
				cast(i32)col,
			)[:col_bytes_len]
			col_dst := item_bytes[col_offset:col_offset + col_size]
			#partial switch col_variant in col_info.variant {
			case runtime.Type_Info_Integer,
			     runtime.Type_Info_Float,
			     runtime.Type_Info_Bit_Set:
				if cast(int)col_bytes_len == 0 {
					log.warnf(
						"col %d was skipped because it size was 0 bytes",
						col,
						location = loc,
					)
					continue
				}
				if cast(int)col_bytes_len != col_size {
					log.panicf(
						"col %d was %d bytes, expected col of type %v to be %d bytes",
						col,
						col_bytes_len,
						col_info.id,
						col_size,
						location = loc,
					)
				}
				copy(col_dst, col_src)
				slice.reverse(col_dst) // flip endian

			case runtime.Type_Info_String:
				str_dst := make([]byte, col_bytes_len, loc = loc)
				copy(str_dst, col_src) // buffer
				raw := transmute(runtime.Raw_Slice)str_dst
				src := (cast([^]byte)&raw)[:size_of(raw)]
				copy(col_dst, src) // ptr and size
			case runtime.Type_Info_Slice:
				elem_info := col_variant.elem
				#partial switch elem_variant in col_variant.elem.variant {
				case runtime.Type_Info_Named:
					elem_info = elem_variant.base
				}
				log.info(elem_info.variant)
				// maybe should col_src
				src := pq.get_value(res, cast(i32)row, cast(i32)col)
				Array_Header :: struct #packed {
					num_dims, flags, elem_oid, dim_size, lower_bound: i32be,
				}
				array_header := (cast(^Array_Header)src[0:])^
				log.info(array_header)

				fields, ok_fields := elem_info.variant.(runtime.Type_Info_Struct)
				if !ok_fields do unimplemented("only structs allowed")
				log.info("fields", fields)

				Field_Header :: struct #packed {
					oid, len: i32be,
				}
				first_elem_len := (cast(^i32be)src[size_of(Array_Header):])^
				min_elem_len := size_of(i32be) * 3 + size_of(Field_Header)
				if cast(int)first_elem_len == min_elem_len {
					log.warn("first was skipped by odd calculation")
					continue
				}
				// this is were id and name go
				fields_dst := make(
					[]byte,
					elem_info.size * cast(int)array_header.dim_size,
					loc = loc,
				)
				n_dst := 0
				log.infof(
					"bytes: %d, e_size: %d",
					len(fields_dst),
					elem_info.size,
				)
				for elem in 0 ..< array_header.dim_size {
					log.info(elem)

					log.info(n_dst)
					elem_start := size_of(Array_Header) + n_dst
					log.info(elem_start)
					elem_len := (cast(^i32be)src[elem_start:])^
					log.warn(elem_len)
					n_dst += size_of(i32be)

					if elem_len == -1 {
						log.panicf(
							"row %d col %d expected no null elements in",
							row,
							col,
							location = loc,
						)
					}

					num_fields := (cast(^i32be)src[elem_start +
						size_of(i32be):])^
					n_dst += size_of(i32be)
					log.info(num_fields, fields.field_count)
					assert(cast(i32)num_fields == fields.field_count)

					n_field := 0
					for field in 0 ..< fields.field_count {
						field_start :=
							elem_start +
							size_of(i32be) +
							size_of(i32be) +
							n_field
						field_info := fields.types[field]
						field_size := field_info.size
						field_offset := cast(int)fields.offsets[field]

						field_header := (cast(^Field_Header)src[field_start:])^
						if cast(int)field_header.len == -1 {
							continue // change this its creating 1 empty
						}
						n_field += size_of(Field_Header)
						// n_dst += size_of(Field_Header)
						log.info(field_header)


						field_dst_start :=
							elem_info.size * cast(int)elem + field_offset
						field_dst := fields_dst[field_dst_start:field_dst_start +
						field_size]

						field_src_start := field_start + size_of(Field_Header)

						#partial switch field_variant in field_info.variant {
						case runtime.Type_Info_Integer,
						     runtime.Type_Info_Float:
							if cast(int)field_header.len != field_size {
								log.panicf(
									"row %d col %d array contained %d fields, expected %d (%v)",
									row,
									col,
									field_header.len,
									fields.field_count,
									fields.names,
									location = loc,
								)
							}
							field_src := src[field_src_start:field_src_start +
							field_size]
							copy(field_dst, field_src)
							slice.reverse(field_dst) // flip endian

						case runtime.Type_Info_String:
							str_dst := make([]byte, field_header.len)
							field_src := src[field_src_start:field_src_start +
							cast(int)field_header.len]
							copy(str_dst, field_src)
							raw := transmute(runtime.Raw_Slice)str_dst
							src := (cast([^]byte)&raw)[:size_of(raw)]
							copy(field_dst, src) // ptr and size

						case:
							log.panic(
								"field `%s` of type `%s` in field `%s` of struct `%s` is not implemented",
								fields.names[field],
								field_info.id,
								cols.names[col],
								elem_info.id,
								location = loc,
							)
						}

						n_field += cast(int)field_header.len
					}
					n_dst += n_field
				}

				// TODO: the fields_dst should aready be short enough
				raw := transmute(runtime.Raw_Slice)fields_dst[:array_header.dim_size]
				src_raw := (cast([^]byte)&raw)[:size_of(raw)]
				copy(col_dst, src_raw)

			case:
				if (col_info.id == time.Time) {
					copy(col_dst, col_src)
					n := cast(^i64)raw_data(col_dst)
					n^ = cast(i64)((cast(^i64be)raw_data(col_dst))^)
					n^ *= 1000 // from micro to nano
					n^ += 946684800 * 1_000_000_000 // to pg epoch
				} else {
					log.panic(
						"field `%s` of type `%s` not implemented",
						cols.names[col],
						col_info.id,
						location = loc,
					)
				}
			}
		}
	}

	return items
}

result_number :: proc(
	$T: typeid,
	res: pq.Result,
	row_number, column_number: i32,
) -> T where intrinsics.type_is_integer(T) ||
	intrinsics.type_is_float(T) ||
	intrinsics.type_is_bit_set(T) {
	assert(pq.get_length(res, row_number, column_number) == size_of(T))

	ptr := pq.get_value(res, row_number, column_number)
	bytes := ptr[:size_of(T)]
	// flip endian
	slice.reverse(bytes)

	return (cast(^T)(ptr))^
}

result_slice :: proc(
	$T: typeid,
	res: pq.Result,
	row_number, column_number: i32,
	allocator := context.allocator,
	loc := #caller_location,
) -> T where intrinsics.type_is_slice(T) {
	context.allocator = allocator
	len := pq.get_length(res, row_number, column_number)
	old_slice := pq.get_value(res, row_number, column_number)[:len]
	return slice.clone(old_slice, loc = loc)
}

result_string :: proc(
	$T: typeid/string,
	res: pq.Result,
	row_number, column_number: i32,
	allocator := context.allocator,
	loc := #caller_location,
) -> string {
	bytes := result_slice(
		[]byte,
		res,
		row_number,
		column_number,
		allocator,
		loc,
	)
	return transmute(string)bytes
}

result :: proc {
	result_number,
	result_slice,
	result_string,
}
