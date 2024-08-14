CREATE TABLE workouts(
    id serial PRIMARY KEY,
    user_id integer NOT NULL,
    start_datetime timestamptz(0) NOT NULL
);

CREATE TABLE routines(
    id serial PRIMARY KEY,
    user_id integer NOT NULL,
    name varchar(255) NOT NULL,
    weekdays smallint NOT NULL,
    CONSTRAINT user_id_routine_name_unique UNIQUE (user_id, name)
);

CREATE TABLE sets(
    id serial PRIMARY KEY,
    exercise_id integer NOT NULL,
    workout_id integer NOT NULL,
    end_datetime timestamptz(0) NOT NULL,
    reps smallint NOT NULL,
    weight smallint NOT NULL
);

CREATE TABLE exercises(
    id serial PRIMARY KEY,
    user_id integer NOT NULL,
    name varchar(255) NOT NULL,
    CONSTRAINT user_id_exericise_name_unique UNIQUE (user_id, name)
);

CREATE TABLE routines_exercises(
    routine_id integer NOT NULL REFERENCES routines(id) ON DELETE CASCADE,
    exercise_id integer NOT NULL REFERENCES exercises(id) ON DELETE CASCADE,
    CONSTRAINT routines_exercises_pkey PRIMARY KEY (routine_id, exercise_id)
);

ALTER TABLE exercises 
    ADD CONSTRAINT exercises_users_id_foreign 
    FOREIGN KEY(user_id) REFERENCES users(id)
    ON DELETE CASCADE;

ALTER TABLE routines 
    ADD CONSTRAINT routines_users_id_foreign 
    FOREIGN KEY(user_id) REFERENCES users(id)
    ON DELETE CASCADE;

ALTER TABLE workouts 
    ADD CONSTRAINT workouts_users_id_foreign 
    FOREIGN KEY(user_id) REFERENCES users(id)
    ON DELETE CASCADE;

ALTER TABLE sets 
    ADD CONSTRAINT sets_exercises_id_foreign 
    FOREIGN KEY(exercise_id) REFERENCES exercises(id)
    ON DELETE CASCADE;
ALTER TABLE sets
    ADD CONSTRAINT sets_workouts_id_foreign 
    FOREIGN KEY(workout_id) REFERENCES workouts(id)
    ON DELETE CASCADE;
