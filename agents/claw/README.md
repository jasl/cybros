# Claw

`claw` is the bundled Cybros agent runtime. It is a standalone Rails app that
serves the `agent_rpc` endpoint consumed by the main `cybros` application.

## Local development

From the monorepo root:

```bash
cd cybros
bin/dev
```

That starts the main app plus a dedicated `claw` process from
`../agents/claw`. `cybros` connects to it through the bundled bootstrap
environment:

- `CYBROS_BOOTSTRAP_BUNDLED_CLAW_ENDPOINT_URL`
- `CYBROS_BOOTSTRAP_BUNDLED_CLAW_BEARER`
- `CYBROS_BOOTSTRAP_BUNDLED_CLAW_FINGERPRINT`

`claw` itself validates:

- `CLAW_REQUIRED_BEARER`
- `CLAW_DEPLOYMENT_FINGERPRINT`
- `CLAW_WORKSPACE_ROOT`

To run `claw` by itself:

```bash
cd agents/claw
PORT=4242 CLAW_REQUIRED_BEARER=secret://bundled-claw:dev \
CLAW_DEPLOYMENT_FINGERPRINT=deployment:bundled-claw:dev \
CLAW_WORKSPACE_ROOT=/absolute/path/to/agent-workspace/bundled/claw \
bin/rails server -b 127.0.0.1
```

## Tests

Run the bundled contract/unit/request suite:

```bash
cd agents/claw
bin/test
```

## Container usage

The production `Dockerfile` exposes the service on port `80`. The main app's
Compose sample points `CYBROS_BOOTSTRAP_BUNDLED_CLAW_ENDPOINT_URL` at
`http://claw/rpc` and gives `claw` a shared workspace volume for its seeded
prompt and skill files.
