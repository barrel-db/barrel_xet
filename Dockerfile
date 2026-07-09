# Multi-stage build for the barrel_xet CAS server.
#
# Build stage compiles the prod release (including the rocksdb and NIF C
# code) on the official Erlang image; the runtime stage is a slim Debian
# with only the shared libraries rocksdb links. The runtime base must
# match the erlang:29 base (Debian 13 "trixie") for ABI compatibility.

FROM erlang:29 AS build
RUN apt-get update && apt-get install -y --no-install-recommends \
        cmake build-essential git \
        liblz4-dev libsnappy-dev libzstd-dev zlib1g-dev libbz2-dev \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY . .
RUN rebar3 as prod tar

FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
        libstdc++6 liblz4-1 libsnappy1v5 libzstd1 zlib1g libbz2-1.0 libssl3t64 \
        ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*
RUN groupadd -r barrel-xet \
    && useradd -r -g barrel-xet -d /var/lib/barrel_xet barrel-xet \
    && mkdir -p /opt/barrel_xet /var/lib/barrel_xet \
    && chown -R barrel-xet:barrel-xet /var/lib/barrel_xet
COPY --from=build /src/_build/prod/rel/barrel_xet/barrel_xet-*.tar.gz /tmp/rel.tar.gz
RUN tar -xzf /tmp/rel.tar.gz -C /opt/barrel_xet && rm /tmp/rel.tar.gz \
    && chown -R barrel-xet:barrel-xet /opt/barrel_xet
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
# HOME lives in the data volume so the distribution cookie persists there
# and `docker exec ... eval` works for token reloads and admin commands.
ENV HOME=/var/lib/barrel_xet \
    ERL_DIST_PORT=9100 \
    BARREL_XET_DATA_DIR=/var/lib/barrel_xet \
    BARREL_XET_TOKENS_FILE=/var/lib/barrel_xet/tokens
USER barrel-xet
VOLUME /var/lib/barrel_xet
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s \
    CMD curl -fsS http://127.0.0.1:8080/healthz || exit 1
ENTRYPOINT ["/entrypoint.sh"]
CMD ["foreground"]
