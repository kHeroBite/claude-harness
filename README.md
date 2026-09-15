<!-- 하네스 배포 패키지 설치·사용 안내 및 보안 고지 문서 -->
# Claude Code 하네스 배포 패키지

WSL2 전용 Claude Code 오케스트레이션 하네스입니다.
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
- cas "$SELECTED" $CONTINUE_FLAG --dangerously-skip-permissions --remote-control 2> >(...)
+ cas "$SELECTED" $CONTINUE_FLAG --remote-control 2> >(...)
```

`ccc` 는 `cc` 를 그대로 호출하므로 위 한 곳만 고치면 함께 해제됩니다.

**③ 순정 Claude Code 사용**

```bash
claude
```

> 단, ①②③ 어느 경우든 팀에이전트 파이프라인 일부가 승인 대기로 멈출 수 있습니다.
> 하네스는 무승인 실행을 전제로 설계되어 있습니다.

### 그 밖의 고지

- **WSL2 전용**입니다. macOS / 네이티브 Linux 는 지원하지 않습니다.
- `settings.json` 에 `skipDangerousModePermissionPrompt: true` 가 포함됩니다.
- 설치 시 `~/.bashrc`, `~/.local/bin`, `~/.claude-profiles`, `~/.harness`, `~/.claude/rules`
  를 생성·수정합니다.
- `tmux` 를 `apt` 로 설치합니다 (**sudo 필요**).

---

## 전제 조건

| 항목 | 요구사항 | 비고 |
|---|---|---|
| OS | **WSL2 전용** | `/mnt/c`, `.exe` 호출, NTFS 전제 코드가 다수 포함됨 |
| tmux | **필수** | 팀에이전트가 tmux pane 에 spawn 됨. `install.sh` 가 자동 설치 |
| python3 + venv | 필수 | `oio` MCP 서버 구동용 |
| git | 필수 | 배포본 clone / 갱신 |
| Claude Code | 최신 버전 권장 | 플러그인·팀에이전트 기능 사용 |

---

## 설치

### 방법 1. git clone + install.sh (권장)

```bash
git clone <배포 repo URL> ~/claude-harness
cd ~/claude-harness
bash install.sh
source ~/.bashrc
```

`install.sh` 는 **멱등**합니다. 몇 번 실행해도 안전합니다.

### 방법 2. 마켓플레이스 등록 (플러그인만)

Claude Code 안에서 실행합니다.

```
/plugin marketplace add <배포 repo URL 또는 로컬 경로>
/plugin install harness
```

> 방법 2 만으로는 `bin` 3종(`cc`/`ccc`/`cas`)과 `oio` venv 가 설치되지 않습니다.
> **두 방법을 모두 수행하는 것이 정식 설치입니다.**

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

프로파일이 하나도 없으면 `cc` 가 종료되므로, `install.sh` 가 `default` 프로파일을 자동 생성합니다.
직접 만들려면 `cas create <이름>` 을 사용하세요.

> **tmux 안에서 실행하는 것을 권장합니다.** 팀에이전트는 tmux pane 에 spawn 되며,
> tmux 세션 밖에서는 pane 생성이 실패할 수 있습니다.

---

## 업데이트

갱신 경로가 **두 축으로 분리**되어 있습니다. 이 구분이 중요합니다.

| 대상 | 갱신 방식 |
|---|---|
| 플러그인 본체 (스킬 / hook / `rules/harness.md` / `oio` MCP) | **마켓플레이스가 자동갱신** (최대 10분 내 전파). 즉시 반영은 `/reload-plugins` |
| 플러그인 바깥 (`bin` 3종, `install.sh`) | **자동갱신되지 않음** → `/oDownload` 스킬 실행 |

```
/oDownload
```

`oDownload` 는 `git pull` → `bin` 심볼릭링크 재생성 → `install.sh` 재실행을 수행합니다.

> ⚠️ **`cc` / `ccc` / `cas` 갱신분은 다음 실행부터 적용됩니다.**
> 지금 도는 Claude Code 는 구(舊) 런처가 띄운 프로세스이기 때문입니다.
> 종료 후 `cc` 를 다시 실행하세요.

배포자는 `/oUpload` 로 publish 합니다 (자격증명 스캔 게이트 + `plugin.json` version 범프 포함).

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
| Codex MCP | `oplan_consult`, `oplan_debate` | `oplan_deep` 으로 대체 사용 |
| context7 MCP | `domain-context7` | 해당 스킬만 미동작 |
| ADB | `otest_mobile` | 해당 스킬만 미동작 |

선택 MCP 는 **여러분의 `.mcp.json`** 에 직접 추가하세요.
배포본 `.mcp.json` 에는 `oio` 만 등록되어 있습니다 (자격증명 유출 방지).

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
