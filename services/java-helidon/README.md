# Java Helidon service

This service implements the benchmark HTTP contract using real Helidon SE WebServer APIs.

## Contract

- `GET /health`
  - Returns exactly `{"status":"ok"}`
- `HEAD /health`
  - Returns status `200` with no response body
- `POST /work`
  - Requires `Content-Type: application/json`
  - Accepts JSON object fields:
    - `requestId`: non-empty string, maximum 128 characters
    - `payloadSize`: integer from 0 through 131072
    - `seed`: integer from 0 through 2147483647
    - `extraWork`: integer from 0 through 100
  - Rejects duplicate fields, unknown fields, quoted numeric strings, wrong scalar types, invalid bounds, invalid JSON, invalid content type, and oversized decoded request bodies
  - The decoded request body limit is 4096 bytes. The handler reads at most 4097 bytes before JSON decoding so oversized bodies are detected without buffering arbitrary input.

## Build

Prerequisites:

- JDK 21
- Maven 3.9 or newer

From this service directory:

    mvn package

## Run

Default port is `18082` on `127.0.0.1`.

    JAVA_PORT=18082 java -jar target/java-helidon-1.0.0.jar

Health check:

    curl -i http://127.0.0.1:18082/health

Example work request:

    curl -i \
      -H 'Content-Type: application/json' \
      -d '{"requestId":"demo-1","payloadSize":1024,"seed":42,"extraWork":3}' \
      http://127.0.0.1:18082/work

## Profiling notes

The benchmark runner is expected to start this JVM with selected Java Flight Recorder and GC logging options when a profiled run is requested. This service does not fabricate or embed benchmark measurements; profiling artifacts should be produced by the run harness and tied to the corresponding manifest.
