# 안녕하세요
지피티 5시간 초기화 시간을 설정하기 위해 만들었습니다.
홈서버로 사용하는 라즈베리파이에 Codex CLI만 설치해 사용하려 합니다.

노트북을 쓰시는 분들은 Sleep 모드에 들어가게 되면 제대로 동작이 안 될 수 있습니다;


## 기술 요약

Linux와 macOS에서 Bash + jq로 동작하며, ChatGPT로 로그인한 Codex CLI가 필요합니다.

### 사용법

```sh
./scheduler.sh status    # 계정 상태 조회 (질문 없음)
./scheduler.sh dry-run   # 현재 예약 조건 확인 (질문 없음)
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

1. `codex app-server`의 `account/rateLimits/read`에서 `LIMIT_ID` 버킷의 `windowDurationMins == 300` 창을 찾습니다.
2. 아래 기준으로 판정합니다.
   - `resetsAt > 현재`: 활성. 잔여량이 100%여도 대기합니다.
   - 유효한 `resetsAt <= 현재`: 비활성으로 추정하고 예약 시간에 1회 전송합니다.
   - 창이나 시각이 없거나 조회에 실패: 불명. 전송을 보류합니다.
   - 주간 한도 등 다른 창이 소진됐거나 서버가 사용을 막음: 전송을 보류합니다.
3. 활성 여부를 나타내는 boolean이 API에 없어서, 서버가 준 초기화 시각으로 추정합니다. 이미 활성인 창을 강제로 초기화하지는 않습니다.

### 중복 방지

- 전송 직전에 `.state/attempts/<계정>/<예약>`에 기록을 남깁니다. 실패나 시간 초과여도 같은 예약은 재전송하지 않습니다.
- 전송 후 사용량을 다시 조회해 결과를 기록합니다. `sent observed=active`면 활성 전환을 확인한 것입니다.
- 동시 실행은 `.state/lock`으로 막습니다. 강제 종료 후 잠금이 남았다면 `lock/pid`의 프로세스가 종료됐는지 확인한 뒤 잠금 디렉터리만 지우세요. `.state/attempts`를 지우면 중복 방지 기록도 사라집니다.
- 조회만으로는 모델을 호출하지 않고, 무료 초기화 크레딧도 쓰지 않습니다.

공식 프로토콜: https://learn.chatgpt.com/docs/app-server
