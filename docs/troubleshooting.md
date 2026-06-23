# Troubleshooting

## Port Already in Use

Default ports are:

- Go service: `18081`
- Java service: `18082`
- Fast echo control service: `18083`

Set alternate ports before running scripts from later parts:

    export GO_PORT=19081
    export JAVA_PORT=19082
    export FAST_ECHO_PORT=19083

## Maven or Go Cache Is Not Writable

Use explicit writable caches:

    export GOCACHE=/tmp/more-go-java-go-build-cache
    export GOMODCACHE=/tmp/more-go-java-go-mod-cache
    export MAVEN_OPTS="-Dmaven.repo.local=/tmp/more-go-java-go-m2"

## Contract Validation Fails

Check the relevant fixture in `fixtures/valid/` or `fixtures/errors/`, then verify:

- `GET /health` returns exactly `{"status":"ok"}`
- `HEAD /health` returns no body
- `POST /work` requires `application/json`
- The decoded body limit is `4096` bytes
- The body limit is enforced before decode by reading at most `4097` bytes
- Duplicate fields are rejected
- Unknown fields are rejected
- Missing required fields are rejected
- Quoted numeric strings are rejected
- Wrong scalar types are rejected
- Numeric bound violations are rejected
- Invalid JSON and multiple JSON documents are rejected

Run the fixture validator after changes:

    ./scripts/validate-fixtures.sh

## Java Service Uses the Wrong HTTP Server

The Java service must be Helidon SE WebServer source. It must not use the JDK built-in HTTP server package.

Run the metadata check after Java source is materialized:

    ./scripts/check-version-metadata.sh

If the check fails, remove the forbidden JDK HTTP server imports and implementation code, then use Helidon WebServer routing instead.

## Helidon Version Check Fails

The Java service is pinned to Helidon `4.4.1` unless a newer version is explicitly verified during the task that changes it.

Check both locations:

- `versions.env`
- `services/java-helidon/pom.xml`

The values must match.

## Generated Artifacts Appear in Git Status

Generated artifacts should stay under ignored artifact directories. Do not commit:

- Old benchmark result JSON, CSV, or JSONL files
- Java GC logs
- Java JFR recordings
- Go CPU profiles
- Go heap profiles
- Go runtime metric snapshots
- Extracted JDK runtime payloads
- Maven `target/` directories
- Binary caches

Move accidental outputs under the appropriate ignored artifact directory or delete them before packaging source.
