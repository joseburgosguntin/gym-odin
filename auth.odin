package main

import "core:bytes"
import "core:crypto"
import "core:crypto/sha3"
import "core:encoding/base64"
import "core:encoding/json"
import "core:encoding/uuid"
import "core:fmt"
import "core:io"
import "core:log"
import "core:math/rand"
import "core:net"
import "core:os"
import "core:strings"
import "core:text/match"
import "core:time"

import http "./shared/odin-http"
import httpc "./shared/odin-http/client"
import pq "./shared/odin-postgresql"


GOOGLE_AUTH_URL :: "https://accounts.google.com/o/oauth2/v2/auth"
GOOGLE_TOKEN_URL :: "https://www.googleapis.com/oauth2/v3/token"
GOOGLE_USER_INFO_URL :: "https://www.googleapis.com/oauth2/v2/userinfo"
GOOGLE_REVOCATION_URL :: "https://oauth2.googleapis.com/revoke"
GOOGLE_EMAIL_SCOPE :: "https://www.googleapis.com/auth/userinfo.email"
GOOGLE_CLIENT_ID: string
GOOGLE_CLIENT_SECRET: string

@(init)
env_google :: proc() {
	GOOGLE_CLIENT_ID_ENV :: "GOOGLE_CLIENT_ID"
	google_client_id, ok_google_client_id := os.lookup_env(
		GOOGLE_CLIENT_ID_ENV,
		context.temp_allocator,
	)
	log.assertf(
		ok_google_client_id,
		"remember to export %s",
		GOOGLE_CLIENT_ID_ENV,
	)
	GOOGLE_CLIENT_ID = google_client_id

	GOOGLE_CLIENT_SECRET_ENV :: "GOOGLE_CLIENT_SECRET"
	google_client_secret, ok_google_client_secret := os.lookup_env(
		GOOGLE_CLIENT_SECRET_ENV,
		context.temp_allocator,
	)
	log.assertf(
		ok_google_client_id,
		"remember to export %s",
		GOOGLE_CLIENT_SECRET_ENV,
	)
	GOOGLE_CLIENT_SECRET = google_client_secret
}

@(thread_local) local_user_id: i32
@(thread_local) local_ok_user_id: bool

get_user_id :: proc(conn: pq.Conn, req: ^http.Request) -> (s: i32, ok: bool) {
	token := http.request_cookie_get(req, "session_token") or_return
	split := strings.index_byte(token, '_')
	if split == -1 {
		log.error("couldn't split")
		return
	}
	p1, p2 := token[:split], token[min(split + 1, len(token)):]
	cmd := fmt.ctprintf(
		`
    SELECT user_id, CURRENT_TIMESTAMP, expires_at,session_token_p2 
    FROM user_sessions WHERE session_token_p1='%[0]s'`,
		p1,
	)
	query_res := exec_bin(conn, cmd)
	if pq.result_status(query_res) != .Tuples_OK do return
	defer pq.clear(query_res)

	Result :: struct {
		user_id:          i32,
		now, expires_at:  i64,
		session_token_p2: string,
	}
	results_1 := results(Result, query_res, context.temp_allocator)
	if len(results_1) < 1 {
		log.error("couldn't find with seesion_token_p1 %s", p1)
		return
	}
	result_1 := results_1[0]
	if result_1.expires_at < result_1.now do return
	// change this to const cmp
	if result_1.session_token_p2 != p2 do return

	return result_1.user_id, true
}

auth_handler_proc :: proc(
	h: ^http.Handler,
	req: ^http.Request,
	res: ^http.Response,
) {
	conn := pool_get(&pool)
	defer pool_release(&pool, conn)
	user_id, ok_user_id := get_user_id(conn, req)
	local_user_id = user_id
	local_ok_user_id = ok_user_id
	defer local_ok_user_id = false

	if !ok_user_id {
		log.warnf("wasnt logged in: %s", req.url.raw)
		http.headers_set(&res.headers, "location", "/login")
		http.respond_with_status(res, .Temporary_Redirect)
		return
	}
	next, ok_next := h.next.?
	log.assertf(ok_next, "router was not set to next")
	next.handle(next, req, res)
}

base64_url :: proc(bytes: []byte, allocator := context.allocator) -> string {
	context.allocator = allocator
  //odinfmt: disable
  URL_ENC_TABLE :: [64]byte {
    'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H',
    'I', 'J', 'K', 'L', 'M', 'N', 'O', 'P',
    'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X',
    'Y', 'Z', 'a', 'b', 'c', 'd', 'e', 'f',
    'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n',
    'o', 'p', 'q', 'r', 's', 't', 'u', 'v',
    'w', 'x', 'y', 'z', '0', '1', '2', '3', 
    '4', '5', '6', '7', '8', '9', '-', '_',
  }
  //odinfmt: enable
	x_64 := base64.encode(bytes, URL_ENC_TABLE)
	x_eq := strings.index_byte(x_64, '=')
	if x_eq != -1 do x_64 = x_64[:x_eq]
	return x_64
}

// this wont right cuz currently anything thats not static gets authed
google_login :: proc(req: ^http.Request, res: ^http.Response) {
	Query :: struct {
		return_url: string,
	}
	q, ok_q := url_decode(Query, req.url.query, context.temp_allocator)
	if !ok_q {
		log.warn("couldn't parse", req.url.query)
		http.respond_with_status(res, .Not_Found)
		return
	}

	host, ok_host := http.headers_get(req.headers, "host")
	if !ok_host {
		log.warn("couldn't find host header")
		http.respond_with_status(res, .Not_Found)
		return
	}

	verifier: [128]byte
	assert(rand.read(verifier[:]) == 128)
	c: sha3.Context
	sha3.init_256(&c)
	sha3.update(&c, verifier[:])
	challenge: [32]byte // 256 / 32 == 8 (byte)
	sha3.final(&c, challenge[:])

	csrf_state := rand.int127()
	state_bytes := (cast([^]byte)&csrf_state)[:size_of(csrf_state)]
	state_64 := base64_url(state_bytes, context.temp_allocator)

	conn := pool_get(&pool)
	defer pool_release(&pool, conn)

	// verifier_64 := base64_url(verifier[:], context.temp_allocator) 
	verifier_64 := "idZgc-fJRnkM7mTroPviS4XQROOHGzJWZ2Vozbb963Q"
	log.info(verifier_64)
	// challenge_64 := base64_url(challenge[:], context.temp_allocator) 
	challenge_64 := "wlIwEQAFJATHVPtcMdpklIVdzlkXK4TBYz8iT4ik6UE"
	log.info(challenge_64)
	return_url_esc := pq.escape_literal(
		conn,
		strings.clone_to_cstring(q.return_url, context.temp_allocator),
		cast(uint)len(q.return_url),
	)
	cmd := fmt.ctprintf(
		`
    INSERT INTO oauth2_state_storage(
      csrf_state, 
      pkce_code_verifier, 
      return_url
    )
    VALUES ('%s', '%s', %s)`,
		state_64,
		verifier_64,
		return_url_esc,
	)
	log.debug(cmd)
	query_res := exec_bin(conn, cmd)
	if pq.result_status(query_res) != .Command_OK {
		log.error(pq.error_message(conn), q.return_url)
		http.respond_with_status(res, .Internal_Server_Error)
		return
	}
	defer pq.clear(query_res)

	scheme := "https"
	if strings.starts_with(host, "localhost") do scheme = "http"
	if strings.starts_with(host, "127.0.0.1") do scheme = "http"
  RESPONSE_TYPE :: "code"
  CHALLENGE_METHOD :: "S256"
	redirect_uri := fmt.tprintf("%s://%s/google_callback", scheme, host)
	scopes := strings.join({GOOGLE_EMAIL_SCOPE}, " ", context.temp_allocator)
	authorize_url := fmt.tprintf(
		"%s?response_type=%s&client_id=%s&state=%s&code_challenge=%s&code_challenge_method=%s&redirect_uri=%s&scope=%s",
		GOOGLE_AUTH_URL,
		RESPONSE_TYPE,
		GOOGLE_CLIENT_ID,
		state_64,
		challenge_64,
		CHALLENGE_METHOD,
		redirect_uri,
		scopes,
	)
	log.debug(redirect_uri)
	// authorize_url := fmt.tprintf(
	// 	"%s?client_id=%s&state=%s&redirect_uri=%s",
	// 	AUTH_URL,
	// 	client_id,
	// 	state_64,
	// 	redirect_uri,
	// )
	http.headers_set(&res.headers, "location", authorize_url)
	http.respond_with_status(res, .Temporary_Redirect)
}


// this wont right cuz currently anything thats not static gets authed
google_callback :: proc(req: ^http.Request, res: ^http.Response) {
	Query :: struct {
		state, code: string,
	}
	q, ok_q := url_decode(Query, req.url.query, context.temp_allocator)
	if !ok_q {
		log.warn("couldn't parse", req.url.query)
		http.respond_with_status(res, .Not_Found)
		return
	}

	// state_eq := strings.index_byte(q.state, '=')
	// if state_eq != -1 do q.state = q.state[:state_eq]

	host, ok_host := http.headers_get(req.headers, "host")
	if !ok_host {
		log.warn("couldn't parse", req.url.query)
		http.respond_with_status(res, .Not_Found)
		return
	}

	scheme := "https"
	if strings.starts_with(host, "localhost") do scheme = "http"
	if strings.starts_with(host, "127.0.0.1") do scheme = "http"
	redirect_uri := fmt.tprintf("%s://%s/google_callback", scheme, host)

	conn := pool_get(&pool)
	defer pool_release(&pool, conn)

	state_esc := pq.escape_literal(
		conn,
		strings.clone_to_cstring(q.state, context.temp_allocator),
		cast(uint)len(q.state),
	)
	defer pq.free_mem(transmute(rawptr)state_esc)
	cmd := fmt.ctprintf(
		`
    DELETE FROM oauth2_state_storage 
      WHERE csrf_state = %s 
      RETURNING pkce_code_verifier, return_url`,
		state_esc,
	)
	query_res := exec_bin(conn, cmd)
	if pq.result_status(query_res) != .Tuples_OK {
		log.error(pq.error_message(conn))
		http.respond_with_status(res, .Internal_Server_Error)
		return
	}
	defer pq.clear(query_res)
	Result :: struct {
		verifier_64, return_url: string,
	}
	results_1 := results(Result, query_res, context.temp_allocator)
	if len(results_1) < 1 {
		log.error("couldn't find oauth2_state with that state", state_esc)
		http.respond_with_status(res, .Not_Found)
		return
	}
	result_1 := results_1[0]
	log.info(result_1.verifier_64)

	scopes := strings.join({GOOGLE_EMAIL_SCOPE}, " ", context.temp_allocator)

	token_req: httpc.Request
	httpc.request_init(&token_req, .Post, context.temp_allocator)
	http.headers_set(&token_req.headers, "accept", "application/json")
	http.headers_set(
		&token_req.headers,
		"content-type",
		"application/x-www-form-urlencoded",
	)

	req_body: bytes.Buffer
	// net.percent_encode()
	bytes.buffer_init_allocator(&req_body, 0, 0, context.temp_allocator)
	w: io.Writer = bytes.buffer_to_stream(&req_body)
	log.debug(q.code)
	fmt.wprintf(
		w,
		"grant_type=authorization_code&code=%s&code_verifier=%s&scope=%s&client_id=%s&client_secret=%s&redirect_uri=%s",
		net.percent_encode(q.code, context.temp_allocator),
		net.percent_encode(result_1.verifier_64, context.temp_allocator),
		net.percent_encode(scopes, context.temp_allocator),
		net.percent_encode(GOOGLE_CLIENT_ID, context.temp_allocator),
		net.percent_encode(GOOGLE_CLIENT_SECRET, context.temp_allocator),
		net.percent_encode(redirect_uri, context.temp_allocator),
	)
	// fmt.wprintf(
	// 	w,
	// 	"code=%s&client_id=%s&client_secret=%s&redirect_uri=%s",
	// 	net.percent_encode(q.code, context.temp_allocator),
	// 	client_id,
	// 	client_secret,
	// 	net.percent_encode(redirect_uri, context.temp_allocator),
	// )
	token_req.body = req_body
	token_res, err_token_res := httpc.request(
		&token_req,
		GOOGLE_TOKEN_URL,
		context.temp_allocator,
	)
	if err_token_res != nil {
		log.error(err_token_res)
		http.respond_with_status(res, .Not_Found)
		return
	}

	token_body_type, _, err_token_body := httpc.response_body(
		&token_res,
		-1,
		context.temp_allocator,
	)
	if err_token_body != nil {
		log.error("body_err:", err_token_body)
		http.respond_with_status(res, .Not_Found)
		return
	}
	token_plain_body, ok_plain_body := token_body_type.(httpc.Body_Plain)
	log.debug(token_plain_body)
	if !ok_plain_body {
		log.error("wrong body type got:", token_body_type)
		http.respond_with_status(res, .Not_Found)
		return
	}

	Token_Body :: struct {
		access_token, scope, token_type, id_token: string,
		expires_in:                                int,
	}
	token_body: Token_Body
	token_body_unmarshal_err := json.unmarshal(
		transmute([]byte)token_plain_body,
		&token_body,
	)
	log.debug(token_body_unmarshal_err)
	if token_body_unmarshal_err != nil {
		log.error(token_body_unmarshal_err)
		log.error(token_plain_body)
		http.respond_with_status(res, .Not_Found)
		return
	}
	log.debug(token_body)

	user_info_res, err_user_info_res := httpc.get(
		fmt.tprintf(
			"%s?oauth_token=%s",
			GOOGLE_USER_INFO_URL,
			token_body.access_token,
		),
		context.temp_allocator,
	)
	if err_user_info_res != nil {
		log.error(err_user_info_res)
		http.respond_with_status(res, .Internal_Server_Error)
		return
	}
	user_info_body_type, _, err_user_info := httpc.response_body(
		&user_info_res,
		-1,
		context.temp_allocator,
	)
	if err_user_info != nil {
		log.error("wrong body type got:", err_user_info)
		http.respond_with_status(res, .Not_Found)
		return
	}

	user_info_plain_body, ok_user_info_plain_body := user_info_body_type.(httpc.Body_Plain)
	log.debug(user_info_plain_body)
	if !ok_user_info_plain_body {
		log.error("wrong body type got:", user_info_body_type)
		http.respond_with_status(res, .Not_Found)
		return
	}

	User_Info_Body :: struct {
		email, picture: string,
		verified_email: bool,
	}

	user_info_body: User_Info_Body
	user_info_unmarshal_err := json.unmarshal(
		transmute([]byte)user_info_plain_body,
		&user_info_body,
	)
	log.debug(user_info_unmarshal_err)
	if user_info_unmarshal_err != nil {
		log.error(user_info_unmarshal_err)
		log.error(user_info_plain_body)
		http.respond_with_status(res, .Not_Found)
		return
	}
	log.debug(user_info_body)

	// Github_Body :: struct {
	// 	access_token, token_type, scope: string,
	// }
	// github_body: Google_Body
	// unmarshal_err := json.unmarshal(transmute([]byte)plain_body, &github_body)
	//  log.debug(unmarshal_err)
	//  if unmarshal_err != nil {
	// 	log.error(unmarshal_err)
	// 	log.error(plain_body)
	// 	http.respond_with_status(res, .Not_Found)
	// 	return
	//  }
	//  log.debug(github_body)
	if !user_info_body.verified_email {
		log.warn("email must be verified")
		http.respond_with_status(res, .Not_Found)
		return
	}

	cmd_2 := fmt.ctprintf(
		`
    INSERT INTO users (email, picture)
      VALUES ('%[0]s', '%[1]s')
      ON CONFLICT (email) 
      DO UPDATE SET picture = EXCLUDED.picture
      RETURNING id;`,


		// `
		//   WITH existing_user AS (
		//     SELECT id FROM users WHERE email = '%[0]s'
		//   )
		//   INSERT INTO users (email, picture)
		//     SELECT '%[0]s', '%[1]s'
		//     WHERE NOT EXISTS (SELECT 1 FROM existing_user);`,
		// `
		//   WITH existing_user AS (
		//     SELECT id FROM users WHERE email = '%[0]s'
		//   )
		//   INSERT INTO users (email, picture)
		//     SELECT '%[0]s', '%[1]s'
		//     WHERE NOT EXISTS (SELECT 1 FROM existing_user)
		//   RETURNING COALESCE(
		//     (SELECT id FROM existing_user), 
		//     (SELECT id FROM users WHERE email = '%[0]s')
		//   );`,
		user_info_body.email,
		user_info_body.picture,
	)
	query_res_2 := exec_bin(conn, cmd_2)
	if pq.result_status(query_res_2) != .Tuples_OK {
		log.error(pq.error_message(conn))
		http.respond_with_status(res, .Internal_Server_Error)
		return
	}
	defer pq.clear(query_res_2)

	Result_2 :: struct {
		user_id: i32,
	}

	results_2 := results(Result_2, query_res_2, context.temp_allocator)
	if len(results_2) < 1 {
		log.error("issue inserting user")
		http.respond_with_status(res, .Not_Found)
		return
	}
	result_2 := results_2[0]

	// rand.
	context.random_generator = crypto.random_generator()
	p_1 := uuid.to_string(uuid.generate_v4())
	p_2 := uuid.to_string(uuid.generate_v4())
	context.random_generator = rand.default_random_generator()

	now := time.now()

	cmd_3 := fmt.ctprintf(
		`
    INSERT INTO user_sessions (
      session_token_p1, 
      session_token_p2, 
      user_id, 
      created_at, 
      expires_at
    )
    VALUES (
      '%s', 
      '%s', 
      %d, 
      CURRENT_TIMESTAMP, 
      CURRENT_TIMESTAMP + '7 day'
    );`,
		p_1,
		p_2,
		result_2.user_id,
	)
	query_res_3 := exec_bin(conn, cmd_3)
	if pq.result_status(query_res_3) != .Command_OK {
		log.error(pq.error_message(conn))
		http.respond_with_status(res, .Internal_Server_Error)
		return
	}
	defer pq.clear(query_res_3)

	append(
		&res.cookies,
		http.Cookie {
			name = "session_token",
			value = fmt.tprintf("%s_%s", p_1, p_2),
			path = "/",
      http_only = true,
      secure = true,
      same_site = .Strict,
		},
	)
	cringe := fmt.tprintf(
		`
    <head>
      <meta charset="UTF-8" />
      <meta name="viewport" content="width=device-width, initial-scale=1" />
      <title>Loading - Gym</title>
      <link href="output.css" rel="stylesheet" />
    </head>
    <html>
      <body>
        <script>
          window.location.href = '%s';
        </script>
      </body>
    </html>`,
		result_1.return_url,
	)
	http.respond_html(res, cringe)
}


Authed_Unauthed :: struct {
	authed, unauthed: ^http.Router,
}


// | auth_middleware |> authed
// | unauthed
// | Not_Found
authed_unauthed_handler :: proc(
	authed_unauthed: ^Authed_Unauthed,
) -> http.Handler {
	h: http.Handler
	h.user_data = authed_unauthed
	h.handle =
	proc(handler: ^http.Handler, req: ^http.Request, res: ^http.Response) {
		data := cast(^Authed_Unauthed)(handler.user_data)
		rline := req.line.(http.Requestline)

		if routes_try_auth(data.authed.routes[rline.method], req, res) {
			return
		}

		if routes_try_auth(data.authed.all, req, res) {
			return
		}

		if routes_try_unauthed(data.unauthed.routes[rline.method], req, res) {
			return
		}

		if routes_try_unauthed(data.unauthed.all, req, res) {
			return
		}

		res.status = .Not_Found
		if res.status == .Not_Found do log.warnf("no route matched %s %s", http.method_string(rline.method), rline.target)
	}

	return h
}

routes_try_unauthed :: proc(
	routes: [dynamic]http.Route,
	req: ^http.Request,
	res: ^http.Response,
) -> bool {
	try_captures: [match.MAX_CAPTURES]match.Match = ---
	for route in routes {
		n, err := match.find_aux(
			req.url.path,
			route.pattern,
			0,
			true,
			&try_captures,
		)
		if err != .OK {
			log.errorf("Error matching route: %v", err)
			continue
		}

		if n > 0 {
			captures := make([]string, n - 1, context.temp_allocator)
			for cap, i in try_captures[1:n] {
				captures[i] = req.url.path[cap.byte_start:cap.byte_end]
			}

			req.url_params = captures
			rh := route.handler
			rh.handle(&rh, req, res)
			return true
		}
	}

	return false
}


routes_try_auth :: proc(
	routes: [dynamic]http.Route,
	req: ^http.Request,
	res: ^http.Response,
) -> bool {
	try_captures: [match.MAX_CAPTURES]match.Match = ---
	for route in routes {
		n, err := match.find_aux(
			req.url.path,
			route.pattern,
			0,
			true,
			&try_captures,
		)
		if err != .OK {
			log.errorf("Error matching route: %v", err)
			continue
		}

		if n > 0 {
			captures := make([]string, n - 1, context.temp_allocator)
			for cap, i in try_captures[1:n] {
				captures[i] = req.url.path[cap.byte_start:cap.byte_end]
			}

			req.url_params = captures
			rh := route.handler
			// maybe rh has problems do i have to new?
			authed := http.middleware_proc(
				new_clone(route.handler, context.temp_allocator),
				auth_handler_proc,
			)
			authed.handle(new_clone(authed, context.temp_allocator), req, res)
			return true
		}
	}

	return false
}

logout :: proc(req: ^http.Request, res: ^http.Response) {
	val, ok_val := http.request_cookie_get(req, "session_token")
	if !ok_val {
		log.error("cookie wasn't set")
		http.respond_with_status(res, .Not_Found)
		return
	}
	split := strings.index_byte(val, '_')
	if split == -1 {
		log.error("couldn't split")
		return
	}
	p1 := val[:split]

	conn := pool_get(&pool)
	defer pool_release(&pool, conn)

	cmd := fmt.ctprintf(
		`DELETE FROM user_sessions WHERE session_token_p1 = '%s';`,
		p1,
	)

	query_res := exec_bin(conn, cmd)
	if pq.result_status(query_res) != .Command_OK {
		log.warn("didn't delete any session tokens")
	}
	defer pq.clear(query_res)

	append(
		&res.cookies,
		http.Cookie {
			name = "session_token",
			value = "deleted",
			path = "/",
			expires_gmt = time.Time{0},
		},
	)

	http.headers_set(&res.headers, "location", "/login")
	http.respond_with_status(res, .Temporary_Redirect)
}
