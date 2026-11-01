#!/usr/bin/env bash

filter_run_lines() {
    local file="${1:-}" run_id="${2:-}"

    if [ "$#" -ne 2 ]; then
        echo "usage: filter_run_lines <file> <run_id>" >&2
        return 2
    fi

    if [ -z "$run_id" ] || [ -z "$file" ]; then
        return 2
    fi

    if ! grep -q "PROBE RUN ${run_id}" "$file" 2>/dev/null; then
        return 1
    fi

    awk -v rid="$run_id" '
        { sub(/\r$/, "") }
        /^PROBE RUN / {
            inrun = ($0 == "PROBE RUN " rid) ? 1 : 0
            next
        }
        inrun && /^PROBE / { print }
    ' "$file"
}

run_output() {
    filter_run_lines "${1:-}" "${2:-}" | awk '!seen[$0]++'
    return "${PIPESTATUS[0]}"
}
