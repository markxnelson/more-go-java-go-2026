#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "${ROOT}/manifests"

python3 - "${ROOT}" <<'PY'
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

root = Path(sys.argv[1]).resolve()
output_path = root / "manifests" / "java-runtimes.json"

env_home_vars = [
    "JAVA_HOME",
    "ORACLE_JDK_HOME",
    "OPENJDK_HOME",
]

local_homes = []

for env_name in ["JAVA_CANDIDATE_HOMES", "JAVA_RUNTIME_HOMES"]:
    for raw_value in os.environ.get(env_name, "").split(os.pathsep):
        value = raw_value.strip()
        if value:
            local_homes.append(value)


def slug(value):
    value = value.lower()
    value = re.sub(r"[^a-z0-9]+", "-", value)
    value = value.strip("-")
    return value or "java"


def unique_id(base, used):
    candidate = base
    index = 2
    while candidate in used:
        candidate = f"{base}-{index}"
        index += 1
    used.add(candidate)
    return candidate


def is_relative_to(child, parent):
    try:
        child.resolve().relative_to(parent.resolve())
        return True
    except Exception:
        return False


def candidate_binary_from_home_or_binary(value):
    if not value:
        return None, None

    path = Path(value).expanduser()

    if not path.is_absolute() and len(path.parts) == 1:
        resolved = shutil.which(str(path))
        if resolved:
            path = Path(resolved)

    if path.name == "java" or path.is_file():
        java_binary = path
        java_home = path.parent.parent if path.parent.name == "bin" else path.parent
        return java_binary, java_home

    java_binary = path / "bin" / "java"
    return java_binary, path


def first_matching_line(text, needles):
    for line in text.splitlines():
        lower = line.lower()
        if any(needle in lower for needle in needles):
            return line.strip()
    return None


def parse_property(text, property_name):
    pattern = re.compile(rf"^\s*{re.escape(property_name)}\s*=\s*(.*?)\s*$")
    for line in text.splitlines():
        match = pattern.match(line)
        if match:
            return match.group(1)
    return None


def unique_non_empty(values):
    seen = set()
    result = []
    for value in values:
        if value is None:
            continue
        text = str(value).strip()
        if not text or text in seen:
            continue
        seen.add(text)
        result.append(text)
    return result


def vendor_runtime_text(details_output, version_line, vendor_line, java_vendor):
    values = [
        version_line,
        vendor_line,
        java_vendor,
    ]

    for property_name in [
        "java.vendor",
        "java.vendor.version",
        "java.runtime.name",
        "java.runtime.version",
        "java.vm.name",
        "java.vm.vendor",
        "java.vm.version",
    ]:
        property_value = parse_property(details_output, property_name)
        if property_value:
            values.append(f"{property_name} = {property_value}")

    for line in details_output.splitlines():
        stripped = line.strip()
        lower = stripped.lower()
        if any(
            marker in lower
            for marker in [
                "runtime environment",
                "server vm",
                "client vm",
                "graalvm",
                "hotspot",
                "openjdk",
                "java(tm)",
            ]
        ):
            values.append(stripped)

    return "\n".join(unique_non_empty(values))


def path_source_text(raw, java_binary, java_home, discovered_java_home):
    return "\n".join(
        str(value)
        for value in [
            raw.get("source"),
            java_binary,
            java_home,
            discovered_java_home,
        ]
        if value
    )


def classify_oracle_like(identity_text):
    lower = identity_text.lower()

    if "oracle corporation" in lower:
        return True

    if "java(tm)" in lower:
        return True

    if "oracle graalvm" in lower:
        return True

    if "hotspot(tm)" in lower and (
        "oracle corporation" in lower
        or "java(tm)" in lower
        or "oracle graalvm" in lower
    ):
        return True

    return False


def classify_openjdk_like(available, is_oracle_like, version_line, identity_text, source_text):
    if not available or is_oracle_like:
        return False

    identity_lower = identity_text.lower()
    source_lower = source_text.lower()

    if version_line and version_line.strip().lower().startswith("openjdk"):
        return True

    if any(
        marker in identity_lower
        for marker in [
            "openjdk",
            "temurin",
            "eclipse adoptium",
            "adoptium",
        ]
    ):
        return True

    if "temurin" in source_lower or "openjdk" in source_lower:
        return True

    return False


def run_java_details(java_binary):
    try:
        completed = subprocess.run(
            [str(java_binary), "-XshowSettings:properties", "-version"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=20,
            check=False,
        )
        return completed.returncode, completed.stdout or ""
    except Exception as exc:
        return 127, str(exc)


def probe_aot_record(java_binary):
    temp_name = None
    try:
        fd, temp_name = tempfile.mkstemp(prefix="java-aot-probe-", suffix=".cache")
        os.close(fd)
        try:
            os.unlink(temp_name)
        except FileNotFoundError:
            pass

        completed = subprocess.run(
            [
                str(java_binary),
                "-XX:AOTMode=record",
                f"-XX:AOTCacheOutput={temp_name}",
                "-version",
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=30,
            check=False,
        )
        return completed.returncode == 0, completed.returncode, completed.stdout or ""
    except subprocess.TimeoutExpired as exc:
        output = ""
        if exc.stdout:
            output += exc.stdout if isinstance(exc.stdout, str) else exc.stdout.decode(errors="replace")
        if exc.stderr:
            output += exc.stderr if isinstance(exc.stderr, str) else exc.stderr.decode(errors="replace")
        return False, 124, output or "AOT record probe timed out"
    except Exception as exc:
        return False, 127, str(exc)
    finally:
        if temp_name:
            try:
                os.unlink(temp_name)
            except FileNotFoundError:
                pass
            except IsADirectoryError:
                shutil.rmtree(temp_name, ignore_errors=True)


raw_candidates = []

java_binary_env = os.environ.get("JAVA_BINARY")
if java_binary_env:
    java_binary, java_home = candidate_binary_from_home_or_binary(java_binary_env)
    raw_candidates.append(
        {
            "baseId": "env-java-binary",
            "source": "env:JAVA_BINARY",
            "javaBinary": java_binary,
            "javaHome": java_home,
        }
    )

for env_var in env_home_vars:
    value = os.environ.get(env_var)
    if value:
        java_binary, java_home = candidate_binary_from_home_or_binary(value)
        raw_candidates.append(
            {
                "baseId": f"env-{slug(env_var)}",
                "source": f"env:{env_var}",
                "javaBinary": java_binary,
                "javaHome": java_home,
            }
        )

for home in local_homes:
    java_binary, java_home = candidate_binary_from_home_or_binary(home)
    raw_candidates.append(
        {
            "baseId": f"local-{slug(Path(home).name)}",
            "source": f"local:{home}",
            "javaBinary": java_binary,
            "javaHome": java_home,
        }
    )

cache_runtimes = root / ".cache" / "runtimes"
if cache_runtimes.exists():
    for java_binary in sorted(cache_runtimes.glob("**/bin/java")):
        if java_binary.is_file() and os.access(java_binary, os.X_OK):
            java_home = java_binary.parent.parent
            raw_candidates.append(
                {
                    "baseId": f"cache-{slug(java_home.name)}",
                    "source": f"cache:{java_home}",
                    "javaBinary": java_binary,
                    "javaHome": java_home,
                }
            )

path_java = shutil.which("java")
if path_java:
    java_binary = Path(path_java)
    java_home = java_binary.parent.parent if java_binary.parent.name == "bin" else java_binary.parent
    raw_candidates.append(
        {
            "baseId": "path-java",
            "source": "PATH:java",
            "javaBinary": java_binary,
            "javaHome": java_home,
        }
    )
else:
    raw_candidates.append(
        {
            "baseId": "path-java",
            "source": "PATH:java",
            "javaBinary": Path("java"),
            "javaHome": None,
        }
    )

used_ids = set()
runtimes = []

for raw in raw_candidates:
    runtime_id = unique_id(raw["baseId"], used_ids)
    java_binary = raw["javaBinary"]
    java_home = raw["javaHome"]

    available = bool(java_binary and java_binary.exists() and os.access(java_binary, os.X_OK))

    version_line = None
    vendor_line = None
    java_vendor = None
    java_version = None
    discovered_java_home = None
    details_output = ""

    if available:
        _, details_output = run_java_details(java_binary)
        for line in details_output.splitlines():
            stripped = line.strip()
            if stripped and (
                stripped.startswith("java version")
                or stripped.startswith("openjdk version")
                or stripped.startswith("java full version")
            ):
                version_line = stripped
                break

        java_vendor = parse_property(details_output, "java.vendor")
        java_version = parse_property(details_output, "java.version")
        discovered_java_home = parse_property(details_output, "java.home")
        vendor_line = first_matching_line(details_output, ["java.vendor =", "java.vendor.version =", "runtime environment"])

    identity_text = vendor_runtime_text(details_output, version_line, vendor_line, java_vendor)
    source_text = path_source_text(raw, java_binary, java_home, discovered_java_home)

    is_oracle_like = classify_oracle_like(identity_text)
    is_openjdk_like = classify_openjdk_like(available, is_oracle_like, version_line, identity_text, source_text)

    cache_runtime = bool(java_binary and is_relative_to(java_binary, cache_runtimes))

    if available:
        supports_aot, aot_status, aot_output = probe_aot_record(java_binary)
    else:
        supports_aot, aot_status, aot_output = False, None, ""

    runtimes.append(
        {
            "id": runtime_id,
            "source": raw["source"],
            "javaBinary": str(java_binary) if java_binary else None,
            "available": available,
            "versionLine": version_line,
            "vendorLine": vendor_line,
            "javaVendor": java_vendor,
            "javaVersion": java_version,
            "javaHome": discovered_java_home or (str(java_home) if java_home else None),
            "isOracleLike": is_oracle_like,
            "isOpenJdkLike": is_openjdk_like,
            "isCacheRuntime": cache_runtime,
            "supportsAotRecordProbe": supports_aot,
            "aotRecordProbeStatus": aot_status,
            "aotRecordProbeOutput": aot_output,
        }
    )


def runtime_text(runtime):
    return "\n".join(
        str(runtime.get(name) or "")
        for name in [
            "id",
            "source",
            "javaBinary",
            "javaHome",
            "versionLine",
            "vendorLine",
            "javaVendor",
            "javaVersion",
        ]
    ).lower()


def is_java_26_0_1(runtime):
    text = runtime_text(runtime)
    return (
        (runtime.get("javaVersion") or "") == "26.0.1"
        or "26.0.1" in text
        or "jdk-26.0.1" in text
        or "temurin-26-0-1" in text
        or "openjdk-26-0-1" in text
    )


def is_java_26(runtime):
    version = runtime.get("javaVersion") or ""
    text = runtime_text(runtime)
    return (
        version == "26"
        or version.startswith("26.")
        or version.startswith("26-")
        or "jdk-26" in text
        or "java-26" in text
        or "openjdk-26" in text
        or "temurin-26" in text
    )


def is_temurin_like(runtime):
    text = runtime_text(runtime)
    return "temurin" in text or "adoptium" in text or "eclipse" in text


def select_runtime(predicate, key):
    candidates = [runtime for runtime in runtimes if predicate(runtime)]
    if not candidates:
        return None
    return sorted(candidates, key=key)[0]["id"]


oracle_jvm = select_runtime(
    lambda runtime: runtime["available"] and runtime["isOracleLike"],
    lambda runtime: (
        0 if is_java_26_0_1(runtime) else 1,
        0 if is_java_26(runtime) else 1,
        runtime["id"],
    ),
)

oracle_aot = select_runtime(
    lambda runtime: runtime["available"] and runtime["isOracleLike"] and runtime["supportsAotRecordProbe"],
    lambda runtime: (
        0 if is_java_26_0_1(runtime) else 1,
        0 if is_java_26(runtime) else 1,
        runtime["id"],
    ),
)

openjdk_jvm = select_runtime(
    lambda runtime: runtime["available"]
    and runtime["isCacheRuntime"]
    and not runtime["isOracleLike"]
    and runtime["isOpenJdkLike"],
    lambda runtime: (
        0 if is_java_26_0_1(runtime) else 1,
        0 if is_java_26(runtime) else 1,
        0 if is_temurin_like(runtime) else 1,
        runtime["id"],
    ),
)

openjdk_aot = select_runtime(
    lambda runtime: runtime["available"]
    and runtime["isCacheRuntime"]
    and not runtime["isOracleLike"]
    and runtime["isOpenJdkLike"]
    and runtime["supportsAotRecordProbe"],
    lambda runtime: (
        0 if is_java_26_0_1(runtime) else 1,
        0 if is_java_26(runtime) else 1,
        0 if is_temurin_like(runtime) else 1,
        runtime["id"],
    ),
)

recommended = {
    "oracleJvm": oracle_jvm,
    "oracleAot": oracle_aot,
    "openJdkJvm": openjdk_jvm,
    "openJdkAot": openjdk_aot,
}

manifest = {
    "javaRuntimes": runtimes,
    "recommended": recommended,
}

output_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

PY
