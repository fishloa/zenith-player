#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/run-filter.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/old.log" <<'LOG'
PROBE PASS 1
PROBE PASS 2
LOG
out="$(filter_run_lines "$tmp/old.log" abc 2>/dev/null)" && rc=0 || rc=$?
if [ "$rc" -eq 0 ]; then echo "case1 expected nonzero exit" >&2; exit 1; fi
if [ -n "$out" ]; then echo "case1 expected no output, got: $out" >&2; exit 1; fi

cat > "$tmp/new.log" <<'LOG'
PROBE RUN abc
PROBE PASS 1
PROBE DONE
LOG
out="$(filter_run_lines "$tmp/new.log" abc)"
expected=$'PROBE PASS 1\nPROBE DONE'
if [ "$out" != "$expected" ]; then echo "case2 mismatch: got [$out]" >&2; exit 1; fi

cat > "$tmp/multi.log" <<'LOG'
PROBE RUN xyz
PROBE OLD 1
PROBE RUN abc
PROBE NEW 1
PROBE DONE
LOG
out="$(filter_run_lines "$tmp/multi.log" abc)"
expected=$'PROBE NEW 1\nPROBE DONE'
if [ "$out" != "$expected" ]; then echo "case3 mismatch: got [$out]" >&2; exit 1; fi

cat > "$tmp/dup.log" <<'LOG'
PROBE RUN abc
PROBE PASS 1
PROBE DONE
PROBE RUN abc
PROBE PASS 1
PROBE DONE
LOG
out="$(run_output "$tmp/dup.log" abc)"
expected=$'PROBE PASS 1\nPROBE DONE'
if [ "$out" != "$expected" ]; then echo "case4 mismatch: got [$out]" >&2; exit 1; fi

printf 'PROBE RUN old\r\nPROBE OLD 1\r\nPROBE RUN abc\r\nPROBE NEW 1\r\nPROBE DONE\r\nPROBE DONE\r\n' > "$tmp/crlf.log"
run_output "$tmp/crlf.log" abc > "$tmp/crlf.out"
printf 'PROBE NEW 1\nPROBE DONE\n' > "$tmp/crlf.expected"
if ! cmp -s "$tmp/crlf.out" "$tmp/crlf.expected"; then
  echo "case5 mismatch: got [$(cat "$tmp/crlf.out")]" >&2
  exit 1
fi

echo "all filter tests passed"
