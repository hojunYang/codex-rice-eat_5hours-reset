#!/bin/bash
# Linux/macOS (GNU or BSD date) + Bash 3.2+ + jq. No API key or authentication-file parsing.
set -euo pipefail
umask 077
ROOT=$(cd "$(dirname "$0")" && pwd)
CONFIG=${CODEX_WINDOW_CONFIG:-"$ROOT/schedule.conf"}
DATA=${CODEX_WINDOW_STATE_DIR:-"$ROOT/.state"}
RPC_DIR="" RPC_PID="" PING_PID="" LOCKED=0

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
  command -v jq >/dev/null || die 'jq가 필요합니다: 패키지 관리자로 jq를 설치하세요 (macOS: brew install jq, Linux: sudo apt install jq)'
  [[ -x $CODEX_BIN ]] || die "Codex CLI를 찾을 수 없습니다: $CODEX_BIN"
  [[ $START_GRACE_MINUTES =~ ^[0-9]+$ && $CHECK_INTERVAL_SECONDS =~ ^[0-9]+$ ]] || die '간격은 정수여야 합니다.'
  (( START_GRACE_MINUTES >= 1 && START_GRACE_MINUTES <= 60 )) || die '시작 유예 시간은 1~60분이어야 합니다.'
  (( CHECK_INTERVAL_SECONDS >= 5 && CHECK_INTERVAL_SECONDS <= 300 )) || die '확인 주기는 5~300초여야 합니다.'
  local t seen=' '
  [[ -n $START_TIMES && -n $LIMIT_ID && -n $PROMPT ]] || die '시작 시간, 버킷, 질문은 비워 둘 수 없습니다.'
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
stop_rpc() {
  if [[ -n $RPC_PID ]]; then
    kill "$RPC_PID" 2>/dev/null || true
    wait "$RPC_PID" 2>/dev/null || true
    RPC_PID=''
    exec 3>&-
  fi
  if [[ -n $RPC_DIR ]]; then rm -rf "$RPC_DIR"; RPC_DIR=''; fi
}
cleanup() {
  if [[ -n $PING_PID ]]; then kill "$PING_PID" 2>/dev/null || true; fi
  stop_rpc
  if (( LOCKED )); then rm -f "$DATA/lock/pid"; rmdir "$DATA/lock" 2>/dev/null || true; fi
}
rpc_call() {
  local id=$1 method=$2 params=$3 n answer
  jq -cn --argjson id "$id" --arg method "$method" --argjson params "$params" \
    '{id:$id,method:$method,params:$params}' >&3
  for ((n=0;n<30;n++)); do
    # Each JSONL response is atomic; ignore an incomplete last line while polling.
    answer=$(jq -Rc --argjson id "$id" 'fromjson? | select(.id == $id)' "$RPC_DIR/out" | head -1)
    if [[ -n $answer ]]; then
      if jq -e 'has("error")' <<< "$answer" >/dev/null; then
        log "CLI 상태 조회 오류: $(jq -r '.error.message' <<< "$answer")" >&2; return 1
      fi
      jq -c '.result' <<< "$answer"; return 0
    fi
    kill -0 "$RPC_PID" 2>/dev/null || return 1
    sleep 1
  done
  log 'CLI 상태 조회 시간 초과. 질문을 보내지 않습니다.' >&2; return 1
}
read_limits() {
  local response ok=0 requested_at
  requested_at=$(date +%s)
  RPC_DIR=$(mktemp -d "${TMPDIR:-/tmp}/codex-window.XXXXXX")
  mkfifo "$RPC_DIR/in"
  exec 3<>"$RPC_DIR/in"
  "$CODEX_BIN" app-server <"$RPC_DIR/in" >"$RPC_DIR/out" 2>"$RPC_DIR/err" &
  RPC_PID=$!
  if rpc_call 1 initialize '{"clientInfo":{"name":"codex_window_scheduler","version":"1.0.0"}}' >/dev/null; then
    printf '%s\n' '{"method":"initialized","params":{}}' >&3
    if response=$(rpc_call 2 account/rateLimits/read '{}'); then
      LIMITS=$response; ok=1
    fi
  fi
  stop_rpc
  if (( ok == 1 )); then
    log "사용량 진단: $(limits_diagnostic "$requested_at" "$(date +%s)")"
  else
    log "사용량 조회 실패 / 요청시각=$requested_at / 종료시각=$(date +%s)"
  fi
  (( ok == 1 ))
}

limits_diagnostic() {
  local account_tag='unknown'
  # A comparison tag helps detect account switches without logging the account ID.
  if jq -e '.accountId | type == "string" and length > 0' <<< "$LIMITS" >/dev/null; then
    account_tag=$(jq -jr '.accountId' <<< "$LIMITS" | cksum | awk '{print $1}')
  fi
  jq -c --arg id "$LIMIT_ID" --arg model "${MODEL:-default}" --arg account "$account_tag" \
    --argjson requested "$1" --argjson received "$2" '
    def window:
      if . == null then null else
        {usedPercent, windowDurationMins, resetsAt,
         secondsUntilReset:(if (.resetsAt|type) == "number" then .resetsAt - $received else null end)}
      end;
    def bucket:
      if . == null then null else
        {limitId, planType, primary:(.primary|window), secondary:(.secondary|window),
         spendControlReached, rateLimitReachedType}
      end;
    {requestedAt:$requested, receivedAt:$received, querySeconds:($received - $requested),
     accountTag:$account, selectedLimitId:$id, pingModel:$model,
     source:(if .rateLimitsByLimitId != null then "rateLimitsByLimitId" else "rateLimits" end),
     ordinaryUsageAllowed,
     rateLimits:(.rateLimits|bucket),
     rateLimitsByLimitId:(if .rateLimitsByLimitId == null then null
                         else .rateLimitsByLimitId | with_entries(.value |= bucket) end)}' <<< "$LIMITS"
}

# Missing fields are unknown, never evidence of an inactive window.
classify() {
  jq -r --arg id "$LIMIT_ID" --argjson now "$1" '
    . as $root |
    (if .rateLimitsByLimitId != null then .rateLimitsByLimitId[$id]
     elif (.rateLimits.limitId == $id or (.rateLimits.limitId == null and $id == "codex")) then .rateLimits
     else null end) as $b |
    [$b.primary, $b.secondary] | map(select(.windowDurationMins == 300)) as $windows |
    if $b == null or ($windows|length) != 1 then "unknown"
    elif $root.ordinaryUsageAllowed == false or $b.spendControlReached == true then "blocked"
    elif ([$b.primary, $b.secondary] | any(. != null and .windowDurationMins != 300 and
          (.usedPercent // 0) >= 100 and (.resetsAt == null or .resetsAt > $now))) then "blocked"
    elif ($windows[0].resetsAt | type) != "number" or $windows[0].resetsAt <= 0 then "unknown"
    elif $windows[0].resetsAt > $now then "active"
    else "inactive" end' <<< "$LIMITS"
}
window_details() {
  local fields used reset reset_local='unknown'
  fields=$(jq -r --arg id "$LIMIT_ID" '
    (if .rateLimitsByLimitId != null then .rateLimitsByLimitId[$id]
     elif (.rateLimits.limitId == $id or (.rateLimits.limitId == null and $id == "codex")) then .rateLimits
     else null end) as $b |
    [$b.primary, $b.secondary] | map(select(.windowDurationMins == 300)) |
    (if length == 1 then .[0] else {} end) |
    [(.usedPercent // "unknown"), (.resetsAt // "unknown")] | @tsv' <<< "$LIMITS")
  IFS=$'\t' read -r used reset <<< "$fields"
  if [[ $reset =~ ^[0-9]+$ ]]; then
    reset_local=$(epoch_fmt "$reset" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null) || reset_local='unknown'
  fi
  printf 'usedPercent=%s / resetsAt=%s / 초기화=%s' "$used" "$reset" "$reset_local"
}
show_limits() {
  jq --arg id "$LIMIT_ID" '
    {ordinaryUsageAllowed, bucket:(if .rateLimitsByLimitId != null then .rateLimitsByLimitId[$id] else .rateLimits end)} |
    {ordinaryUsageAllowed, limitId:.bucket.limitId, primary:.bucket.primary, secondary:.bucket.secondary}' <<< "$LIMITS"
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
  local key=$1 account=$2 attempt="$DATA/attempts/$2/$1" now slot current_key state exit_code=0 started
  # A network lookup can cross a schedule boundary. Recheck immediately before sending.
  now=$(date +%s)
  slot=$(slot_for "$(date '+%H:%M')") || return 0
  current_key=$(slot_key "$now" "$slot")
  [[ $key == "$current_key" ]] || return 0
  mkdir -p "$DATA/attempts/$account"
  if ! mkdir "$attempt" 2>/dev/null; then
    log "예약 $key / 전송 생략: 기존 시도 기록이 있습니다."
    return 0
  fi
  printf 'attempted %s\n' "$now" >"$attempt/result"
  log "예약 $key: 비활성 창 확인. CLI 질문을 1회 전송합니다. / model=${MODEL:-default} / attemptedAt=$now"
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
  if read_limits; then
    state=$(classify "$(date +%s)")
    printf 'sent observed=%s\n' "$state" >"$attempt/result"
    log "전송 후 창 상태: $state / $(window_details)"
  else
    log '질문은 완료됐지만 활성 전환을 확인하지 못했습니다. 재전송하지 않습니다.'
  fi
}
tick() {
  local dry=$1 epoch slot key state account
  epoch=$(date +%s)
  if ! slot=$(slot_for "$(date '+%H:%M')"); then
    [[ $dry != dry ]] || log '예약 시작 유예 시간 밖이거나 휴식 시간입니다. 전송하지 않습니다.'
    return 0
  fi
  key=$(slot_key "$epoch" "$slot")
  if ! read_limits; then log '상태 조회 실패. 전송하지 않습니다.'; return 0; fi
  state=$(classify "$(date +%s)")
  log "예약 $key / 창 상태: $state / $(window_details)"
  [[ $state == inactive ]] || return 0
  account=$(jq -r '.accountId // empty' <<< "$LIMITS")
  [[ $account =~ ^[a-zA-Z0-9_-]+$ ]] || { log '계정 ID를 확인하지 못해 전송하지 않습니다.'; return 0; }
  if [[ $dry == dry ]]; then log 'DRY RUN: 이 조건에서는 질문을 1회 전송합니다.'; return 0; fi
  send_ping "$key" "$account"
}
main() {
  local previous_slot='' current_slot=''
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  load_config
  case ${1:-status} in
    status)
      log "예약: $START_TIMES / 휴식: $QUIET_START~$QUIET_END"
      read_limits || die '사용량을 조회할 수 없습니다. codex login 상태를 확인하세요.'
      log "5시간 창: $(classify "$(date +%s)") / $(window_details)"
      show_limits ;;
    dry-run) tick dry ;;
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
    *) die '사용법: scheduler.sh {status|dry-run|once|run}' ;;
  esac
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
