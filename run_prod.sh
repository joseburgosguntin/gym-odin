#!/bin/bash

# Run tailwindcss cli
npx tailwindcss -i ./static/input.css -o ./static/output.css &

wait $temple_pid

# Run Odin HTTP server
odin run . -o:speed
# odin run . -debug
