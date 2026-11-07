---
name: oUpdate
description: 이 머신에 설치된 하네스를 배포 repo 의 최신판(또는 지정 판)으로 갱신하는 수신자 전용 스킬. status 로 현재·대상 판과 큰 변경·새 요구 도구·마이그레이션·해야 할 일을 먼저 보여 주고, 사용자 확인 뒤 apply 로 임시 추출 → 사전 검증 → 요구 도구 → 큰 변경 확인 → 마이그레이션 → active 원자 교체 → 사후 검증 순서로 적용한다. 실패하면 현행을 유지하거나 직전 판으로 되돌린다. 정본(배포자) 머신에서는 거부하고 /oUpload 를 안내한다. 사용자가 '/oUpdate', '하네스 업데이트', '최신판 받아', '하네스 갱신', '/oDownload' 를 요청할 때 사용.
---

# oUpdate — 하네스 최신판 받기 (수신자 전용)

> **대상 머신**: 설치 sh(`install_harness.sh`)나 레거시 설치로 하네스를 받은 머신이다.
> **정본(배포자) 머신은 대상이 아니다.** 정본 머신에서 배포는 `/oUpload` 로 한다. 엔진이 `OUPDATE REFUSE` rc=3 으로 거부하며 아무것도 바꾸지 않는다.
> **새 머신**은 이 스킬이 아니라 아래 "새 머신 설치" 의 1줄 설치를 쓴다.
> 이 스킬은 갱신 엔진 `harness_update.py` 를 부르고 결과를 사용자에게 전달한다. 엔진이 하지 않는 일(재시작·로그인·플러그인 재로드)은 안내만 한다.

---

## 0. 엔진 위치 찾기

다음 순서로 처음 찾은 파일을 쓴다. 경로를 추정하지 말고 실제로 있는지 확인한다.

1. `<AI 루트>/.claude/scripts/harness_update.py` — AI 루트는 `HARNESS_AI_ROOT` 환경변수, 없으면 `~/.config/claude-harness/project_home` 첫 줄 + `/AI` 이다.
2. `${HARNESS_HOME}/active/plugins/harness/scripts/harness_update.py`
3. `${HARNESS_HOME:-$HOME/.harness}/current/scripts/harness_update.py`

```bash
bash -c 'H="${HARNESS_HOME:-$HOME/.harness}"; A="${HARNESS_AI_ROOT:-}";
  [ -z "$A" ] && [ -f "$HOME/.config/claude-harness/project_home" ] && A="$(head -1 "$HOME/.config/claude-harness/project_home" | sed "s/[[:space:]]*$//")/AI";
  for f in "$A/.claude/scripts/harness_update.py" "$H/active/plugins/harness/scripts/harness_update.py" "${HARNESS_HOME:-$HOME/.harness}/current/scripts/harness_update.py"; do
    [ -n "$f" ] && [ -f "$f" ] && { echo "ENGINE=$f"; exit 0; }; done; echo ENGINE_NOT_FOUND; exit 2'
```

- `ENGINE_NOT_FOUND` 이면 아래 "레거시 부트스트랩" 으로 간다.
- 이하 명령의 `$ENGINE` 은 위에서 찾은 경로다. 셸은 dash 일 수 있으므로 명령은 `bash -c` 로 감싼다.

---

## 1. status — 적용 전 확인 (항상 먼저)

```bash
bash -c 'python3 -B "$ENGINE" status; echo "RC=$?"'
```

출력에서 다음을 사용자에게 그대로 보여 준다. 판정을 지어내지 않는다.
- 현재 판 → 대상 판(sha 12자), `UP_TO_DATE` 여부
- `⚠️ 큰 변경`(BREAKING) 과 그 요약
- 새 요구 도구(requires) 와 누락 여부
- 실행될 마이그레이션 id
- 해야 할 일(post_actions)

`UP_TO_DATE` 면 여기서 끝난다. 원격에 연결할 수 없으면 `--no-fetch` 로 로컬 기준 상태만 볼 수 있다.

---

## 2. apply — 적용

```bash
bash -c 'python3 -B "$ENGINE" apply --non-interactive; echo "RC=$?"'
```

| 인자 | 뜻 |
|---|---|
| `--ref R` | 특정 태그·커밋으로 적용한다. 낮은 판으로 내리는 것은 `--ref` 가 있을 때만 허용된다 |
| `--dry-run` | 바꾸지 않고 적용 계획만 출력한다 |
| `--accept-breaking` | 큰 변경을 승인한다. **사용자 확인을 받은 뒤에만** 붙인다 |
| `--non-interactive` | 질문하지 않는다. 스킬 경유 실행은 항상 이 인자를 쓴다 |
| `--yes` | 요구 도구 설치를 자동 승인한다(사용자 공간 설치, sudo 는 `sudo -n` 만) |
| `--no-sudo` | 어떤 단계에서도 sudo 를 쓰지 않는다. `--yes --no-sudo` 는 "사용자 공간 설치만 자동" 이다 |
| `--skip-plugin-update` | 플러그인 갱신을 건너뛴다(결과는 PARTIAL) |
| `--force` | 같은 판도 다시 적용한다 |
| `--ai-root P` | AI 루트를 지정한다(status·rollback·verify 도 받는다) |

`HARNESS_HOME` 을 직접 지정하려면 공통 인자 `--harness-home H` 를 하위 명령 **앞**에 둔다(예: `python3 -B "$ENGINE" --harness-home H apply --non-interactive`).

적용 순서는 엔진이 고정한다. 임시 위치 추출 → 사전 검증 → 요구 도구(requires) → 큰 변경 확인 → 마이그레이션(pre) → active 원자 교체 → 마이그레이션(post) → 사후 검증 → 해야 할 일 출력 순서다. 판을 여러 개 건너뛰어도 대상 판의 누적 기록으로 건너뛴 판의 큰 변경·마이그레이션·해야 할 일을 빠짐없이 처리한다.

### 2.1 결과 코드별 대응

결과 줄은 모두 `OUPDATE ` 로 시작한다. 요약 줄 앞에 마이그레이션 진행 줄(`  RC …`, `  M0001 OK`)이나 `⚠️ 큰 변경:` 줄이 먼저 나올 수 있으므로, 판정은 첫 줄이 아니라 `OUPDATE` 로 시작하는 요약 줄과 rc 로 한다.

| 요약 줄 / rc | 뜻 | 대응 |
|---|---|---|
| `OUPDATE OK` rc=0 | 적용·검증 통과 | 아래 "해야 할 일" 을 사용자에게 전달한다 |
| `OUPDATE UP_TO_DATE <ver> (<sha12>)` rc=0 | 이미 최신 | 끝 |
| `OUPDATE FAIL` rc=1 | 검증·마이그레이션 실패, 현행 유지 또는 직전 판으로 원복됨 | 출력 원인을 보고한다. 같은 명령 재시도 전 원인을 먼저 본다 |
| rc=2 | 전제 불충족(clone 없음·원격 실패·디스크 부족) | 원인 보고 |
| `OUPDATE REFUSE_DOWNGRADE` rc=2 | 대상 판이 현재보다 낮다 | 내려야 하면 사용자 확인 뒤 `--ref` 로 지정한다 |
| `OUPDATE REFUSE` rc=3 | 정본(배포자) 머신이거나 AI 루트가 실디렉터리이거나 `<HARNESS_HOME>/active` 가 링크가 아닌 실경로 | 정본 머신이면 `/oUpload` 를 안내하고 끝낸다. 그 밖이면 출력 원인을 보고한다 |
| `OUPDATE LOCKED` rc=4 | 다른 갱신이 진행 중 | 기다렸다가 다시 실행한다 |
| `OUPDATE PARTIAL` rc=5 | 스킬·bin 은 신판, 플러그인(hook·oio)은 구판 | 아래 2.2 |
| `OUPDATE NEEDS` rc=6 | 필수 도구 누락, 교체하지 않음 | 아래 2.3 |
| `OUPDATE BREAKING` rc=7 | 큰 변경 확인 필요(비대화) | 아래 2.4 |

### 2.2 PARTIAL (rc=5)

플러그인 갱신만 실패했다. hook·oio 는 플러그인 캐시에서 돌기 때문에 구판으로 남아 있다. 사용자에게 알리고 다음을 안내한다.

```bash
claude plugin marketplace update harness-marketplace
claude plugin update harness@harness-marketplace
```

이 머신에 harness 플러그인이 아예 없으면 엔진은 `plugin=n/a` 로 OK 를 낸다. 이것은 실패가 아니다.

### 2.3 NEEDS (rc=6) — 필수 도구 누락

NEEDS 는 새 판이 요구하는 도구가 없다는 뜻이다. 대상 도구는 git·python3(3.10 이상)·venv·tmux·jq·curl 또는 wget·claude(Claude Code)·node(18.18 이상)·codex(Codex CLI)다.
교체는 일어나지 않았다. 출력에 도구별 결과(`system | user | sudo | missing`)와 설치 명령이 함께 나온다.

- 사용자 공간 설치로 해결되는 도구(claude 네이티브 설치·node 공식 바이너리·codex 공식 standalone)는 사용자 동의 뒤 `apply --non-interactive --yes --no-sudo` 로 다시 실행한다.
- sudo 가 필요한 도구는 에이전트가 sudo 를 실행하지 않는다. 출력된 패키지 관리자 명령을 사용자에게 전달하고, 사용자가 직접 설치한 뒤 다시 실행한다.
- Claude Code 공식 설치는 `curl -fsSL https://claude.ai/install.sh | bash` 이다. `sudo npm install -g` 는 쓰지 않는다.
- codex 공식 설치는 `curl -fsSL https://chatgpt.com/codex/install.sh | sh` 이다. 대안은 `npm install -g @openai/codex` 이며 sudo 로 실행하지 않는다.
- node 가 있어도 18.18 미만이면 누락으로 친다. codex 플러그인의 companion 이 node 로 돌기 때문이다.

### 2.4 BREAKING (rc=7) — 큰 변경 확인

연쇄 범위 안에 큰 변경이 있다. 엔진이 출력한 `⚠️ 큰 변경` 요약을 그대로 사용자에게 보여 주고 진행 여부를 묻는다.
- 메인 사용자 화면 세션이면 AskUserQuestion 으로 묻는다. 승인을 받은 뒤에만 `--accept-breaking` 을 붙여 다시 실행한다.
- 자율(oto) 세션이나 팀원이면 묻지 않고 보류로 보고한다. 에이전트가 스스로 `--accept-breaking` 을 붙이지 않는다.

### 2.5 해야 할 일 (post_actions) — 안내만

`해야 할 일:` 줄은 post_actions 다. 종류는 new_shell·restart_cc·reload_plugin·note 이다. 엔진도 스킬도 **자동 실행하지 않는다.** 사용자에게 그대로 전달한다.
- `new_shell`: 새 셸을 열거나 `exec $SHELL -l` 을 실행한다.
- `restart_cc`: 열려 있는 cc 세션을 종료하고 다시 연다.
- `reload_plugin`: Claude Code 안에서 `/reload-plugins` 를 실행한다. 엔진은 `plugin=updated` 일 때 이 안내를 낸다.

실행 중인 세션에는 즉시 반영되지 않는다. 플러그인을 갱신해도 실행 중 세션은 이미 적재한 판을 유지하고, 새 판은 `/reload-plugins` 를 실행하거나 다음에 기동할 때 적용된다(출처: https://code.claude.com/docs/en/plugins/install, https://code.claude.com/docs/en/plugins/loading). `~/.local/bin` 링크·rc 표식 블록·AI facade 는 새로 시작하는 셸·세션부터 적용된다. 실행 중 세션이 compact·resume 때 hook 설정과 스킬을 다시 읽는지는 확인 안 됨(공식 문서에서 찾지 못함).

---

## 3. 마이그레이션 규칙

- 마이그레이션은 배포 repo 의 `RELEASE.json` 에 누적 목록으로 실린다. 엔진은 아직 실행하지 않은 id 만 순서대로 실행하고, 완료 id 를 `update_state.json` 의 `migrations_done` 에 남긴다.
- 스크립트는 멱등이다. 같은 id 를 다시 실행해도 결과가 같다.
- 인자는 `--harness-home H --ai-root A [--dry-run]` 이고, 되돌리기가 있으면 `--undo` 를 지원한다.
- 마이그레이션은 사용자 데이터·자격증명·settings.json 을 건드리지 않는다.
- 실패하면 엔진이 `--undo` 를 시도하고 현행(또는 직전 판)으로 원복한 뒤 rc=1 을 낸다. 실패 줄은 `마이그레이션 실패: <id> rc=N 사유: <stderr 1줄>` 형식이다(값·diff 본문은 나오지 않는다). 시간 초과도 같은 실패로 처리한다.
- 대상이 아니어서 `<이름> SKIP` 을 낸 마이그레이션(예: 새 구조 home 의 m0001)은 `migrations_done` 에만 기록하고 요약의 `마이그레이션:` 줄에는 넣지 않는다. 실행한 것이 없으면 `마이그레이션: 없음` 이다.

---

## 4. rollback — 직전 판으로 되돌리기

```bash
bash -c 'python3 -B "$ENGINE" rollback; echo "RC=$?"'
```

- 직전 판(previous)으로 active 링크와 `~/.local/bin` 링크를 되돌린다.
- 직전 판이 레거시 설치였으면 레거시 src 를 기록된 sha 로 `git reset --keep` 하고, 기록된 링크 값과 rc 표식 블록 백업(`<파일>.harness-bak.<UTC>`)을 복원한다.
- 플러그인 구판 복귀는 CLI 한계로 보장되지 않는다. 결과에 그렇게 나오면 그대로 보고한다.
- 상태 점검만 하려면 `verify`, 엔진 자체 점검은 `selftest` 를 쓴다.

---

## 5. 레거시 부트스트랩 (엔진이 아직 없는 기존 설치)

옛 설치(`HARNESS_HOME/src` clone, `current → src/plugins/harness`)에는 엔진이 없다. 레거시 src 의 원격에서 엔진만 꺼내 1회 실행하면 첫 apply 가 레거시 이전 마이그레이션(m0001)을 함께 수행한다.

```bash
bash -c 'S="$HARNESS_HOME/src"; T="$(mktemp -d)"; git -C "$S" fetch origin --tags || exit 2;
  for p in plugins/harness/scripts/harness_update.py plugins/harness/scripts/harness_ai_root.py install_harness.sh requires.txt; do
    git -C "$S" show "origin/HEAD:$p" > "$T/$(basename "$p")" || exit 2; done;
  PATH="$HOME/.local/bin:$PATH" python3 -B "$T/harness_update.py" status'
```

이어서 같은 임시 파일로 `apply --ai-root <프로젝트홈>/AI --non-interactive` 를 실행한다. 큰 변경이 있으면 2.4 처럼 사용자 확인 뒤 `--accept-breaking` 을 붙인다.
- 레거시 폴더(src·current·bin·venv)는 옮기지도 지우지도 않는다. 실행 중 세션·daemon·marketplace 소스를 보호하기 위해서다.
- rc 표식 블록이 든 파일(`~/.bashrc`·`~/.profile`·`~/.bash_profile`)은 파일마다 백업 후 갱신되고, 출력은 파일별 `RC <파일> backup=… changed_lines=… sha256=…` 1줄뿐이다. diff 내용은 출력하거나 보고하지 않는다.

---

## 6. 새 머신 설치 (oUpdate 가 아니라 설치 sh)

하네스가 없는 머신은 배포 repo 루트의 `install_harness.sh` 파일을 전달받아 `bash install_harness.sh` 로 설치한다(구 이름 `install-online.sh` 는 호환 래퍼). `<owner>/<repo>/<기본브랜치>` 는 배포 repo README 의 값을 쓴다(이미 설치된 머신에서는 `git -C "$HARNESS_HOME/src" remote get-url origin` 으로 확인한다). URL 에 토큰이 들어 있으면 그 부분은 출력하지 않는다.

```bash
# 1순위는 install_harness.sh 파일을 대상 머신으로 복사한 뒤 실행하는 방식이다.
bash install_harness.sh
# 대안은 배포 repo 를 clone 해 실행하는 방식이다.
git clone <배포 repo URL> /tmp/ch && bash /tmp/ch/install_harness.sh
```

- 프로젝트 홈 폴더를 1회 묻고(`--home` 으로 지정 가능) `<프로젝트홈>/AI` 를 만든 뒤 필수 도구 점검·설치, clone, apply, `~/.local/bin` 링크(cc·ccc·lcc·lccc·claude-as·cas)까지 수행한다.
- 이미 설치된 머신에서 다시 실행하면 자동으로 oUpdate(apply)를 호출한다.
- 인자는 `--home`·`--non-interactive`·`--yes`·`--no-sudo`·`--no-plugin`·`--no-rc`·`--repo-url` 이다.
- codex 플러그인 연결은 설치 sh 가 수행한다. 실패했거나 `--no-plugin` 이면 다음 명령을 직접 실행한다. oUpdate 는 codex 플러그인을 설치하지 않고, 없으면 `해야 할 일: [note] codex 플러그인 연결: …` 줄로 이 명령을 안내만 한다.

```bash
claude plugin marketplace add openai/codex-plugin-cc && claude plugin install codex@openai-codex
```

- 플러그인 연결(또는 첫 세션의 규칙 적재) 뒤 `/oUpdate` 를 다시 실행하면 facade 가 정리된다. 엔진은 이미 최신(`OUPDATE UP_TO_DATE`)이어도 facade 를 다시 맞춘다. 플러그인이 활성이면 facade 가 만든 `.mcp.json` 을 지워 oio 이중 기동을 막고, `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/rules/harness.md` 가 있으면 `CLAUDE.md` 를 짧은 표식 파일로 바꿔 규칙 이중 적재를 막는다.

### 6.1 로그인은 수동이다

계정 인증은 자동화할 수 없다. 설치·갱신이 끝나면 다음을 사용자에게 안내한다.
- 새 셸을 열거나 `exec $SHELL -l` 을 실행하면 cc 를 바로 쓸 수 있다.
- 처음이면 claude 를 실행한 뒤 `/login` 으로 로그인한다.
- codex 는 `codex login` 으로 로그인한다(ChatGPT 계정 또는 API 키). 그 뒤 Claude Code 안에서 `/codex:setup` 으로 준비 상태를 확인한다.

---

## 7. 완료 보고

다음을 사용자에게 보고한다.
- 요약 줄(`OUPDATE OK|PARTIAL <이전> → <새> (<sha12>) verify=PASS plugin=<updated|n/a|partial> ai_root=<경로>`)과 rc, 이어지는 `변경:`·`요구 도구:`·`마이그레이션:`·`해야 할 일: [kind] text` 줄
- 큰 변경 요약, 요구 도구 결과(`요구 도구: git=system claude=user codex=missing …` 처럼 도구=단계 요약), 실행된 마이그레이션 id(SKIP 은 빠지고, 없으면 `없음`)
- 해야 할 일(post_actions) 전체
- PARTIAL·NEEDS·BREAKING·REFUSE 이면 그 대응 안내

---

## 금지 사항

- 사용자 확인 없이 `--accept-breaking` 을 붙이는 것
- 에이전트가 sudo 를 실행하는 것(sudo 명령은 사용자에게 전달만 한다)
- post_actions(재시작·새 셸·플러그인 재로드)를 자동 실행하는 것
- 정본(배포자) 머신에서 REFUSE 를 우회하는 것 — 정본 머신은 `/oUpload` 를 쓴다
- 레거시 폴더를 옮기거나 지우는 것
- rc diff 내용·자격증명·토큰이 든 URL 을 출력하는 것
