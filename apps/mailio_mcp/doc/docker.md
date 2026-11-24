# Run the MCP server in a container

This page shows how to build the mailio MCP server as a container image and run it, over stdio for one local client or over HTTP for a shared deployment. You need it when you do not want to install Erlang on the machine that runs the server.

The image holds the server and nothing else: it needs no database, and it keeps its drafts, checkpoints and send records in `/data`. It runs as an unprivileged user.

## Get the image

CI publishes the image to GitHub's container registry on every change to `main`, for `linux/amd64` and `linux/arm64`:

```bash
docker pull ghcr.io/benoitc/mailio-mcp:latest
```

The examples below use the name `mailio-mcp`; tag the pulled image with `docker tag ghcr.io/benoitc/mailio-mcp:latest mailio-mcp`, or build it yourself.

## Build the image

From the repository root:

```bash
docker build -t mailio-mcp .
```

The build compiles `mailio` and `mailio_mcp` only. It does not build the store.

## Write the config

Start from `apps/mailio_mcp/docker/mail.config`. It defines one account, one caller (`assistant`) and the HTTP listener. Secrets are references to environment variables, so the file holds none:

| Variable | What it is |
|---|---|
| `WORK_MAIL_PASSWORD` | The password of the mail account |
| `MAILIO_MCP_JWT_SECRET` | The HS256 secret of the bearer tokens you issue, at least 32 bytes |
| `MAILIO_MCP_STATE_KEY` | Signs two-step requests, at least 32 bytes, the same on every node |

Generate the two keys once and keep them in your secret store:

```bash
openssl rand -base64 48
```

The `sub` claim of a bearer token must be a principal `id` from the config, and its audience must be `mailio-mcp`. [Client setup](client-setup.md) explains accounts, principals and roles.

## Run over HTTP

With Compose, from `apps/mailio_mcp/docker`:

```bash
export WORK_MAIL_PASSWORD=... MAILIO_MCP_JWT_SECRET=... MAILIO_MCP_STATE_KEY=...
docker compose up -d --build
```

Or with `docker run`:

```bash
docker run -d --name mailio-mcp -p 127.0.0.1:8420:8420 \
  -e WORK_MAIL_PASSWORD -e MAILIO_MCP_JWT_SECRET -e MAILIO_MCP_STATE_KEY \
  -v "$PWD/mail.config:/config/mail.config:ro" -v mailio-data:/data \
  mailio-mcp http
```

The endpoint is `http://127.0.0.1:8420/mcp`. The port is published on the host loopback only, because the container speaks plain HTTP: the config says `tls_terminated_upstream`, which means you put a TLS proxy in front before anything else can reach it. A request without a token gets 401.

## Run over stdio

Over stdio the client starts the container and talks to it through its standard input and output:

```json
{
  "mcpServers": {
    "mail": {
      "command": "docker",
      "args": ["run", "-i", "--rm",
               "-e", "WORK_MAIL_PASSWORD",
               "-v", "/path/to/mail.config:/config/mail.config:ro",
               "-v", "mailio-data:/data",
               "mailio-mcp", "stdio"],
      "env": { "WORK_MAIL_PASSWORD": "..." }
    }
  }
}
```

Leave the `http` entry out of the config for stdio. The server writes only protocol messages to standard output; its logs go to standard error.

## Check that it works

```bash
apps/mailio_mcp/docker/smoke.sh mailio-mcp
```

The script starts the image with the example config, checks that a request without a token is refused, signs a token, and lists the tools and the account. CI runs it on every change.

## Notes

- A missing or unreadable config file stops the container at start with the file name in the message. Check `docker logs`.
- Mount `/data` as a volume, or drafts and checkpoints are lost when the container is removed. Send records live there too, and they are what stops a message from being sent twice.
- `latest` follows `main`. Each build is also tagged with the short commit, such as `sha-97016d0`, so you can pin one.
