package main

import "base:intrinsics"
import "core:log"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"

import pq "./shared/odin-postgresql"

CONNINFO: cstring

@(init)
env_db :: proc() {
	DATABASE_URL_ENV ::
		"DATABASE_URL_DEV" when #config(DB_DEV, DEV) else "DATABASE_URL_PROD"
	database_url, ok_database_url := os.lookup_env(
		DATABASE_URL_ENV,
		context.temp_allocator,
	)
	log.assertf(ok_database_url, "remember to export %s", DATABASE_URL_ENV)
	CONNINFO = strings.clone_to_cstring(database_url)
}

Pg_Pool_Atomic :: struct {
	free_list:   []bool,
	connections: []pq.Conn,
}

FREE, USED :: true, false

pool_init :: proc(p: ^Pg_Pool_Atomic, cap, init_count: int) {
	log.assertf(init_count <= cap, "can't have more than N connections")
	p.free_list = make([]bool, cap)
	p.connections = make([]pq.Conn, cap)
	for &is_free in p.free_list do is_free = FREE
	for i in 0 ..< init_count do p.connections[i] = pq.connectdb(CONNINFO)
}

pool_get :: proc(p: ^Pg_Pool_Atomic) -> pq.Conn {
	i, ok_i := -1, false
	for &b, j in p.free_list {
		if intrinsics.atomic_load_explicit(&b, .Acquire) == FREE {
			i, ok_i = j, true
			break
		}
	}
	log.assert(ok_i, "thread count should equal pool count")
	intrinsics.atomic_store_explicit(&p.free_list[i], USED, .Release)
	// maybe i have exclusize here
	conn := p.connections[i]
	if pq.status(conn) == .Ok do return conn
	if conn == nil {
		p.connections[i] = pq.connectdb(CONNINFO)
		return p.connections[i]
	}
	pq.reset(conn)
	return conn
}

pool_release :: proc(p: ^Pg_Pool_Atomic, conn: pq.Conn) {
	i, ok_i := slice.linear_search(p.connections[:], conn)
	log.assert(ok_i, "thread count should equal pool count")
	intrinsics.atomic_store_explicit(&p.free_list[i], FREE, .Release)
}

pool_destroy :: proc(p: ^Pg_Pool_Atomic) {
	// can we asume this is fine?
	p.free_list = {}
	for conn in p.connections do pq.finish(conn)
}
