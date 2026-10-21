# 안녕하세요
지피티 5시간 초기화 시간을 설정하기 위해 만들었습니다.
홈서버로 사용하는 라즈베리파이에 Codex CLI만 설치해 사용하려 합니다.

노트북을 쓰시는 분들은 Sleep 모드에 들어가게 되면 제대로 동작이 안 될 수 있습니다;


## 기술 요약

Linux와 macOS에서 Bash로 동작하며 (macOS 서비스 등록에는 jq 필요), ChatGPT로 로그인한 Codex CLI가 필요합니다.

### 사용법

```sh
./scheduler.sh dry-run   # 지금 전송 대상인지 확인 (질문 없음)
./scheduler.sh run       # 계속 감시 (Ctrl+C로 중단)

./service.sh install     # Linux: systemd 사용자 서비스 / macOS: LaunchAgent
./service.sh status | logs | uninstall
```

Linux에서 로그아웃 후에도 유지하려면 `sudo loginctl enable-linger "$USER"`를 한 번 실행합니다.
테스트는 `./test.sh`입니다. 가짜 CLI를 쓰므로 실제 질문은 나가지 않습니다.

### 설정 (`schedule.conf`)

서버 로컬 시간 기준이고, 수정하면 다음 확인 주기부터 반영됩니다. Shell 코드이므로 신뢰할 수 있는 내용만 넣으세요.

| 항목 | 기본값 | 설명 |
| --- | --- | --- |
| `START_TIMES` | `09:00 14:00 19:00 00:00` | 예약 시각 |
| `QUIET_START` / `QUIET_END` | `05:00` / `09:00` | 이 시간에는 자동 질문 중단 (사용자의 직접 질문에는 영향 없음) |
| `START_GRACE_MINUTES` | `10` | 예약 시각 이후 이 시간 동안만 시작 시도. 넘기면 다음 예약까지 대기 |
| `CHECK_INTERVAL_SECONDS` | `15` | 상태 확인 주기 |

### 동작 방식

창 상태(활성/비활성)는 보지 않습니다. 서버가 창이 시작되지 않았을 때도 `resetsAt`을 `지금 + 5시간`으로 내려줘서 활성 여부를 신뢰할 수 없기 때문입니다.
예약 시각이 되면 `START_GRACE_MINUTES` 안에서 질문을 예약당 1회 전송합니다. 휴식 시간에는 전송하지 않습니다.

### 중복 방지

- 전송 직전에 `.state/attempts/<예약>`에 기록을 남깁니다. 실패나 시간 초과여도 같은 예약은 재전송하지 않습니다.
- 동시 실행은 `.state/lock`으로 막습니다. 강제 종료 후 잠금이 남았다면 `lock/pid`의 프로세스가 종료됐는지 확인한 뒤 잠금 디렉터리만 지우세요. `.state/attempts`를 지우면 중복 방지 기록도 사라집니다.
- `dry-run`은 모델을 호출하지 않습니다.

공식 프로토콜: https://learn.chatgpt.com/docs/app-server
