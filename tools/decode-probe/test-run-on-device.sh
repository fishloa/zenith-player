#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin"
RUN_ID_FILE="$tmp/last-run-id"
: > "$RUN_ID_FILE"
export RUN_ID_FILE

cat > "$tmp/bin/xcrun" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" != "devicectl" ]; then
  exit 0
fi
shift
args="$*"
record_run_id() {
  local prev=""
  for a in "$@"; do
    if [ "$prev" = "-runId" ]; then
      printf '%s' "$a" > "${RUN_ID_FILE:?}"
    fi
    prev="$a"
  done
}
case "$args" in
  *"device process launch"*"--console"*)
    record_run_id "$@"
    sleep 3600
    exit 0
    ;;
  *"device process launch"*)
    record_run_id "$@"
    sleep 3600
    exit 0
    ;;
  *"device copy from"*)
    dest=""
    prev=""
    for a in "$@"; do
      if [ "$prev" = "--destination" ]; then dest="$a"; fi
      prev="$a"
    done
    rid="$(cat "${RUN_ID_FILE:?}" 2>/dev/null || true)"
    {
      echo "PROBE RUN ${rid}"
      echo "PROBE SOAK DONE 1/1 passed"
    } > "$dest"
    exit 0
    ;;
  *"device info processes"*)
    echo "DecodeProbe.app running"
    exit 0
    ;;
  *"device install"*)
    exit 0
    ;;
  *"list devices"*)
    echo "AppleTV physical 00000000-0000-0000-0000-000000000000"
    exit 0
    ;;
esac
exit 0
STUB
chmod +x "$tmp/bin/xcrun"

cat > "$tmp/bin/xcodebuild" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$tmp/bin/xcodebuild"

cat > "$tmp/bin/xcodegen" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$tmp/bin/xcodegen"

export PATH="$tmp/bin:$PATH"
export PROBE_BUNDLE_ID="com.example.decodeprobe"
export TEAM_ID="TEAM"
export ASC_KEY_ID="KEY"
export ASC_ISSUER_ID="ISSUER"
export ZENITH_URL="http://example.test"
export SKIP_BUILD=1
export WAIT_FOR="PROBE SOAK DONE"

set +e
timeout 240 "$HERE/run-on-device.sh" "TEST-UDID" >"$tmp/out" 2>"$tmp/err"
rc=$?
set -e

if [ "$rc" -ne 0 ]; then
  echo "expected exit 0, got $rc" >&2
  echo "--- stdout ---" >&2
  cat "$tmp/out" >&2
  echo "--- stderr ---" >&2
  cat "$tmp/err" >&2
  exit 1
fi
if ! grep -q "PROBE SOAK DONE" "$tmp/out"; then
  echo "expected stdout to contain PROBE SOAK DONE" >&2
  echo "--- stdout ---" >&2
  cat "$tmp/out" >&2
  echo "--- stderr ---" >&2
  cat "$tmp/err" >&2
  exit 1
fi

echo "all on-device run tests passed"