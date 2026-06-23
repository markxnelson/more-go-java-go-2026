# Go HTTP benchmark service

This service is the Go `net/http` implementation used by the benchmark package.
It implements the shared service contract:

- `GET /health`
- `HEAD /health`
- `POST /work`

`GET /health` returns exactly:

```json
{"status":"ok"}
```

`POST /work` accepts a JSON object with these fields:

- `requestId` string, length 1 through 128
- `payloadSize` integer, 0 through 131072
- `seed` integer, 0 through 2147483647
- `extraWork` integer, 0 through 100

The request validator rejects:

- decoded bodies larger than 4096 bytes
- duplicate top-level fields
- unknown fields
- quoted numeric strings
- wrong scalar types
- out-of-bounds values
- missing fields
- invalid JSON
- unsupported or missing `Content-Type`

The decoded body limit is enforced by reading at most 4097 bytes before JSON
decoding.

## Prerequisites

- Go compatible with the `go.mod` directive

No third-party Go modules are required.

## Run locally

From this directory:

```bash
go test ./...
go run ./cmd/go-http
```

By default the service listens on `127.0.0.1:18081`.

You can override the host and port:

```bash
GO_HOST=0.0.0.0 GO_PORT=18081 go run ./cmd/go-http
```

## Smoke test

```bash
curl -i http://127.0.0.1:18081/health

curl -i \
  -H 'Content-Type: application/json' \
  -d '{"requestId":"demo-1","payloadSize":128,"seed":42,"extraWork":1}' \
  http://127.0.0.1:18081/work
```

Expected health response body:

```json
{"status":"ok"}
```

Expected work response shape:

```json
{
  "requestId": "demo-1",
  "payloadSize": 128,
  "extraWork": 1,
  "checksum": "stable-hex-value",
  "ok": true
}
```

The checksum value is deterministic for the same request fields.

## Profiling note

This service does not fabricate measurements. Benchmark and profiling scripts in
the package are responsible for starting selected profiled runs and collecting
Go CPU profiles, Go heap profiles, and Go runtime metric snapshots tied to run
manifests.
