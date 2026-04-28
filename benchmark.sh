#!/usr/bin/env bash
# benchmark.sh — sysbench OLTP benchmark against a Postgres URL.
# Run from a host close to the DB (low RTT; same AWS AZ/region preferably)
#
# Usage:
#   ./benchmark.sh --url <postgres-url> --size <SIZE> [options]
#
# Required:
#   --url URL           Postgres URL (e.g. postgresql://user:pass@host:5432/dbname)
#   --size SIZE         Target dataset size with K/M/G/T suffix (e.g. 1G, 500M, 10G)
#                       OR pass --table-size + --tables explicitly (skips size→rows math).
#
# Workload:
#   --mode MODE         oltp_read_write | oltp_read_only | oltp_write_only |
#                       oltp_point_select | oltp_update_index | oltp_update_non_index |
#                       oltp_insert | oltp_delete   (default: oltp_read_write)
#   --threads N         Concurrent client threads (default: 8)
#   --time SECONDS      Measurement window (default: 60)
#   --warmup SECONDS    Run workload this long before measurement starts; stats
#                       are reset at the boundary so cold-cache noise doesn't
#                       skew TPS/p99 (default: 60). Pass 0 or --no-warmup to skip.
#   --no-warmup         Disable warmup (equivalent to --warmup 0).
#   --tables N          Number of sbtest tables (default: 8)
#   --table-size N      Rows per table (overrides --size)
#   --report-interval S Per-second progress lines (default: 10)
#
# Phases (default runs all three):
#   --prepare-only      Only load data, don't run the workload
#   --run-only          Skip prepare, just run (assumes data already loaded)
#   --cleanup           Drop sbtest tables and exit
#   --keep              Don't drop sbtest tables after the run
#
# Examples:
#   ./benchmark.sh --url postgresql://postgres:pw@db.example:5432/postgres --size 1G
#   ./benchmark.sh --url "$URL" --size 5G --threads 32 --time 300 --mode oltp_read_only
#   ./benchmark.sh --url "$URL" --table-size 1000000 --tables 16 --time 600
set -euo pipefail

log()  { echo "==> [bench] $*"; }
warn() { echo "==> [bench] WARNING: $*" >&2; }
die()  { echo "==> [bench] FATAL: $*" >&2; exit 1; }

usage() { sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//' | head -n -1; exit "${1:-0}"; }

# ── Defaults ──────────────────────────────────────────────────────────────────
DB_URL=""
SIZE=""
TABLE_SIZE=""
TABLES=8
THREADS=8
DURATION=60
WARMUP=60
REPORT_INTERVAL=10
MODE="oltp_read_write"
PHASE_PREPARE=true
PHASE_RUN=true
PHASE_CLEANUP=true
CLEANUP_ONLY=false

# Approx bytes per sbtest row including indexes on PostgreSQL.
# Empirically ~240–256B/row; using 220 means actual size will slightly
# overshoot the requested size, which is the safer side for benchmarks.
BYTES_PER_ROW=220

# ── Parse args ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --url)             DB_URL="$2"; shift 2 ;;
        --size)            SIZE="$2"; shift 2 ;;
        --table-size)      TABLE_SIZE="$2"; shift 2 ;;
        --tables)          TABLES="$2"; shift 2 ;;
        --threads)         THREADS="$2"; shift 2 ;;
        --time)            DURATION="$2"; shift 2 ;;
        --warmup)          WARMUP="$2"; shift 2 ;;
        --no-warmup)       WARMUP=0; shift ;;
        --report-interval) REPORT_INTERVAL="$2"; shift 2 ;;
        --mode)            MODE="$2"; shift 2 ;;
        --prepare-only)    PHASE_RUN=false; PHASE_CLEANUP=false; shift ;;
        --run-only)        PHASE_PREPARE=false; PHASE_CLEANUP=false; shift ;;
        --cleanup)         CLEANUP_ONLY=true; shift ;;
        --keep)            PHASE_CLEANUP=false; shift ;;
        -h|--help)         usage 0 ;;
        *) die "Unknown arg: $1 (try --help)" ;;
    esac
done

[[ -n "${DB_URL}" ]] || { usage 1; }
command -v sysbench >/dev/null 2>&1 || die "sysbench not found. Install: sudo dnf install -y sysbench"

case "${MODE}" in
    oltp_read_write|oltp_read_only|oltp_write_only|oltp_point_select|\
    oltp_update_index|oltp_update_non_index|oltp_insert|oltp_delete) ;;
    *) die "Unsupported --mode: ${MODE}" ;;
esac

# ── Parse Postgres URL ────────────────────────────────────────────────────────
# Accepts: postgresql://[user[:pass]@]host[:port][/dbname][?...]   (also "postgres://")
parse_url() {
    local url="$1" rest userpass hostport
    [[ "${url}" =~ ^postgres(ql)?:// ]] || die "URL must start with postgres:// or postgresql://"
    rest="${url#*://}"
    rest="${rest%%\?*}"          # strip query string
    if [[ "${rest}" == */* ]]; then
        PG_DB="${rest#*/}"
        rest="${rest%%/*}"
        [[ -n "${PG_DB}" ]] || PG_DB="postgres"
    else
        PG_DB="postgres"
    fi
    if [[ "${rest}" == *@* ]]; then
        userpass="${rest%@*}"
        hostport="${rest##*@}"
        if [[ "${userpass}" == *:* ]]; then
            PG_USER="${userpass%%:*}"
            PG_PASSWORD="${userpass#*:}"
        else
            PG_USER="${userpass}"
            PG_PASSWORD=""
        fi
    else
        hostport="${rest}"
        PG_USER="${USER:-postgres}"
        PG_PASSWORD=""
    fi
    if [[ "${hostport}" == *:* ]]; then
        PG_HOST="${hostport%:*}"
        PG_PORT="${hostport##*:}"
    else
        PG_HOST="${hostport}"
        PG_PORT="5432"
    fi
    # URL-decode user/password (handles e.g. %40 → @)
    PG_USER=$(printf '%b' "${PG_USER//%/\\x}")
    PG_PASSWORD=$(printf '%b' "${PG_PASSWORD//%/\\x}")
    [[ -n "${PG_HOST}" ]] || die "Could not parse host from URL"
}

parse_url "${DB_URL}"

# ── Convert --size to --table-size (rows) ────────────────────────────────────
size_to_bytes() {
    local s="$1" num suf
    [[ "${s}" =~ ^([0-9]+)([KkMmGgTt]?)$ ]] || die "Bad --size: ${s} (use e.g. 500M, 2G)"
    num="${BASH_REMATCH[1]}"; suf="${BASH_REMATCH[2]}"
    case "${suf}" in
        ''|'B'|'b') echo "${num}" ;;
        K|k)        echo $(( num * 1024 )) ;;
        M|m)        echo $(( num * 1024 * 1024 )) ;;
        G|g)        echo $(( num * 1024 * 1024 * 1024 )) ;;
        T|t)        echo $(( num * 1024 * 1024 * 1024 * 1024 )) ;;
    esac
}

if [[ -z "${TABLE_SIZE}" ]]; then
    [[ -n "${SIZE}" ]] || die "Either --size or --table-size is required"
    BYTES=$(size_to_bytes "${SIZE}")
    TABLE_SIZE=$(( BYTES / TABLES / BYTES_PER_ROW ))
    [[ "${TABLE_SIZE}" -gt 0 ]] || die "Computed table size is 0 — request a larger --size"
    log "Target size ${SIZE} → ${TABLES} tables × ${TABLE_SIZE} rows (≈${BYTES_PER_ROW}B/row)"
fi

# ── Introspect target Postgres ───────────────────────────────────────────────
# Pulls version, key tuning GUCs, db size, and any neon extension. Caps threads
# at max_connections-5 so sysbench doesn't hit "too many connections", and warns
# if synchronous_commit is relaxed (write throughput numbers become misleading).
# Skipped gracefully if psql is missing or the DB can't be reached for inspection.
introspect_db() {
    if ! command -v psql >/dev/null 2>&1; then
        warn "psql not found — skipping DB introspection (install: sudo dnf install -y postgresql)"
        return 0
    fi
    local out
    if ! out=$(PGPASSWORD="${PG_PASSWORD}" psql \
        "host=${PG_HOST} port=${PG_PORT} user=${PG_USER} dbname=${PG_DB}" \
        -At -F'|' -v ON_ERROR_STOP=1 2>/dev/null <<'SQL'
SELECT 'version', split_part(version(), ' on ', 1);
SELECT 'database', current_database();
SELECT 'db_size', pg_size_pretty(pg_database_size(current_database()));
SELECT name, setting || COALESCE(' ' || NULLIF(unit, ''), '')
  FROM pg_settings
 WHERE name IN ('max_connections','shared_buffers','effective_cache_size',
                'work_mem','maintenance_work_mem','wal_level',
                'synchronous_commit','max_wal_size','checkpoint_timeout',
                'random_page_cost','effective_io_concurrency')
 ORDER BY name;
SELECT 'extensions',
       COALESCE(string_agg(extname || ' ' || extversion, ', ' ORDER BY extname), '(none)')
  FROM pg_extension WHERE extname <> 'plpgsql';
SQL
    ); then
        warn "Could not introspect ${PG_HOST}:${PG_PORT}/${PG_DB} — proceeding without DB context"
        return 0
    fi

    local pg_max_conn="" pg_sync_commit=""
    log "── Postgres introspection ──"
    while IFS='|' read -r key value; do
        [[ -z "${key}" ]] && continue
        printf "    %-22s %s\n" "${key}" "${value}"
        case "${key}" in
            max_connections)    pg_max_conn="${value%% *}" ;;
            synchronous_commit) pg_sync_commit="${value%% *}" ;;
        esac
    done <<< "${out}"

    if [[ -n "${pg_max_conn}" ]] && [[ "${pg_max_conn}" =~ ^[0-9]+$ ]]; then
        local cap=$(( pg_max_conn - 5 ))
        if [[ "${THREADS}" -gt "${cap}" ]]; then
            warn "--threads=${THREADS} exceeds max_connections-5 (=${cap}); capping to ${cap}"
            THREADS="${cap}"
        fi
    fi
    case "${pg_sync_commit}" in
        off|local|remote_write)
            warn "synchronous_commit=${pg_sync_commit} — write throughput numbers will be optimistic (durability is relaxed)"
            ;;
    esac
}

# ── Build common sysbench args ───────────────────────────────────────────────
SB_COMMON=(
    --db-driver=pgsql
    --pgsql-host="${PG_HOST}"
    --pgsql-port="${PG_PORT}"
    --pgsql-user="${PG_USER}"
    --pgsql-db="${PG_DB}"
    --tables="${TABLES}"
    --table-size="${TABLE_SIZE}"
)
[[ -n "${PG_PASSWORD}" ]] && SB_COMMON+=(--pgsql-password="${PG_PASSWORD}")

log "Target: ${PG_USER}@${PG_HOST}:${PG_PORT}/${PG_DB}"
introspect_db
log "Workload: ${MODE} | threads=${THREADS} | warmup=${WARMUP}s | time=${DURATION}s | tables=${TABLES} | rows/table=${TABLE_SIZE}"

# ── Phases ───────────────────────────────────────────────────────────────────
if ${CLEANUP_ONLY}; then
    log "Cleanup only — dropping sbtest tables"
    sysbench "${SB_COMMON[@]}" "${MODE}" cleanup
    exit 0
fi

if ${PHASE_PREPARE}; then
    log "Preparing data (this can take a while for large sizes)…"
    # --threads helps prepare go faster; sysbench parallelizes table loading
    sysbench "${SB_COMMON[@]}" --threads="${THREADS}" "${MODE}" prepare
fi

if ${PHASE_RUN}; then
    SB_RUN=(
        --threads="${THREADS}"
        --time="${DURATION}"
        --report-interval="${REPORT_INTERVAL}"
        --histogram=on
    )
    [[ "${WARMUP}" -gt 0 ]] && SB_RUN+=(--warmup-time="${WARMUP}")
    log "Running ${MODE}: ${WARMUP}s warmup + ${DURATION}s measured, ${THREADS} threads"
    sysbench "${SB_COMMON[@]}" "${SB_RUN[@]}" "${MODE}" run
fi

if ${PHASE_CLEANUP}; then
    log "Cleaning up sbtest tables (use --keep to skip)"
    sysbench "${SB_COMMON[@]}" "${MODE}" cleanup
fi

log "Done."
