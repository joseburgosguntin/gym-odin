package main

import "base:builtin"
import "base:intrinsics"
import "base:runtime"
import "core:log"
import "core:slice"

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
	row_info := type_info_of(builtin.typeid_of(T))
	#partial switch row_variant in row_info.variant {
	case runtime.Type_Info_Named:
		row_info = row_variant.base
	}
	rows := pq.n_tuples(res)
	cols, ok_cols := row_info.variant.(runtime.Type_Info_Struct)
	if !ok_cols do unimplemented("only structs allowed")
	if cast(int)pq.n_fields(res) != len(cols.names) {
		log.panicf(
			"query contained %d cols, expected %d (%v)",
			cast(int)pq.n_fields(res),
			len(cols.names),
			cols.names,
		)
	}

	items := make([]T, rows, loc=loc)
	for &item, row in items {
		item_bytes := cast([^]byte)&item
		for col in 0 ..< len(cols.names) {
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
          log.warnf("col %d was skipped because it size was 0 bytes", col)
          continue
        }
				if cast(int)col_bytes_len != col_size {
					log.panicf(
						"col %d was %d bytes, expected col of type %v to be %d bytes",
            col,
						col_bytes_len,
						col_info.id,
						col_size,
					)
				}
				copy(col_dst, col_src)
				slice.reverse(col_dst) // flip endian
			case runtime.Type_Info_String:
				str_dst := make([]byte, col_bytes_len, loc=loc)
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
          loc=loc,
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
						)
					}

					num_fields := (cast(^i32be)src[elem_start +
						size_of(i32be):])^
					n_dst += size_of(i32be)
					log.info(cast(int)num_fields, len(fields.names))
					assert(cast(int)num_fields == len(fields.names))

					n_field := 0
					for field in 0 ..< len(fields.names) {
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
						     runtime.Type_Info_Float,
						     runtime.Type_Info_Bit_Set:
							if cast(int)field_header.len != field_size {
								log.panicf(
									"row %d col %d array contained %d fields, expected %d (%v)",
									row,
									col,
									field_header.len,
									len(fields.names),
									fields.names,
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
							unimplemented()
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
				unimplemented()
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
