#!/usr/bin/env bash
# Redis benchmark runner for orb fence synthesis evaluation.
# Runs redis-benchmark against each server variant and collects results.
#
# Usage: ./bench.sh [--runs N] [--clients C] [--requests R] [variant...]
#   If no variants given, runs all that have result-* links.
#   Examples:
#     ./bench.sh                          # all variants, defaults
#     ./bench.sh clang orb                # just those two
#     ./bench.sh --runs 3 --requests 500000

set -euo pipefail

RUNS=3
CLIENTS=50
REQUESTS=200000
TESTS="ping_inline,ping_mbulk,set,get,incr,lpush,rpush,lpop,rpop,sadd,hset,mset"
PORT=0  # disable TCP
SOCK=/tmp/redis-bench-$$.sock
OUTDIR=bench-results/$(date +%Y%m%d-%H%M%S)

# --- parse args ---
VARIANTS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --runs)     RUNS="$2"; shift 2 ;;
        --clients)  CLIENTS="$2"; shift 2 ;;
        --requests) REQUESTS="$2"; shift 2 ;;
        *)          VARIANTS+=("$1"); shift ;;
    esac
done

# --- find variants ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

declare -A SERVERS
# Map result-<name> links to server binaries
for link in result-*; do
    [[ -L "$link" ]] || continue
    variant="${link#result-}"
    server="$link/bin/redis-server"
    [[ -x "$server" ]] || continue
    SERVERS["$variant"]="$server"
done

if [[ ${#SERVERS[@]} -eq 0 ]]; then
    echo "No result-* links found. Build variants first:"
    echo "  nix build '.#clang-O3' --out-link result-clang"
    echo "  nix build '.#orb-O3-fc333' --out-link result-orb"
    exit 1
fi

# Filter to requested variants
if [[ ${#VARIANTS[@]} -gt 0 ]]; then
    declare -A FILTERED
    for v in "${VARIANTS[@]}"; do
        found=0
        for k in "${!SERVERS[@]}"; do
            if [[ "$k" == "$v" ]]; then
                FILTERED["$k"]="${SERVERS[$k]}"
                found=1
            fi
        done
        if [[ $found -eq 0 ]]; then
            echo "Warning: variant '$v' not found (no result-$v link)" >&2
        fi
    done
    if [[ ${#FILTERED[@]} -eq 0 ]]; then
        echo "No matching variants found." >&2
        exit 1
    fi
    unset SERVERS
    declare -A SERVERS
    for k in "${!FILTERED[@]}"; do SERVERS["$k"]="${FILTERED[$k]}"; done
fi

# --- find benchmark tool ---
# Prefer our clang-built redis-benchmark, fall back to nixpkgs
BENCH=""
for link in result-clang result-gcc; do
    if [[ -x "$link/bin/redis-benchmark" ]]; then
        BENCH="$link/bin/redis-benchmark"
        break
    fi
done
if [[ -z "$BENCH" ]]; then
    BENCH="$(command -v redis-benchmark 2>/dev/null || true)"
fi
if [[ -z "$BENCH" ]]; then
    echo "No redis-benchmark found. Build clang variant or enter devShell." >&2
    exit 1
fi

CLI=""
for link in result-clang result-gcc; do
    if [[ -x "$link/bin/redis-cli" ]]; then
        CLI="$link/bin/redis-cli"
        break
    fi
done
if [[ -z "$CLI" ]]; then
    CLI="$(command -v redis-cli 2>/dev/null || true)"
fi

echo "Benchmark tool: $BENCH"
echo "Variants: ${!SERVERS[*]}"
echo "Runs: $RUNS, Clients: $CLIENTS, Requests: $REQUESTS"
echo ""

mkdir -p "$OUTDIR"

# --- run benchmarks ---
for variant in $(echo "${!SERVERS[@]}" | tr ' ' '\n' | sort); do
    server="${SERVERS[$variant]}"
    echo "=== $variant ==="
    echo "  server: $server"

    for run in $(seq 1 "$RUNS"); do
        echo "  run $run/$RUNS ..."
        rm -f "$SOCK"

        # Start server
        "$server" \
            --port "$PORT" \
            --unixsocket "$SOCK" \
            --unixsocketperm 700 \
            --daemonize no \
            --save "" \
            --appendonly no \
            --loglevel warning \
            --io-threads 1 \
            &
        SERVER_PID=$!

        # Wait for socket
        for i in $(seq 1 30); do
            [[ -S "$SOCK" ]] && break
            sleep 0.1
        done
        if [[ ! -S "$SOCK" ]]; then
            echo "  ERROR: server failed to start" >&2
            kill "$SERVER_PID" 2>/dev/null || true
            wait "$SERVER_PID" 2>/dev/null || true
            continue
        fi

        # Run benchmark
        outfile="$OUTDIR/${variant}_run${run}.csv"
        "$BENCH" \
            -s "$SOCK" \
            -c "$CLIENTS" \
            -n "$REQUESTS" \
            -t "$TESTS" \
            --csv \
            > "$outfile" 2>/dev/null

        # Shutdown server
        if [[ -n "$CLI" ]]; then
            "$CLI" -s "$SOCK" SHUTDOWN NOSAVE 2>/dev/null || true
        else
            kill "$SERVER_PID" 2>/dev/null || true
        fi
        wait "$SERVER_PID" 2>/dev/null || true
        rm -f "$SOCK"

        # Print results for this run
        head -1 "$outfile" | grep -q "test" && \
            tail -n +2 "$outfile" | while IFS=, read -r test rps rest; do
                printf "    %-20s %s req/s\n" "$(echo $test | tr -d '"')" "$(echo $rps | tr -d '"')"
            done
    done
    echo ""
done

# --- summary ---
echo "=== Summary (average req/s across $RUNS runs) ==="
printf "%-20s" "test"
for variant in $(echo "${!SERVERS[@]}" | tr ' ' '\n' | sort); do
    printf "  %-16s" "$variant"
done
echo ""

# Get test names from first CSV
first_csv=$(ls "$OUTDIR"/*.csv 2>/dev/null | head -1)
if [[ -z "$first_csv" ]]; then
    echo "No results collected."
    exit 1
fi

tail -n +2 "$first_csv" | cut -d, -f1 | tr -d '"' | while read -r test; do
    printf "%-20s" "$test"
    for variant in $(echo "${!SERVERS[@]}" | tr ' ' '\n' | sort); do
        avg=$(awk -F, -v t="\"$test\"" '$1 == t { gsub(/"/, "", $2); sum += $2; n++ } END { if(n>0) printf "%.0f", sum/n; else printf "N/A" }' \
            "$OUTDIR"/${variant}_run*.csv 2>/dev/null)
        printf "  %-16s" "$avg"
    done
    echo ""
done

echo ""
echo "Raw results: $OUTDIR/"
