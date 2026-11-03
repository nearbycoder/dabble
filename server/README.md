# Dabble sync server (optional)

A tiny relay that lets Dabble devices sync when they aren't on the same network. Dabble works fine without it, since nearby devices sync directly. Add one if your devices are usually apart.

It's end-to-end encrypted. Devices derive everything from their sync group key, and the server stores only ciphertext. It never sees the content of your to-dos or the group key itself. See [SECURITY.md](../SECURITY.md#the-optional-sync-server) for exactly what it can and can't see.

## Run it

Node 22.13 or newer, with no dependencies:

```sh
node server.mjs
```

Or with Docker:

```sh
docker compose up -d
```

| Variable | Default | |
|---|---|---|
| `PORT` | `8787` | Port to listen on |
| `HOST` | `0.0.0.0` | Address to bind |
| `DATA_DIR` | `./data` | Where the SQLite database lives |
| `REGISTRATION` | `open` | `closed` refuses new sync groups. Set it once your devices have connected. |

Put it behind HTTPS, for example with Caddy (`reverse_proxy localhost:8787`), a Cloudflare Tunnel, `tailscale serve`, or a platform like Fly.io. The apps refuse plain `http://` except for addresses on your local network.

Then on each device: **Settings → Sync → Sync Server**, enter the address and choose **Use Server**. A device that isn't paired with the others yet can join with **Join with Sync Key**, using the key copied from a device that's already set up.

## API

All group endpoints take `Authorization: Bearer <token>`. The token is 64 hex characters derived from the group key. A group is registered with the first token that uses it.

- `GET /v1/health` returns `{ ok, service: "dabble-sync", version, registration }`.
- `POST /v1/groups/:group/push` with body `{ rows: [{ k, h, d }] }`, where `k` is a 32-hex opaque field key, `h` is a sortable HLC and `d` is base64 ciphertext. It keeps only the newest `h` per `k` and returns `{ accepted, cursor }`.
- `GET /v1/groups/:group/pull?since=<cursor>&limit=<n>&wait=<seconds>` returns `{ rows: [d], cursor, more }`. With `wait`, it holds the request open (up to 30 s) until another device pushes.

## Test

```sh
npm test
```
