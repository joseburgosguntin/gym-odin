# node (alpine) end
FROM node:18-alpine AS node

  WORKDIR /app
  ADD \
    package.json package-lock.json \
    tailwind.config.js static/input.css \
    *.odin \ 
    ./
  ADD static ./static
  ADD templates ./templates

  RUN npm ci
  RUN npx tailwind -i ./input.css -o ./output.css
# node end

# odin (ubuntu) start
FROM joseburgos/odin:dev-2024-12-ubuntu AS odin
  RUN apt-get update && apt-get install -y libpq-dev

  WORKDIR /gym-odin
  ADD static ./static
  ADD templates ./templates
  ADD shared ./shared
  ADD *.odin ./
  COPY --from=node /app/output.css ./static/output.css

  RUN odin build .
  ENTRYPOINT ["./gym-odin"]
  EXPOSE 6969
# odin end
