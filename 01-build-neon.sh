#!/usr/bin/env bash
# 01-build-neon.sh — Build Neon Rust binaries from existing checkout.
set -euo pipefail

log()  { echo "==> [build-neon] $*"; }
die()  { echo "==> [build-neon] FATAL: $*" >&2; exit 1; }

# Ensure Rust toolchain is available
if ! command -v cargo &>/dev/null; then
    if [[ -f "$HOME/.cargo/env" ]]; then
        # shellcheck source=/dev/null
        source "$HOME/.cargo/env"
    else
        die "Rust/Cargo not found. Run 00-prerequisites.sh first."
    fi
fi

# Prevent rustc stack overflows in deep macro expansion (prost-types, serde)
export RUST_MIN_STACK=268435456
export CARGO_INCREMENTAL=0

# Use mold linker if available — much lower memory usage than GNU ld,
# avoids linker OOM/segfault on machines with ≤16GB RAM.
if command -v mold &>/dev/null; then
    log "Using mold linker"
    export RUSTFLAGS="-Cforce-frame-pointers=yes -Clink-arg=-fuse-ld=mold"
else
    log "Warning: mold not found — large binaries may fail to link on low-memory machines."
    log "  Install with: sudo dnf install -y mold"
fi

# ── Neon source directory ────────────────────────────────────────────────────
NEON_DIR="/home/srinivas/SourceCode/neon"

if [[ ! -d "${NEON_DIR}/.git" ]]; then
    die "Neon checkout not found at ${NEON_DIR}. Clone it first:
    git clone https://github.com/neondatabase/neon.git ${NEON_DIR}
    cd ${NEON_DIR} && git submodule update --init --recursive"
fi

log "Using existing Neon checkout at ${NEON_DIR}"

# ── Build PostgreSQL v17 (needed by postgres_ffi + walproposer) ──────────────
cd "${NEON_DIR}"

# Build postgres v17 via neon's Makefile if not already installed.
# Uses postgres-headers-install + full compile + install into pg_install/v17/.
if [[ ! -f "${NEON_DIR}/pg_install/v17/bin/pg_config" ]]; then
    log "Building PostgreSQL v17 from vendor/postgres-v17..."
    # Clean stale vendor artifacts that confuse VPATH (from standalone builds)
    rm -f vendor/postgres-v17/src/backend/nodes/node-support-stamp \
          vendor/postgres-v17/src/include/nodes/header-stamp 2>/dev/null || true
    make postgres-v17 -j1
else
    log "PostgreSQL v17 already installed at pg_install/v17/"
fi

# postgres_ffi needs all of v14-v17. We only build v17 — symlink the rest.
for pgver in v14 v15 v16; do
    link="${NEON_DIR}/pg_install/${pgver}"
    if [[ ! -e "${link}" ]]; then
        ln -sfn "${NEON_DIR}/pg_install/v17" "${link}"
        log "Symlinked pg_install/${pgver} → pg_install/v17"
    fi
done

# ── Build walproposer C library (bypass neon-pg-ext-v17 dependency) ──────────
# The 'make walproposer-lib' target depends on neon-pg-ext-v17 which pulls in
# cargo/jemalloc builds that crash on low-memory machines. Build the C library
# directly instead.
WALPROP_DIR="${NEON_DIR}/build/walproposer-lib"
if [[ ! -f "${WALPROP_DIR}/libwalproposer.a" ]]; then
    log "Building walproposer static library..."
    mkdir -p "${WALPROP_DIR}"
    make PG_CONFIG="${NEON_DIR}/pg_install/v17/bin/pg_config" \
        -C "${WALPROP_DIR}" \
        -f "${NEON_DIR}/pgxn/neon/Makefile" walproposer-lib

    # Copy postgres static libs and strip OpenSSL-dependent objects
    cp "${NEON_DIR}/pg_install/v17/lib/libpgport.a" "${WALPROP_DIR}/"
    cp "${NEON_DIR}/pg_install/v17/lib/libpgcommon.a" "${WALPROP_DIR}/"
    ar d "${WALPROP_DIR}/libpgport.a" pg_strong_random.o
    ar d "${WALPROP_DIR}/libpgport.a" pg_crc32c.o 2>/dev/null || true
    ar d "${WALPROP_DIR}/libpgcommon.a" \
        checksum_helper.o cryptohash_openssl.o hmac_openssl.o \
        md5_common.o parse_manifest.o scram-common.o
    log "walproposer-lib ready"
else
    log "walproposer-lib already built"
fi

# ── Build neon-pg-ext-v17 (postgres extensions for compute nodes) ─────────────
if [[ ! -f "${NEON_DIR}/pg_install/v17/lib/neon.so" ]]; then
    log "Building neon-pg-ext-v17..."
    make neon-pg-ext-v17 -j1
else
    log "neon-pg-ext-v17 already built"
fi

# ── Build ─────────────────────────────────────────────────────────────────────
# Build each package individually to minimise memory pressure and avoid
# corrupted LTO bitcode from a prior interrupted build.
PACKAGES=(pageserver safekeeper proxy storage_broker storage_controller)
for pkg in "${PACKAGES[@]}"; do
    log "Building ${pkg} (cargo build --release -j1 -p ${pkg})..."
    cargo build --release -j1 -p "${pkg}"
    log "${pkg} built."
done

# ── Verify ────────────────────────────────────────────────────────────────────
BINARIES=(pageserver safekeeper proxy storage_broker storage_controller)
log ""
log "Build complete. Checking binaries:"
ALL_OK=true
for bin in "${BINARIES[@]}"; do
    BIN_PATH="${NEON_DIR}/target/release/${bin}"
    if [[ -x "${BIN_PATH}" ]]; then
        SIZE=$(du -h "${BIN_PATH}" | cut -f1)
        log "  ✓ ${bin} (${SIZE})"
    else
        log "  ✗ ${bin} — NOT FOUND"
        ALL_OK=false
    fi
done

if [[ "${ALL_OK}" != "true" ]]; then
    die "Some binaries are missing. Check the build output above."
fi

log ""
log "All binaries built successfully in ${NEON_DIR}/target/release/"
log "Done."
