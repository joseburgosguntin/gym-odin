CREATE TABLE users (
    id serial PRIMARY KEY,
    email text NOT NULL UNIQUE,
    picture text NOT NULL
);

CREATE TABLE user_sessions (
    id serial PRIMARY KEY,
    user_id integer NOT NULL,
    session_token_p1 text NOT NULL,
    session_token_p2 text NOT NULL,
    created_at timestamptz NOT NULL,
    expires_at timestamptz NOT NULL
);

CREATE TABLE oauth2_state_storage (
    id serial PRIMARY KEY,
    csrf_state text NOT NULL,
    pkce_code_verifier text NOT NULL,
    return_url text NOT NULL
);
