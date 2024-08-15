# gym-odin

## setup db

```sh
export DATABASE_URL="<database-connection-string>"
cargo install sqlx-cli
sqlx db setup
```

## run the web server

### dev

```sh
sudo apt-get install -y libpq-dev
```

```sh
export DATABASE_URL_DEV="<database-connection-string>"
export GOOGLE_CLIENT_ID="<google-client-id>"
export GOOGLE_CLIENT_SECRET="<google-client-secret>"
odin run . -debug
```

### prod

```sh
docker build -t gym-odin .
```

.env

```sh
DATABASE_URL_PROD="<database-connection-string>"
GOOGLE_CLIENT_ID="<google-client-id>"
GOOGLE_CLIENT_SECRET="<google-client-secret>"
```

```sh
docker run --env-file .env -p 6969:6969 -it gym-odin:latest
```
