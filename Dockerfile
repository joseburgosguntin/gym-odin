# node (alpine) end
FROM node:18-alpine AS node

  WORKDIR /app
  ADD \
    package.json package-lock.json \
    tailwind.config.js static/input.css \
    ./

  RUN npm ci
  RUN npx tailwind -i ./input.css -o ./output.css
# node end

# # odin (ubuntu) start
# FROM primeimages/odin:latest AS odin
#
#   RUN apt-get update && apt-get install -y libpq-dev
#
#   WORKDIR /gym-odin
#   ADD static ./static
#   ADD templates ./templates
#   ADD shared ./shared
#   ADD *.odin ./
#   COPY --from=node /app/output.css ./static/output.css
#
#   RUN odin build . 
#   ## -collection:shared=./shared/
#   ENTRYPOINT ["./gym-odin"]
#   EXPOSE 6969
# # odin end


## trying to fix the odin version

# odin (ubuntu) start
FROM ubuntu:22.04 AS odin

  RUN apt-get update -qq \
      && apt-get install -y llvm clang git build-essential

  WORKDIR /Odin-install
  RUN git clone https://github.com/joseburgosguntin/odin.git \ 
      /Odin-install \
      && git checkout f118a59175dde87c2cb09022d4373bfbfbd749fe \
      && make

  RUN mkdir /opt/Odin \
      && cp -R ./base ./core ./shared ./vendor ./odin /opt/Odin/
  WORKDIR /
  RUN rm -rf /Odin-install

  ENV PATH="/opt/Odin:${PATH}"

  # my part start
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
  # my part end
# odin end
