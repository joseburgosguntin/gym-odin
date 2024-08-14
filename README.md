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

