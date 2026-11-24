# The mailio MCP server in a container. Build from the repository root:
#   docker build -t mailio-mcp .
# See apps/mailio_mcp/doc/docker.md for how to run it.

FROM erlang:28 AS build
# barrel_mcp's HTTP stack builds a small native library with cmake
RUN apt-get update \
 && apt-get install -y --no-install-recommends cmake build-essential \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY . .
# The server needs mailio and mailio_mcp only. Without the store, the build
# skips barrel_docdb and its native database.
RUN rm -rf apps/mailio_store \
 && rebar3 compile

FROM erlang:28-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 --home-dir /data mailio \
 && mkdir -p /data /config \
 && chown mailio /data
# bin/mailio-mcp finds the compiled libraries relative to itself
COPY --from=build /src/_build/default/lib /app/_build/default/lib
COPY apps/mailio_mcp/bin /app/apps/mailio_mcp/bin
USER mailio
WORKDIR /data
ENV MAILIO_MCP_CONFIG=/config/mail.config
VOLUME /data
EXPOSE 8420
ENTRYPOINT ["/app/apps/mailio_mcp/bin/mailio-mcp"]
CMD ["stdio"]
