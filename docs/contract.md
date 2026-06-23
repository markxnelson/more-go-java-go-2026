# HTTP Contract

The Go and Java services must implement the same externally visible contract.

## Health

### `GET /health`

Returns status `200`, content type `application/json`, and exactly this response body:

```json
{"status":"ok"}
```

No extra spaces, fields, or trailing newline are part of the required body.

### `HEAD /health`

Returns status `200` with no response body.

## Work

### `POST /work`

The request content type must be `application/json`.

The decoded request body limit is `4096` bytes. Implementations must enforce this by reading at most `4097` bytes before decode and rejecting a body whose decoded byte length is greater than `4096`.

The request body must be one JSON object with exactly these fields:

- `requestId`
  - Type: string
  - Bounds: length `1..128`
- `payloadSize`
  - Type: integer
  - Bounds: `0..131072`
- `seed`
  - Type: integer
  - Bounds: `0..2147483647`
- `extraWork`
  - Type: integer
  - Bounds: `0..100`


The success response is JSON and includes at least:

- `requestId`
- `payloadSize`
- `extraWork`
- `checksum`
- `ok`

The `ok` field must be `true`.

## Required Rejections

Both services must reject:

- Missing or invalid content type
- Decoded request bodies larger than `4096` bytes
- Invalid JSON
- Multiple JSON documents in one body
- JSON values that are not objects
- Duplicate object fields
- Unknown object fields
- Missing required fields
- Quoted numeric strings
- Wrong scalar types
- Numeric bound violations

Error responses use a stable JSON envelope:

```json
{"ok":false,"error":{"code":"stable_machine_code","message":"human_readable_message"}}
```

The exact HTTP status and machine code may vary by error category, but both services should be consistent for equivalence validation.
