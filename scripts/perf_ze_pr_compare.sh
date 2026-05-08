#!/usr/bin/env bash

set -euo pipefail
PERFTEST=${PERFTEST:-build/src/tools/perf/ucx_perftest}
PORT=${PORT:-13347}
ITERS=${ITERS:-200}
WARMUP=${WARMUP:-20}
TIMEOUT=${TIMEOUT:-30}
SIZES=${SIZES:-"4096 65536 1048576 4194304 8388608"}
TESTS=${TESTS:-"put_bw get_bw"}
MODE=${1:-all}

# Optional: per-side ZE_AFFINITY_MASK for cross-card / cross-tile runs.
# Each value is a Level Zero device selector, e.g. "0" picks card0 (all tiles)
# and "0.1" picks card0 tile1. Examples:
#   SERVER_AFFINITY=0.0 CLIENT_AFFINITY=0.1   # same card, different tiles
#   SERVER_AFFINITY=0   CLIENT_AFFINITY=1     # different cards
# Leave unset to let UCX use whatever ZE_AFFINITY_MASK is in the environment.

if [[ ! -x "$PERFTEST" ]]; then
    echo "ERROR: ucx_perftest not found: $PERFTEST" >&2
    echo "Run from UCX repo root, or set PERFTEST=/path/to/ucx_perftest" >&2
    exit 1
fi

RESULTS=$(mktemp /tmp/ucx_ze_perf_results.XXXXXX)
DETAILS=$(mktemp /tmp/ucx_ze_perf_details.XXXXXX)
trap 'rm -f "$RESULTS" "$DETAILS" /tmp/ucx_perf_srv.out /tmp/ucx_perf_cli.out' EXIT

CASE_ID=0

append_result() {
    local path=$1
    local test=$2
    local size=$3
    local output=$4
    local status=${5:-}
    local note=${6:-}

    local final
    final=$(awk '/^Final:/ {line=$0} END {print line}' <<<"$output")
    if [[ -n "$final" ]]; then
        awk -v path="$path" -v test="$test" -v size="$size" \
            'BEGIN {status="OK"}
             /^Final:/ {
                 printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", \
                        path, test, size, status, $3, $4, $6, $8, ""
             }' <<<"$final" >>"$RESULTS"
        return
    fi

    if [[ -z "$status" ]]; then
        status="FAIL"
    fi
    if [[ -z "$note" ]]; then
        note=$(awk '/ERROR|WARN|SKIP|Destination is unreachable|does not support/ {print; exit}' <<<"$output")
    fi
    note=${note//$'\t'/ }
    printf "%s\t%s\t%s\t%s\t-\t-\t-\t-\t%s\n" \
           "$path" "$test" "$size" "$status" "$note" >>"$RESULTS"
}

run_loopback() {
    local path=$1
    local test=$2
    local size=$3
    shift 3

    local output
    output=$(timeout "$TIMEOUT" env UCX_LOG_LEVEL=warn "$PERFTEST" "$@" 2>&1 || true)
    {
        echo "=== $path $test size=$size ==="
        awk '/^Final:/ || /ERROR|WARN|Destination is unreachable|does not support|SKIP/' <<<"$output"
    } >>"$DETAILS"
    append_result "$path" "$test" "$size" "$output"
}

run_pair() {
    local path=$1
    local test=$2
    local size=$3
    shift 3

    local case_port=$((PORT + CASE_ID))
    CASE_ID=$((CASE_ID + 1))

    rm -f /tmp/ucx_perf_srv.out /tmp/ucx_perf_cli.out
    # Optional per-side ZE_AFFINITY_MASK for cross-card / cross-tile runs.
    # Falls back to whatever ZE_AFFINITY_MASK is in the environment.
    local srv_aff=${SERVER_AFFINITY:-${ZE_AFFINITY_MASK:-}}
    local cli_aff=${CLIENT_AFFINITY:-${ZE_AFFINITY_MASK:-}}
    timeout "$TIMEOUT" env UCX_LOG_LEVEL=warn ZE_AFFINITY_MASK="$srv_aff" \
        "$PERFTEST" -p "$case_port" "$@" \
        >/tmp/ucx_perf_srv.out 2>&1 &
    local server_pid=$!

    sleep 1
    timeout "$TIMEOUT" env UCX_LOG_LEVEL=warn ZE_AFFINITY_MASK="$cli_aff" \
        "$PERFTEST" -p "$case_port" 127.0.0.1 "$@" \
        >/tmp/ucx_perf_cli.out 2>&1 || true
    wait "$server_pid" 2>/dev/null || true

    local output
    output=$(cat /tmp/ucx_perf_cli.out /tmp/ucx_perf_srv.out)
    {
        echo "=== $path $test size=$size ==="
        awk '/^Final:/ || /ERROR|WARN|Destination is unreachable|does not support|SKIP/' <<<"$output" | tail -20
    } >>"$DETAILS"
    append_result "$path" "$test" "$size" "$output"
}

skip_case() {
    local path=$1
    local test=$2
    local size=$3
    local note=$4
    printf "%s\n" "=== $path $test size=$size ===" "SKIP: $note" >>"$DETAILS"
    append_result "$path" "$test" "$size" "" "SKIP" "$note"
}

run_with_pr_ze_ipc() {
    [[ "$MODE" == "all" || "$MODE" == "with-pr" || "$MODE" == "ze-ipc" ]] || return 0

    for test in $TESTS; do
        for size in $SIZES; do
            run_pair "WITH_PR:ze_ipc" "$test" "$size" \
                -t "$test" -D zcopy -s "$size" -n "$ITERS" -w "$WARMUP" \
                -m ze-device -x ze_ipc -d ze_ipc
        done
    done
}

run_host_transport_baseline() {
    [[ "$MODE" == "all" || "$MODE" == "baseline" || "$MODE" == "host" || "$MODE" == "tcp" || "$MODE" == "cma" ]] || return 0

    for test in $TESTS; do
        for size in $SIZES; do
            if [[ "$MODE" == "all" || "$MODE" == "baseline" || "$MODE" == "host" || "$MODE" == "tcp" ]]; then
                if [[ "$test" == "get_bw" ]]; then
                    skip_case "NO_ZE_IPC:host_tcp" "$test" "$size" \
                        "UCT tcp/lo does not support get_bw zcopy; use put_bw for TCP host transport baseline"
                else
                    run_pair "NO_ZE_IPC:host_tcp" "$test" "$size" \
                        -t "$test" -D zcopy -s "$size" -n "$ITERS" -w "$WARMUP" \
                        -m host -x tcp -d lo
                fi
            fi

            if [[ "$MODE" == "all" || "$MODE" == "baseline" || "$MODE" == "host" || "$MODE" == "cma" ]]; then
                run_loopback "NO_ZE_IPC:host_cma" "$test" "$size" \
                    -t "$test" -D zcopy -s "$size" -n "$ITERS" -w "$WARMUP" \
                    -m host -x cma -d memory -l
            fi
        done
    done
}

run_staging_component() {
    [[ "$MODE" == "all" || "$MODE" == "staging" || "$MODE" == "ze-copy" ]] || return 0

    for size in $SIZES; do
        run_loopback "STAGING:ze_copy_same" "put_bw" "$size" \
            -t put_bw -D zcopy -s "$size" -n "$ITERS" -w "$WARMUP" \
            -m ze-device -x ze_copy -d GPU0 -l
        run_loopback "STAGING:xpu_to_cpu" "put_bw" "$size" \
            -t put_bw -D zcopy -s "$size" -n "$ITERS" -w "$WARMUP" \
            -m ze-device,host -x ze_copy -d GPU0 -l
        run_loopback "STAGING:cpu_to_xpu" "put_bw" "$size" \
            -t put_bw -D zcopy -s "$size" -n "$ITERS" -w "$WARMUP" \
            -m host,ze-device -x ze_copy -d GPU0 -l
    done
}

print_table() {
    echo
    echo "Summary table"
    printf '%-24s %-7s %10s %8s %10s %10s %12s %12s %s\n' \
           "path" "test" "size(B)" "status" "p50_us" "avg_us" "bw_MBps" "msg_rate" "note"
    printf '%-24s %-7s %10s %8s %10s %10s %12s %12s %s\n' \
           "------------------------" "-------" "----------" "--------" "----------" "----------" "------------" "------------" "----"
    awk -F'\t' '{printf "%-24s %-7s %10s %8s %10s %10s %12s %12s %s\n", $1, $2, $3, $4, $5, $6, $7, $8, $9}' "$RESULTS"

    echo
    echo "Notes"
    echo "  WITH_PR:ze_ipc       = direct XPU IPC path from the PR"
    echo "  NO_ZE_IPC:host_tcp   = host transport segment if fallback stages through CPU over TCP"
    echo "  NO_ZE_IPC:host_cma   = same-node host transport segment if fallback stages through CPU over CMA"
    echo "  STAGING:xpu_to_cpu   = XPU -> CPU staging copy cost"
    echo "  STAGING:cpu_to_xpu   = CPU -> XPU staging copy cost"
    echo "  ze_copy e2e          = STAGING:xpu_to_cpu + host_tcp/host_cma + STAGING:cpu_to_xpu"
    echo
    echo "Raw relevant lines saved in: $DETAILS"
}

print_e2e_table() {
    echo
    echo "E2E comparison (computed from avg_us)"
            printf '%-22s %-7s %10s %12s %10s %10s %10s %14s %16s %s\n' \
                "path" "test" "size(B)" "e2e_us" "d2h_us" "host_us" "h2d_us" "eff_bw_MBps" "vs_ze_ipc" "formula"
            printf '%-22s %-7s %10s %12s %10s %10s %10s %14s %16s %s\n' \
                "----------------------" "-------" "----------" "------------" "----------" "----------" "----------" "--------------" "----------------" "-------"
    awk -F'\t' '
        $4 == "OK" {
            key = $2 SUBSEP $3
            avg[$1, $2, $3] = $6 + 0
        }
        END {
            for (key in avg) {
                split(key, parts, SUBSEP)
            }
        }
    ' "$RESULTS" >/dev/null

    for test in $TESTS; do
        for size in $SIZES; do
            awk -F'\t' -v test="$test" -v size="$size" '
                $4 == "OK" && $2 == test && $3 == size {
                    avg[$1] = $6 + 0
                }
                END {
                    ze = avg["WITH_PR:ze_ipc"]
                    if (ze > 0) {
                        bw = (size / ze)
                           printf "%-22s %-7s %10s %12.3f %10s %10s %10s %14.2f %15.2fx %s\n", \
                               "ze_ipc", test, size, ze, "-", "-", "-", bw, 1.0, "direct XPU->XPU IPC"
                    }
                }
            ' "$RESULTS"
        done
    done

    for size in $SIZES; do
        awk -F'\t' -v size="$size" '
            $4 == "OK" && $3 == size {
                avg[$1, $2] = $6 + 0
            }
            END {
                d2h = avg["STAGING:xpu_to_cpu", "put_bw"]
                h2d = avg["STAGING:cpu_to_xpu", "put_bw"]
                ze  = avg["WITH_PR:ze_ipc", "put_bw"]

                tcp_e2e = 0
                cma_e2e = 0

                tcp = avg["NO_ZE_IPC:host_tcp", "put_bw"]
                if ((d2h > 0) && (h2d > 0) && (tcp > 0)) {
                    tcp_e2e = d2h + tcp + h2d
                    bw  = size / tcp_e2e
                    ratio = (ze > 0) ? (tcp_e2e / ze) : 0
                          printf "%-22s %-7s %10s %12.3f %10.3f %10.3f %10.3f %14.2f %15.2fx %s\n", \
                              "ze_copy_e2e_tcp", "put_bw", size, tcp_e2e, d2h, tcp, h2d, bw, ratio, \
                           "ze_copy(D2H) + host_tcp + ze_copy(H2D)"
                }

                cma = avg["NO_ZE_IPC:host_cma", "put_bw"]
                if ((d2h > 0) && (h2d > 0) && (cma > 0)) {
                    cma_e2e = d2h + cma + h2d
                    bw  = size / cma_e2e
                    ratio = (ze > 0) ? (cma_e2e / ze) : 0
                          printf "%-22s %-7s %10s %12.3f %10.3f %10.3f %10.3f %14.2f %15.2fx %s\n", \
                              "ze_copy_e2e_cma", "put_bw", size, cma_e2e, d2h, cma, h2d, bw, ratio, \
                           "ze_copy(D2H) + host_cma + ze_copy(H2D)"
                }

                if ((tcp_e2e > 0) || (cma_e2e > 0)) {
                    best = tcp_e2e
                    name = "tcp"
                    if ((best == 0) || ((cma_e2e > 0) && (cma_e2e < best))) {
                        best = cma_e2e
                        name = "cma"
                    }
                    bw = size / best
                    ratio = (ze > 0) ? (best / ze) : 0
                          host = (name == "cma") ? cma : tcp
                          printf "%-22s %-7s %10s %12.3f %10.3f %10.3f %10.3f %14.2f %15.2fx %s\n", \
                              "ze_copy_e2e_best", "put_bw", size, best, d2h, host, h2d, bw, ratio, \
                           "best host path = " name
                }
            }
        ' "$RESULTS"
    done
}

cat <<EOF
UCX ZE PR comparison
  mode:    $MODE
  sizes:   $SIZES
  tests:   $TESTS
  iters:   $ITERS
  warmup:  $WARMUP
  timeout: ${TIMEOUT}s/case
EOF

run_with_pr_ze_ipc
run_host_transport_baseline
run_staging_component
print_table
print_e2e_table
