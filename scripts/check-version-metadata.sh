#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSIONS_FILE="${ROOT_DIR}/versions.env"
POM_FILE="${ROOT_DIR}/services/java-helidon/pom.xml"
JAVA_SRC_DIR="${ROOT_DIR}/services/java-helidon/src/main/java"

EXPECTED_HELIDON_VERSION="4.4.1"
EXPECTED_HELIDON_REGEX="${EXPECTED_HELIDON_VERSION//./[.]}"

[[ -f "${VERSIONS_FILE}" ]] || fail "Missing versions.env"
[[ -f "${POM_FILE}" ]] || fail "Missing services/java-helidon/pom.xml"
[[ -d "${JAVA_SRC_DIR}" ]] || fail "Missing Java source directory: services/java-helidon/src/main/java"

version_line_count="$(
  grep -Ec '^[[:space:]]*(export[[:space:]]+)?HELIDON_VERSION[[:space:]]*=' "${VERSIONS_FILE}" || true
)"
[[ "${version_line_count}" == "1" ]] || fail "versions.env must contain exactly one HELIDON_VERSION assignment"

if ! grep -Eq "^[[:space:]]*(export[[:space:]]+)?HELIDON_VERSION[[:space:]]*=[[:space:]]*['\"]?${EXPECTED_HELIDON_REGEX}['\"]?([[:space:]]*(#.*)?)?$" "${VERSIONS_FILE}"; then
  fail "versions.env must pin HELIDON_VERSION=${EXPECTED_HELIDON_VERSION}"
fi

pom_helidon_property_count="$(
  grep -Ec '<helidon[.]version>[[:space:]]*[^<]+[[:space:]]*</helidon[.]version>' "${POM_FILE}" || true
)"
[[ "${pom_helidon_property_count}" == "1" ]] || fail "pom.xml must contain exactly one helidon.version property"

if ! grep -Eq "<helidon[.]version>[[:space:]]*${EXPECTED_HELIDON_REGEX}[[:space:]]*</helidon[.]version>" "${POM_FILE}"; then
  fail "pom.xml must pin helidon.version to ${EXPECTED_HELIDON_VERSION}"
fi

if ! find "${JAVA_SRC_DIR}" -type f -name '*.java' -print -quit | grep -q .; then
  fail "No Java source files found under services/java-helidon/src/main/java"
fi

if ! grep -R --include='*.java' -Eq 'io[.]helidon[.]webserver' "${JAVA_SRC_DIR}"; then
  fail "Java source must reference io.helidon.webserver"
fi

pkg_a="com"
pkg_b="sun"
pkg_c="net"
pkg_d="httpserver"
forbidden_package="${pkg_a}.${pkg_b}.${pkg_c}.${pkg_d}"
forbidden_regex="${pkg_a}[.]${pkg_b}[.]${pkg_c}[.]${pkg_d}"

if grep -R --include='*.java' -En "${forbidden_regex}" "${JAVA_SRC_DIR}" >&2; then
  fail "Java source must not reference forbidden JDK HTTP package: ${forbidden_package}"
fi

printf 'Version metadata validation passed.\n'
