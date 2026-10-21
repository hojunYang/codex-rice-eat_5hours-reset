#!/bin/bash
# Linux/macOS (GNU or BSD date) + Bash 3.2+. No API key or authentication-file parsing.
set -euo pipefail
umask 077
ROOT=$(cd "$(dirname "$0")" && pwd)
CONFIG=${CODEX_WINDOW_CONFIG:-"$ROOT/schedule.conf"}
DATA=${CODEX_WINDOW_STATE_DIR:-"$ROOT/.state"}
PING_PID="" LOCKED=0

# epoch -> formatted local time. GNU date uses -d @N, BSD (macOS) date uses -r N.
if date -d @0 +%s >/dev/null 2>&1; then
  epoch_fmt() { date -d "@$1" "$2"; }
else
  epoch_fmt() { date -r "$1" "$2"; }
fi
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$*"; }
die() { log "$*" >&2; exit 1; }
minutes() {
  [[ $1 =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || return 1
  printf '%s\n' "$((10#${1%:*} * 60 + 10#${1#*:}))"
}
load_config() {
  # The configuration is a local, trusted shell file.
  source "$CONFIG"
  [[ -x $CODEX_BIN ]] || die "Codex CLI를 찾을 수 없습니다: $CODEX_BIN"
  [[ $START_GRACE_MINUTES =~ ^[0-9]+$ && $CHECK_INTERVAL_SECONDS =~ ^[0-9]+$ ]] || die '간격은 정수여야 합니다.'
  (( START_GRACE_MINUTES >= 1 && START_GRACE_MINUTES <= 60 )) || die '시작 유예 시간은 1~60분이어야 합니다.'
  (( CHECK_INTERVAL_SECONDS >= 5 && CHECK_INTERVAL_SECONDS <= 300 )) || die '확인 주기는 5~300초여야 합니다.'
  local t seen=' '
  [[ -n $START_TIMES && -n $PROMPT ]] || die '시작 시간과 질문은 비워 둘 수 없습니다.'
  for t in $START_TIMES; do
    minutes "$t" >/dev/null || die "잘못된 시작 시간: $t"
    [[ $seen != *" $t "* ]] || die "중복 시작 시간: $t"
    seen="$seen$t "
  done
  minutes "$QUIET_START" >/dev/null || die '잘못된 휴식 시작 시간'
  minutes "$QUIET_END" >/dev/null || die '잘못된 휴식 종료 시간'
  [[ $QUIET_START != "$QUIET_END" ]] || die '휴식 시작과 종료는 달라야 합니다.'
}

# Prints a scheduled time only within its start grace period and outside quiet hours.
slot_for() {
  local current qs qe t start elapsed chosen='' best=1441
  current=$(minutes "$1") || return 1
  qs=$(minutes "$QUIET_START"); qe=$(minutes "$QUIET_END")
  if (( qs < qe )); then
    (( current >= qs && current < qe )) && return 1
  else
    (( current >= qs || current < qe )) && return 1
  fi
  for t in $START_TIMES; do
    start=$(minutes "$t")
    elapsed=$(( (current - start + 1440) % 1440 ))
    if (( elapsed < START_GRACE_MINUTES && elapsed < best )); then
      chosen=$t; best=$elapsed
    fi
  done
  [[ -n $chosen ]] || return 1
  printf '%s\n' "$chosen"
}
slot_key() {
  local epoch=$1 slot=$2 day
  if (( $(minutes "$(epoch_fmt "$epoch" '+%H:%M')") < $(minutes "$slot") )); then
    epoch=$((epoch - 86400))
  fi
  day=$(epoch_fmt "$epoch" '+%Y-%m-%d')
  printf '%s_%s\n' "$day" "${slot/:/-}"
}
cleanup() {
  if [[ -n $PING_PID ]]; then kill "$PING_PID" 2>/dev/null || true; fi
  if (( LOCKED )); then rm -f "$DATA/lock/pid"; rmdir "$DATA/lock" 2>/dev/null || true; fi
}
acquire_lock() {
  mkdir -p "$DATA/attempts"
  if ! mkdir "$DATA/lock" 2>/dev/null; then
    die "다른 실행이 있거나 이전 잠금이 남아 있습니다: $DATA/lock (PID 파일을 확인하세요.)"
  fi
  LOCKED=1
  printf '%s\n' "$$" >"$DATA/lock/pid"
}
send_ping() {
  local key=$1 attempt="$DATA/attempts/$1" now slot current_key exit_code=0 started
  # Recheck the schedule immediately before sending.
  now=$(date +%s)
  slot=$(slot_for "$(date '+%H:%M')") || return 0
  current_key=$(slot_key "$now" "$slot")
  [[ $key == "$current_key" ]] || return 0
  mkdir -p "$DATA/attempts"
  # Already attempted for this slot: stay silent so the 15-second loop does not spam logs.
  mkdir "$attempt" 2>/dev/null || return 0
  printf 'attempted %s\n' "$now" >"$attempt/result"
  log "예약 $key: CLI 질문을 1회 전송합니다. / model=${MODEL:-default} / attemptedAt=$now"
  local args=(exec --ignore-user-config --ignore-rules --ephemeral --skip-git-repo-check
    --sandbox read-only -c 'approval_policy="never"' -c 'project_doc_max_bytes=0'
    --color never --json -C "$attempt")
  [[ -z $MODEL ]] || args+=(--model "$MODEL")
  "$CODEX_BIN" "${args[@]}" "$PROMPT" >"$attempt/response.jsonl" 2>"$attempt/stderr.log" &
  PING_PID=$!; started=$(date +%s)
  while kill -0 "$PING_PID" 2>/dev/null; do
    if (( $(date +%s) - started >= 120 )); then
      kill "$PING_PID" 2>/dev/null || true
      sleep 2
      kill -KILL "$PING_PID" 2>/dev/null || true
      exit_code=124; break
    fi
    sleep 1
  done
  wait "$PING_PID" || exit_code=$?
  PING_PID=''
  if (( exit_code != 0 )); then
    printf 'uncertain exit=%s\n' "$exit_code" >"$attempt/result"
    log "요청 실패/시간 초과($exit_code). 중복 방지를 위해 이번 예약은 재전송하지 않습니다."
    return 0
  fi
  printf 'sent\n' >"$attempt/result"
  log "예약 $key / CLI 응답 완료 / 소요시간=$(( $(date +%s) - started ))초"
}
tick() {
  local dry=$1 epoch slot key
  epoch=$(date +%s)
  if ! slot=$(slot_for "$(date '+%H:%M')"); then
    [[ $dry != dry ]] || log '예약 시작 유예 시간 밖이거나 휴식 시간입니다. 전송하지 않습니다.'
    return 0
  fi
  key=$(slot_key "$epoch" "$slot")
  if [[ $dry == dry ]]; then log "DRY RUN: 예약 $key / 이 조건에서는 질문을 1회 전송합니다."; return 0; fi
  send_ping "$key"
}
main() {
  local previous_slot='' current_slot=''
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  load_config
  case ${1:-dry-run} in
    dry-run)
      log "예약: $START_TIMES / 휴식: $QUIET_START~$QUIET_END"
      tick dry ;;
    once) acquire_lock; tick live ;;
    run)
      acquire_lock
      log "감시 시작: $START_TIMES / 휴식 $QUIET_START~$QUIET_END / 유예=${START_GRACE_MINUTES}분 / 확인주기=${CHECK_INTERVAL_SECONDS}초 / model=${MODEL:-default} / CLI=$("$CODEX_BIN" --version)"
      while true; do
        load_config
        current_slot=$(slot_for "$(date '+%H:%M')" || true)
        if [[ -n $previous_slot && $previous_slot != "$current_slot" ]]; then
          log "예약 $previous_slot / 확인 종료: 시작 유예 시간 또는 허용 시간대가 끝났습니다."
        fi
        previous_slot=$current_slot
        tick live
        sleep "$CHECK_INTERVAL_SECONDS"
      done ;;
    *) die '사용법: scheduler.sh {dry-run|once|run}' ;;
  esac
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
