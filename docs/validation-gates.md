# Validation Gates

Use these gates before treating a run as usable.

## Source Gate

- Required files are present.
- No generated benchmark results are committed.
- No extracted JDK payloads are committed.
- No build output or cache directories are committed.
- Helidon version remains pinned to `4.4.1` unless a newer version was verified during the relevant task.

## Contract Gate

Validate both services against:

- `contracts/work-contract.json`
- `fixtures/valid/`
- `fixtures/errors/`

Required checks include:

- `GET /health`
- `HEAD /health`
- `POST /work`
- Body limit enforcement at `4096` decoded bytes using at most `4097` bytes read before decode
- Rejection of duplicate fields
- Rejection of unknown fields
- Rejection of wrong scalar types
- Rejection of quoted numeric strings
- Rejection of invalid JSON and multiple JSON documents

## Equivalence Gate

The Go and Java services should produce equivalent success and error behavior for the shared fixtures.

## Profiling Gate

For selected profiled runs:

- Profile files must exist before being referenced.
- Manifest entries must point to the actual files.
- Missing profiles must be reported as missing, not invented.
- No measurements should be fabricated.

## Publication Gate

Before publishing any performance discussion:

- Confirm the environment manifest.
- Confirm runtime versions.
- Confirm matrix cells.
- Confirm raw artifacts and summaries were produced by actual runs.
- Keep analysis separate from source material.
