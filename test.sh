#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")" && pwd)
source "$ROOT/scheduler.sh"
load_config
# Local "YYYY-MM-DD HH:MM:SS" -> epoch (GNU or BSD date).
to_epoch() {
  if date -d @0 +%s >/dev/null 2>&1; then /bin/date -d "$1" +%s
  else /bin/date -j -f '%Y-%m-%d %H:%M:%S' "$1" +%s; fi
}
expect() { [[ $1 == "$2" ]] || { echo "FAIL: $1 != $2"; exit 1; }; }
expect "$(slot_for 09:00)" 09:00
expect "$(slot_for 09:09)" 09:00
expect "$(slot_for 09:10 || echo skip)" skip
expect "$(slot_for 14:00)" 14:00
expect "$(slot_for 19:00)" 19:00
expect "$(slot_for 00:00)" 00:00
expect "$(slot_for 04:59 || echo skip)" skip
expect "$(slot_for 05:00 || echo skip)" skip
expect "$(slot_for 08:59 || echo skip)" skip
START_TIMES='23:58'
expect "$(slot_for 00:02)" 23:58
epoch=$(to_epoch '2026-10-20 00:02:00')
expect "$(slot_key "$epoch" 23:58)" 2026-10-19_23-58
load_config
LIMITS='{"rateLimitsByLimitId":{"codex":{"primary":{"windowDurationMins":300,"usedPercent":0,"resetsAt":2000}}}}'
expect "$(classify 1000)" active
expect "$(classify 2000)" inactive
LIMITS='{"rateLimits":{"limitId":"codex","primary":{"windowDurationMins":300,"resetsAt":null}}}'
expect "$(classify 2000)" unknown
LIMITS='{"rateLimits":{"limitId":"codex","primary":{"windowDurationMins":300,"resetsAt":1000},"secondary":{"windowDurationMins":10080,"usedPercent":100,"resetsAt":3000}}}'
expect "$(classify 2000)" blocked
LIMITS='{"rateLimits":{"limitId":"codex","primary":{"windowDurationMins":300,"resetsAt":1000}},"rateLimitsByLimitId":{"other":{}}}'
expect "$(classify 2000)" unknown

# Stub the CLI and clock: no real model requests, including failure/retry cases.
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
DATA="$TEST_DIR/state"; mkdir -p "$DATA"
CODEX_BIN="$TEST_DIR/codex"
cat >"$CODEX_BIN" <<'STUB'
#!/bin/bash
echo called >> "$CALL_LOG"
exit "${STUB_EXIT:-0}"
STUB
chmod +x "$CODEX_BIN"
export CALL_LOG="$TEST_DIR/calls"
FIXED_EPOCH=$(to_epoch '2026-10-20 09:00:00')
date() {
  case "$*" in
    +%s) echo "$FIXED_EPOCH" ;;
    +%H:%M) echo 09:00 ;;
    *) /bin/date "$@" ;;
  esac
}
read_limits() {
  LIMITS='{"accountId":"test-account","rateLimits":{"limitId":"codex","primary":{"windowDurationMins":300,"resetsAt":1000}}}'
}
tick live >/dev/null
tick live >/dev/null
expect "$(wc -l <"$CALL_LOG" | tr -d ' ')" 1
export STUB_EXIT=1
DATA="$TEST_DIR/failure"; mkdir -p "$DATA"
tick live >/dev/null
tick live >/dev/null
expect "$(wc -l <"$CALL_LOG" | tr -d ' ')" 2
echo 'PASS: 시간 경계, 자정, 잔여량 100%의 활성 창, 누락 상태, 주간 한도, 성공/실패 후 중복 방지'
