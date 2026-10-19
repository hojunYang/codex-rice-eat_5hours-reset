#!/bin/bash
# Auto-start service: systemd user service on Linux, LaunchAgent on macOS.
set -euo pipefail
umask 077
ROOT=$(cd "$(dirname "$0")" && pwd)
NAME=codex-rice-eat

need_tools() {
  command -v jq >/dev/null || { echo "먼저 jq를 설치하세요 ($1)."; exit 1; }
  command -v codex >/dev/null || { echo 'PATH에서 codex를 찾을 수 없습니다.'; exit 1; }
}

linux_service() {
  local unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
  local unit="$unit_dir/$NAME.service"
  case $1 in
    install)
      need_tools 'sudo apt install jq'
      [[ $ROOT != *%* && $PATH != *%* ]] || { echo '경로에 % 문자를 쓸 수 없습니다.'; exit 1; }
      [[ ! -e $unit ]] || { echo "이미 설치되어 있습니다: $unit"; exit 1; }
      mkdir -p "$unit_dir" "$ROOT/.state"
      cat >"$unit" <<UNIT_EOF
[Unit]
Description=Codex 5-hour window scheduler

[Service]
ExecStart=/bin/bash "$ROOT/scheduler.sh" run
WorkingDirectory=$ROOT
Environment="PATH=$PATH"
Restart=always
RestartSec=60

[Install]
WantedBy=default.target
UNIT_EOF
      systemctl --user daemon-reload
      if ! systemctl --user enable --now "$NAME.service"; then
        rm -f "$unit"; systemctl --user daemon-reload; echo '서비스 등록 실패'; exit 1
      fi
      echo "자동 실행 시작. 설정: $ROOT/schedule.conf"
      echo '로그아웃 후에도 계속 돌리려면: sudo loginctl enable-linger "$USER"' ;;
    uninstall)
      [[ -f $unit ]] || { echo '설치된 서비스가 없습니다.'; exit 0; }
      systemctl --user disable --now "$NAME.service" || true
      rm -f "$unit"
      systemctl --user daemon-reload
      echo '자동 실행을 중단했습니다. 설정과 기록은 보존합니다.' ;;
    status) systemctl --user status "$NAME.service" --no-pager ;;
    logs) journalctl --user -u "$NAME.service" -f ;;
    *) usage ;;
  esac
}

mac_service() {
  local label=local.$NAME
  local plist="$HOME/Library/LaunchAgents/$label.plist"
  local domain="gui/$(id -u)"
  case $1 in
    install)
      need_tools 'brew install jq'
      mkdir -p "$HOME/Library/LaunchAgents" "$ROOT/.state"
      [[ ! -e $plist ]] || { echo "이미 설치되어 있습니다: $plist"; exit 1; }
      plutil -create xml1 "$plist"
      plutil -insert Label -string "$label" "$plist"
      plutil -insert ProgramArguments -json "$(jq -cn --arg script "$ROOT/scheduler.sh" '["/bin/bash",$script,"run"]')" "$plist"
      plutil -insert WorkingDirectory -string "$ROOT" "$plist"
      plutil -insert EnvironmentVariables -json "$(jq -cn --arg p "$PATH" '{PATH:$p}')" "$plist"
      plutil -insert RunAtLoad -bool YES "$plist"
      plutil -insert KeepAlive -bool YES "$plist"
      plutil -insert ThrottleInterval -integer 60 "$plist"
      plutil -insert StandardOutPath -string "$ROOT/.state/service.log" "$plist"
      plutil -insert StandardErrorPath -string "$ROOT/.state/service.log" "$plist"
      if ! launchctl bootstrap "$domain" "$plist"; then
        rm -f "$plist"; echo '서비스 등록 실패'; exit 1
      fi
      echo "자동 실행 시작. 설정: $ROOT/schedule.conf" ;;
    uninstall)
      [[ -f $plist ]] || { echo '설치된 서비스가 없습니다.'; exit 0; }
      launchctl bootout "$domain" "$plist"
      rm -f "$plist"
      echo '자동 실행을 중단했습니다. 설정과 기록은 보존합니다.' ;;
    status) launchctl print "$domain/$label" ;;
    logs) tail -f "$ROOT/.state/service.log" ;;
    *) usage ;;
  esac
}

usage() { echo '사용법: service.sh {install|uninstall|status|logs}'; exit 1; }

case $(uname -s) in
  Linux) linux_service "${1:-status}" ;;
  Darwin) mac_service "${1:-status}" ;;
  *) echo "지원하지 않는 OS입니다: $(uname -s)"; exit 1 ;;
esac
