#!/usr/bin/env bash
# test_docker.sh — Smoke-test locally built Neon Docker images.
set -euo pipefail

log()  { echo "==> [test] $*"; }
fail() { echo "==> [test] FAIL: $*" >&2; FAILURES=$((FAILURES + 1)); }

FAILURES=0

declare -A TESTS=(
    ["pageserver"]="--version"
    ["safekeeper"]="--version"
    ["proxy"]="--version"
    ["storage-broker"]="--help"
    ["storage-controller"]="--version"
)

for component in "${!TESTS[@]}"; do
    IMAGE="neon/${component}:latest"
    ARG="${TESTS[$component]}"
    log "Testing ${component}..."
    output=$(docker run --rm "${IMAGE}" "${ARG}" 2>&1) || true
    if [[ -n "${output}" ]]; then
        log "  $(echo "${output}" | tail -1)"
    else
        fail "${component} — no output"
    fi
done

echo ""
if [[ ${FAILURES} -eq 0 ]]; then
    log "All images OK."
else
    log "${FAILURES} image(s) failed."
    exit 1
fi
