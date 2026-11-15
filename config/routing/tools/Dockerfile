FROM debian:bookworm-slim
RUN apt-get update -qq && apt-get install --no-install-recommends -y osmium-tool curl ca-certificates python3 && rm -rf /var/lib/apt/lists/*
WORKDIR /data
