<!-- 하네스 배포 패키지 설치·사용 안내 및 보안 고지 문서 -->
# Claude Code 하네스 배포 패키지

WSL2 와 일반 Linux(사용자 공간 설치, sudo 불필요)에서 쓰는 Claude Code 오케스트레이션 하네스입니다.
o시리즈 파이프라인(oplan → odev → otest → odone → ofinish), 물리 차단 hook 묶음,
파일 I/O 전담 `oio` MCP 서버를 하나의 플러그인으로 묶어 배포합니다.

---

## ⚠️ 보안 고지 — 반드시 읽으세요

이 패키지의 `cc` / `ccc` / `cas` 는 Claude Code 를
**`--dangerously-skip-permissions` 모드로 실행합니다.**

### 무슨 뜻인가

모든 파일 읽기 / **쓰기** / **삭제**와 셸 명령이 **확인 없이 즉시 실행**됩니다.
평소 Claude Code 가 보여주는 "이 파일을 수정할까요?", "이 명령을 실행할까요?" 같은
**승인 프롬프트가 전부 건너뛰어집니다.**

하네스가 다수의 hook 과 팀에이전트를 자동 운용하기 위한 설계상의 선택입니다.
매 동작마다 승인을 누르면 파이프라인이 성립하지 않기 때문입니다.

### 어디에 적용되어 있는가 (실측)

| 실행 경로 | 플래그 적용 | 근거 |
|---|---|---|
| `cc` | **적용됨** | `bin/cc` 에서 `cas` 호출 시 플래그를 직접 주입 |
| `ccc` | **적용됨 (간접)** | 전문이 `exec cc "$@" --continue` — `cc` 경유라 상속 |
| `cas` (`claude-as`) | **적용됨** | 배포본에서 멱등 주입 로직을 추가 (중복 주입 방지) |

### 위험

- 잘못된 지시 한 줄로 파일이 삭제될 수 있습니다.
- 신뢰할 수 없는 저장소·문서·웹페이지를 다루면 프롬프트 인젝션 피해가 **승인 없이** 실현됩니다.
- **중요한 작업은 반드시 git 으로 버전 관리되는 디렉토리에서 하세요.**

### 비활성화 방법

**① `cas` 직접 호출만 안전 모드로 (환경변수)**

```bash
export HARNESS_SAFE_MODE=1
cas <프로파일명>
```

`claude-as` 의 플래그 주입이 생략됩니다. 영구 적용은 `~/.bashrc` 에 위 `export` 를 추가하세요.

**② `cc` / `ccc` 까지 완전 비활성화 (스크립트 편집 — 필수)**

`HARNESS_SAFE_MODE` 는 `claude-as` 의 주입만 막습니다.
`cc` 는 플래그를 **자기 명령줄에 직접 써 넣으므로** 환경변수로는 막히지 않습니다.
`bin/cc` 에서 `cas` 를 호출하는 마지막 줄의 `--dangerously-skip-permissions` 토큰을 지우세요.

```diff
- cas "$SELECTED" "${SESSION_ARGS[@]}" --model "$_MODEL_ARG" --dangerously-skip-permissions 2> >(...)
+ cas "$SELECTED" "${SESSION_ARGS[@]}" --model "$_MODEL_ARG" 2> >(...)
```

`ccc` 는 `cc` 를 그대로 호출하므로 위 한 곳만 고치면 함께 해제됩니다.

**③ 순정 Claude Code 사용**

```bash
claude
```

> 단, ①②③ 어느 경우든 팀에이전트 파이프라인 일부가 승인 대기로 멈출 수 있습니다.
> 하네스는 무승인 실행을 전제로 설계되어 있습니다.

### 그 밖의 고지

- **WSL2 + 일반 Linux** 를 지원합니다. macOS 는 지원하지 않습니다.
  일반 Linux 에서는 WSL 전용 기능(`oss` 스크린샷, Windows 알림, `clip.exe` 클립보드)이 비활성입니다.
- `settings.json` 에 `skipDangerousModePermissionPrompt: true` 가 없으면 추가됩니다(기존 키는 덮어쓰지 않고 원본은 `settings.json.bak.<시각>` 으로 백업).
- 설치 시 `~/.bashrc`·로그인 셸 파일(`~/.bash_profile` 또는 `~/.profile`)·`~/.tmux.conf` 의 표식 블록,
  `~/.local/bin`, `<프로젝트홈>/AI` 와 그 안의 `.harness`(= `$HARNESS_HOME`), `$HARNESS_PROFILES_ROOT`(기본 `~/.claude-profiles`),
  `~/.config/claude-harness/project_home`, `~/.claude/rules` 를 생성·수정합니다.
- `install.sh` 는 **sudo·apt 를 쓰지 않습니다.** 도구 설치는 `install_harness.sh` 가 맡습니다.
  sudo 는 사용자 공간 설치로 안 될 때만, 대화 모드에서 명령을 보여 주고 y/N 동의를 받은 뒤에만 씁니다(`--no-sudo` 면 아예 쓰지 않음).

---

## 전제 조건

필요한 도구는 설치 스크립트(`install_harness.sh`)가 점검하고, 없으면 설치를 제안합니다(배포 repo 루트 `requires.txt` 가 목록의 정본입니다).

| 항목 | 요구사항 | 비고 |
|---|---|---|
| OS | **WSL2 또는 일반 Linux** | 일반 Linux 에서는 Windows 연동 기능만 비활성 |
| git | 필수 | 배포본 clone / 갱신 |
| python3 + venv | 필수 (3.10 이상) | `oio` MCP 서버 구동용. 3.10 미만이면 설치가 rc=4 로 멈춥니다 |
| tmux · jq · curl 또는 wget | 필수 | 팀에이전트가 tmux pane 에 spawn 됩니다 |
| Claude Code (`claude`) | 필수 | 없으면 공식 네이티브 설치(`curl -fsSL https://claude.ai/install.sh \| bash`)를 제안합니다 |
| Node.js | 필수 (18.18 이상) | codex 플러그인 companion 실행용. 없거나 낮으면 nodejs.org 공식 바이너리를 `~/.local/share/node` 에 받습니다 |
| Codex CLI (`codex`) | 필수 | 없으면 공식 설치(`curl -fsSL https://chatgpt.com/codex/install.sh \| sh`)를 제안합니다 |

---

## 설치

### 새 머신 — 설치 스크립트 파일 전달 (권장)

`install_harness.sh` 파일 하나를 새 머신에 복사(scp·USB 등)한 뒤 실행하면 됩니다. 배포 저장소 주소와 기본 판은 스크립트에 내장돼 있습니다. 처음에 프로젝트 홈 폴더를 한 번 묻습니다(기본 `$HOME/Project`). 그 아래 `AI` 폴더가 하네스의 정본 자리가 됩니다.

```bash
bash install_harness.sh
```

대안(비권장): `curl -fsSL https://raw.githubusercontent.com/kHeroBite/claude-harness/master/install_harness.sh | sh`. 구 이름 `install-online.sh` 도 호환 래퍼로 남아 있습니다(다음 메이저에서 제거 예정).

- 폴더 질문은 터미널(`/dev/tty`)에서 받습니다. 터미널이 없으면 비대화로 진행합니다.
- 주요 인자: `--home <프로젝트홈>`(질문 생략), `--non-interactive`, `--yes`(동의 질문에 자동 예), `--no-sudo`(sudo 를 전혀 쓰지 않음), `--no-plugin`, `--no-rc`, `--repo-url <URL>`, `--ref <태그|브랜치>`. 인자는 `bash install_harness.sh --home ~/Project --yes --no-sudo` 처럼 넘깁니다.
- 이미 설치된 머신에서 다시 실행하면 새로 설치하지 않고 `oUpdate` 갱신으로 처리합니다.

설치 스크립트가 하는 일은 다음과 같습니다.

1. **도구 점검·설치** — 시스템에 있으면 그대로 씁니다. 없으면 sudo 없이 사용자 공간 설치를 먼저 시도하고, 그래도 안 되면 패키지 관리자 명령을 보여 주고 y/N 으로 묻습니다. 비대화 모드는 sudo 를 시도하지 않고 누락 목록과 명령만 출력합니다(rc=3). 결과표에 도구별로 `system | user | sudo | missing` 를 표시합니다.
   - **Claude Code·Codex·Node.js 도 자동 설치 대상**입니다. 외부 설치 스크립트를 실행하므로 대화 모드는 y/N 동의를 받고, 비대화 모드는 `--yes` 가 있을 때만 실행합니다.
2. 배포 repo 를 `<프로젝트홈>/AI/.harness/src` 에 clone 하고, `oUpdate` 로 첫 판을 `releases/` 에 풀어 `active` 링크를 겁니다.
3. `oio` venv 를 만들고 `install.sh` 를 실행합니다(아래 "install.sh 가 하는 일").
4. **플러그인 연결** — `claude` 가 있으면 하네스 플러그인(`harness@harness-marketplace`)과 codex 플러그인(`codex@openai-codex`, 마켓플레이스 `openai/codex-plugin-cc`)을 등록합니다. 이미 있으면 건너뜁니다. 실패하거나 `--no-plugin` 이면 다시 실행할 명령을 출력합니다.

```bash
claude plugin marketplace add openai/codex-plugin-cc && claude plugin install codex@openai-codex
```

### 로그인은 직접 해야 합니다

계정 인증은 자동화하지 않습니다(자동화할 수 없습니다). 설치가 끝나면 아래를 직접 실행하세요.

1. 새 셸을 열거나 `exec $SHELL -l` 을 실행합니다. 이미 열린 셸에는 PATH 가 바로 반영되지 않습니다.
2. `claude` 를 실행한 뒤 `/login` 으로 로그인합니다.
3. `codex login` 으로 Codex 에 로그인합니다(ChatGPT 계정 또는 API 키).
4. Claude Code 안에서 `/codex:setup` 으로 codex 연결 상태를 확인합니다.
5. `cas create default` 로 프로필을 만들고 `cc` 로 시작합니다.

### AI 정본 폴더와 ocopy

- `<프로젝트홈>/AI` 가 이 머신의 하네스 정본 자리입니다. `cc ai` 로 열립니다. 스킬·hook·scripts 는 `.harness/active` 를 가리키는 링크라 직접 고치지 않습니다.
- 새 프로젝트에 하네스 공용 파일을 연결하려면 그 프로젝트에서 `/ocopy` 를 씁니다. 링크는 AI 정본 폴더를 가리킵니다.
- 프로젝트 홈은 `~/.config/claude-harness/project_home` 에 1줄로 기록됩니다. `cc <이름>` 은 `<프로젝트홈>/<이름>` 을 엽니다(대소문자 무시).

### 수동 설치 — 플러그인만 (참고)

Claude Code 안에서 실행합니다.

```
/plugin marketplace add <배포 repo URL 또는 로컬 경로>
/plugin install harness
```

> 이 방법만으로는 `bin`(`cc`/`ccc`/`lcc`/`lccc`/`cas`)과 `oio` venv 가 설치되지 않습니다.
> 1줄 설치가 정식 설치입니다.

### install.sh 옵션과 환경변수

| 이름 | 기본값 | 용도 |
|---|---|---|
| `HARNESS_HOME` | rc 표식 블록 값 → `~/.harness` | 하네스 내부 루트(1줄 설치는 `<프로젝트홈>/AI/.harness`) |
| `HARNESS_AI_ROOT` | rc 표식 블록 값 → `HARNESS_HOME` 의 부모(`<AI>/.harness` 꼴일 때) | AI 정본 폴더 |
| `CLAUDE_PROJECT_ROOTS` | rc 표식 블록 값 → `project_home` 파일 첫 줄 | 프로젝트 홈(`cc <이름>` 해석) |
| `--no-rc` | — | 셸 rc 파일을 고치지 않음 |
| `HARNESS_PROFILES_ROOT` | `~/.claude-profiles` | `cc`/`cas` 프로필 루트. 셸에는 `CLAUDE_PROFILES_ROOT` 로 기록됨 |
| `HARNESS_PROJECT_ROOTS` | (자동 판별) | `oio` 허용 프로젝트 루트(아래 "프로젝트 경로 설정") |
| `--non-interactive` | — | 질문 없이 진행(표준입력이 터미널이 아니어도 자동 적용) |
| `--link-skills` | — | 플러그인 스킬을 `~/.claude/skills/<이름>` 으로 링크해 `/ok` 처럼 접두어 없이 호출(기존 실제 디렉터리는 건드리지 않음) |

`install.sh` 가 하는 일은 다음과 같습니다(모두 멱등).

- `$HARNESS_HOME/current` → 설치된 플러그인 루트 링크(이후 갱신은 SessionStart hook 이 맡음)
- `cc`/`ccc`/`lcc`/`lccc`/`claude-as`/`cas` 를 `$HARNESS_HOME/bin` 과 `~/.local/bin` 에 링크.
  `$HARNESS_HOME/active/bin` 이 있으면 그곳을 가리킵니다(`oUpdate` 가 active 만 바꾸면 새 판이 적용됨).
  `~/.local/bin` 에 다른 프로그램이 둔 파일·링크가 있으면 덮어쓰지 않고 SKIP 으로 표시합니다
- `~/.bashrc` 와 로그인 셸 파일에 `# >>> harness PATH` 표식 블록 기록(원본은 `.bak.<시각>` 백업):
  `export HARNESS_HOME=…`, `export CLAUDE_PROFILES_ROOT=…`, `export HARNESS_AI_ROOT=…`, `export CLAUDE_PROJECT_ROOTS=…`,
  PATH 추가(`~/.local/bin` 줄은 PATH 에 없을 때만, 재실행 시 블록을 교체)
- AI 정본 폴더를 `harness_ai_root.py ensure` 로 맞춤(빈 폴더이거나 하네스 표식이 있을 때만. 배포자의 실제 정본 폴더는 건드리지 않음)
- 끝에 항목별 결과표(✅ 성공 · ⏭️ 건너뜀 · ❌ 실패)와 `exec $SHELL -l` 안내를 출력
- `~/.tmux.conf` 에 `# >>> harness tmux` 표식 블록으로 `source-file "$HARNESS_HOME/current/tmux/tmux.conf"` 1줄 연결(기존 내용 보존)
- `oio` venv 를 `$HARNESS_HOME/venv/oio` 에 생성. `HARNESS_HOME` 이 기본값이 아니면 플러그인 `.mcp.json` 이 가리키는
  `~/.harness/venv` → `$HARNESS_HOME/venv` 호환 링크를 만듦
- `${CLAUDE_CONFIG_DIR:-~/.claude}/settings.json` 과 각 프로필의 `settings.json` 에 `statusLine`·`skipDangerousModePermissionPrompt`·
  `enabledPlugins` 의 harness 항목을 **없을 때만** 추가

### 일반 Linux 서버 설치 (사용자 공간, sudo 없음)

공용 서버처럼 root 권한이 없는 계정에서는 1줄 설치에 `--no-sudo` 를 붙이는 것이 기본입니다(예: `bash install_harness.sh --home /data/me/Project --yes --no-sudo`).
아래는 예전(레거시) 수동 설치 절차입니다. 이렇게 설치한 머신은 첫 `/oUpdate` 때 새 레이아웃(`<프로젝트홈>/AI/.harness`)으로 옮겨집니다. tmux·python3·git 은 미리 있어야 합니다.

```bash
# 1) Claude Code 설치 (공식 설치 스크립트 — 사용자 홈에 설치됨)
curl -fsSL https://claude.ai/install.sh | bash

# 2) 하네스 받기 + 설치 (경로는 예시 — 원하는 위치로 바꾸세요)
git clone <배포 repo URL> /data/me/claude/harness/src
HARNESS_HOME=/data/me/claude/harness \
HARNESS_PROFILES_ROOT=/data/me/claude/profiles \
  bash /data/me/claude/harness/src/install.sh --non-interactive

# 3) 플러그인 등록 (비대화 CLI)
claude plugin marketplace add /data/me/claude/harness/src
claude plugin install harness@harness-marketplace

# 4) 새 로그인 셸에서 프로필 생성 — 로그인(브라우저 OAuth)은 사용자가 직접 진행
cas create default
```

- 홈 디렉터리 용량이 작으면 `~/.local/share/claude`·`~/.claude` 를 큰 디스크로 심볼릭링크한 뒤 1) 을 실행하세요.
- 로그인 셸(`bash -l`)과 대화형 셸 모두에서 `HARNESS_HOME`·`CLAUDE_PROFILES_ROOT` 가 잡히도록 두 파일에 같은 블록을 씁니다.
- WSL 전용 기능(`oss`, Windows 알림, `clip.exe` 클립보드)은 일반 Linux 에서 동작하지 않습니다(tmux 복사는 버퍼에만 남음).

### 다른 머신의 세션과 협업 (ssh + git)

- 코드는 **git** 으로 동기화합니다. 양쪽 모두 같은 원격에 push/pull 하고, 작업 전에 fetch/rebase 합니다.
- `ListAgents`/`SendMessage` 세션 간 통지는 **같은 머신 안 세션끼리만** 닿습니다. 하네스의 `cc`/`ccc` 는 Remote Control 을 켜지 않습니다.
- 다른 머신 세션에는 ssh 통지 스크립트로 작업 시작·종료를 알립니다. 본문은 표준입력으로만 넘기며, 받은 쪽은 수신함 파일에 데이터로만 기록합니다.

```bash
# 보내기 (ssh 별칭은 ~/.ssh/config 의 Host 이름)
echo "api 모듈 수정 시작" | bash "$HARNESS_HOME/current/scripts/peer_ssh_notify.sh" send my-server MyProject 작업시작
# 내 수신함 읽기
bash "$HARNESS_HOME/current/scripts/peer_ssh_notify.sh" read MyProject
```

- 상대 머신으로 ssh 가 안 되는 방향(예: 서버 → WSL)은 `send --outbox` 로 자기 outbox 에 적고, 반대편이 `pull` 로 가져옵니다.
- 실시간 대화형 왕복이 꼭 필요하면 세션 안에서 `/remote-control` 로 수동으로 켤 수 있습니다(https://code.claude.com/docs/en/remote-control).

### 설치 후 필수 1단계 — 규칙 문서 연결

프로젝트 `CLAUDE.md` 에 아래 **한 줄**을 추가하세요.

```
@~/.claude/rules/harness.md
```

- 이 파일은 SessionStart hook 이 플러그인 안의 `rules/harness.md` 로부터 **자동 동기화**합니다.
  플러그인이 갱신되면 규칙도 함께 갱신됩니다.
- 플러그인 캐시 경로는 버전마다 바뀌기 때문에 고정 경로(`~/.claude/rules/`)를 경유하는 구조입니다.
- **하네스는 여러분의 `CLAUDE.md` 를 읽지도 쓰지도 않습니다.** 위 한 줄은 직접 추가해 주세요
  (자동 삽입은 파일 파괴 위험이 있어 의도적으로 금지했습니다).

### 첫 실행

```bash
cc
```

프로파일이 하나도 없으면 `cc` 가 종료됩니다. `install.sh` 는 프로파일을 만들지 않고 안내만 하므로,
먼저 `cas create default` 로 만들고 1회 로그인하세요.

> **tmux 안에서 실행하는 것을 권장합니다.** 팀에이전트는 tmux pane 에 spawn 되며,
> tmux 세션 밖에서는 pane 생성이 실패할 수 있습니다.

---

## 업데이트

설치된 머신은 Claude Code 안에서 **`/oUpdate`** 를 실행합니다(`/oDownload` 는 같은 일을 하는 옛 이름입니다).

```
/oUpdate
```

`oUpdate` 는 먼저 `status` 로 새 판이 있는지 보고, `apply` 로 적용합니다. 새 판을 임시 폴더에 풀어 검사한 뒤
`releases/<판>` 에 두고 `active` 링크 하나를 원자적으로 바꿉니다. 판을 여러 개 건너뛰어도 사이의 변경을 한 번에 적용합니다.
문제가 생기면 `rollback` 으로 직전 판에 돌아갑니다.

결과 상태는 다음과 같습니다.

| 상태 | 뜻 | 할 일 |
|---|---|---|
| `OK` / `UP_TO_DATE` | 적용 완료 / 이미 최신 | 없음 |
| `NEEDS` (rc=6) | 새 판에 필요한 도구(claude·node·codex 등)가 없음. 현행 유지 | 출력된 설치 명령을 실행하거나 `apply --yes` 로 다시 실행 |
| `BREAKING` (rc=7) | 큰 변경이 있어 확인이 필요함. 비대화 실행은 여기서 멈춤 | 요약을 읽고 동의하면 `apply --accept-breaking` |
| `PARTIAL` (rc=5) | 하네스는 갱신됐지만 플러그인 쪽 일부가 남음 | 출력된 안내대로 플러그인 갱신 |
| `REFUSE` (rc=3) | 이 머신이 정본(배포자) 머신이거나 실디렉터리를 덮으려 함 | 정본 머신은 `/oUpload` 를 씀 |

- **post_actions** — 판마다 갱신 뒤 할 일(새 셸 열기, `cc` 다시 시작, 플러그인 다시 불러오기 등)을 `해야 할 일:` 로 출력합니다. oUpdate 는 안내만 하고 자동으로 실행하지 않습니다.
- 실행 중인 세션은 건드리지 않습니다. `cc`·`ccc`·`lcc`·`cas` 와 rc 블록 변경은 **새로 여는 셸·세션부터** 적용됩니다.

> ⚠️ 지금 도는 Claude Code 는 구(舊) 런처가 띄운 프로세스입니다. 종료 후 `cc` 를 다시 실행하세요.

### 정본(배포자) 머신

AI 정본 저장소가 있는 배포자 머신에서는 `oUpdate` 를 쓰지 않습니다(REFUSE). 배포는 **`/oUpload`** 로 합니다.
`/oUpload` 는 배포본 빌드 → 자격증명 스캔 게이트 → `plugin.json`·`marketplace.json` version 범프 → `RELEASE.json` 작성·검사 → 커밋·태그 → push 까지 진행합니다.
다른 머신은 그다음 `/oUpdate`(이미 설치된 머신) 또는 1줄 설치(새 머신)로 받습니다.

---

## 주의사항

### 환경 전제에 의존하는 기능

아래 기능은 이 환경 전제(WSL2 + tmux + 무승인 실행)에 의존합니다. 전제가 깨지면 동작하지 않습니다.

- **팀에이전트** — `tmux` pane 에 spawn 됩니다. tmux 부재 또는 tmux 세션 밖 실행 시 실패할 수 있습니다.
- **tmux pane 관리 기능** (`oinit` / `ofinish` 의 pane 진단·정리) — tmux 전용입니다.
- **파이프라인 자동 진행** (`ofinish autoloop`, `oralph` 반복 루프) — 무승인 실행을 전제로 합니다.
  안전 모드에서는 승인 대기로 멈출 수 있습니다.
- **Windows 연동 스킬** (`oss` 스크린샷, `otest_winforms`, `otest_mobile`) — `/mnt/c` 와 `.exe`
  호출을 사용합니다. WSL2 밖에서는 동작하지 않습니다.

### 선택 의존 (없어도 나머지는 정상 동작)

| 필요한 것 | 이것을 요구하는 스킬 | 미설치 시 |
|---|---|---|
| MySQL MCP | `domain-database`, `otest_make` | 해당 스킬만 미동작 |
| Codex CLI + codex 플러그인 | `oplan_consult`, `oplan_debate`, `oguard`, `codex:adversarial-review` 를 쓰는 단계 | 1줄 설치가 함께 설치·연결합니다. 빠지면 해당 단계만 미동작(`oplan_deep` 으로 대체) |
| context7 MCP | `domain-context7` | 해당 스킬만 미동작 |
| ADB | `otest_mobile` | 해당 스킬만 미동작 |

선택 MCP 는 **여러분의 `.mcp.json`** 에 직접 추가하세요.
배포본 `.mcp.json` 에는 `oio` 만 등록되어 있습니다 (자격증명 유출 방지).

### 프로젝트 경로 설정

`oio` MCP 서버는 파일 I/O 를 **허용된 루트 안으로만** 제한합니다. 실수로 시스템 파일을
건드리는 것을 막는 안전장치입니다. 이 목록은 다음 순서로 결정됩니다.

| 순위 | 수단 | 동작 |
|---|---|---|
| 1 | `FILEOPS_ALLOWED_ROOTS` | 목록 **전체**를 직접 지정합니다. 홈·`/tmp` 도 자동 추가되지 않습니다. |
| 2 | `HARNESS_PROJECT_ROOTS` | **프로젝트 루트만** 콤마로 지정합니다. 홈과 `/tmp` 는 자동 포함됩니다. |
| 3 | 자동 판별 | `CLAUDE_PROJECT_DIR` → 현재 작업 디렉토리 순으로 프로젝트 루트를 잡습니다. |

**대부분의 경우 아무 설정도 필요 없습니다.** 프로젝트 디렉토리에서 `cc` 를 실행하면
3번 자동 판별이 그 디렉토리를 허용 루트로 잡습니다. 프로젝트를 `/mnt/d/work/myapp` 에
두든 `~/projects/api` 에 두든 그대로 동작합니다.

여러 위치의 프로젝트를 오가는 경우에만 선언하세요.

```bash
export HARNESS_PROJECT_ROOTS="/mnt/d/work,/mnt/c/src"
```

`install.sh` 가 설치 중에 이 값을 물어보고 `~/.bashrc` 에 기록합니다. 그냥 Enter 를
누르면 자동 판별을 사용합니다.

> **보안 하한선 — 광역 경로는 열리지 않습니다.**
> `/` · `/mnt` · `/mnt/c` · `/home` 처럼 최상위에 가까운 경로는 `HARNESS_PROJECT_ROOTS`
> 로 명시해도, 자동 판별로도 **거부**됩니다. 이 경우 홈과 `/tmp` 만 남습니다(fail-safe).
> 정말로 필요하다면 1순위인 `FILEOPS_ALLOWED_ROOTS` 로 직접 지정해야 하며,
> 그때의 위험은 사용자 책임입니다.

허용되지 않은 경로에 접근하면 `PATH_NOT_ALLOWED` 오류와 함께 현재 허용 목록이
표시되므로, 오류 메시지를 보고 위 환경변수를 조정하면 됩니다.

### 프로젝트별 인프라 설정

빌드·배포·헬스체크 명령은 프로젝트마다 다르므로 배포본에 포함되어 있지 않습니다.
`oinfra_template` 스킬을 `oinfra_<내프로젝트>` 로 복사해 채우세요.
**채우기 전에는 `otest_build` / `otest_run` 이 동작하지 않습니다.**

### 한국어 전제

하네스는 한국어 응답·주석·커밋 메시지를 전제로 작성되어 있습니다.
다른 언어를 쓰려면 `~/.claude/rules/harness.md` 의 "언어 정책" 절을 여러분의 `CLAUDE.md` 에서
덮어쓰면 됩니다. 나머지 규칙은 그대로 동작합니다.

---

## 배포 전 자격증명 점검 (배포자용)

```bash
bash scripts/credential_scan.sh
```

- 발견 0건이면 `exit 0`, 1건 이상이면 `exit 1` + **파일:줄번호만** 출력합니다
  (자격증명 값 자체는 출력하지 않습니다).
- `scripts/pre-commit` 을 `.git/hooks/pre-commit` 에 링크하면 커밋이 **물리 차단**됩니다.

```bash
ln -sfn "$(git rev-parse --show-toplevel)/scripts/pre-commit" \
        "$(git rev-parse --git-dir)/hooks/pre-commit"
```

`.git/hooks` 는 clone 으로 전파되지 않으므로, `/oUpload` 가 매 실행마다 배선 여부를 확인합니다.

---

## 제거

`docs/UNINSTALL.md` 를 참조하세요.
`~/.claude-profiles` 는 사용자 데이터이므로 제거 절차에서 삭제하지 않습니다.
