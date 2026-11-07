---
name: oUpload
description: 하네스 배포 repo(기본값 <AI 루트>/claude-harness)를 안전하게 publish하는 배포자(정본 머신) 전용 스킬. 배포본 빌드 → 자격증명 스캔 게이트 → plugin.json + marketplace.json 2파일 동기 version 범프 → RELEASE.json 메타(요약·큰 변경·해야 할 일) 작성과 lint-release → 명시 경로 add·커밋·태그 → push 순서로 진행한다. 두 파일의 version이 일치해야 하며, 한쪽만 올리면 불일치가 남아 수신자 자동갱신이 깨진다. 다른 머신은 install-online.sh 1줄 설치 또는 /oUpdate 로 받는다. 사용자가 '/oUpload', '하네스 배포', '배포본 올려', '플러그인 배포' 요청 시 사용.
---

# oUpload — 하네스 배포 publish (배포자 전용)

> **전제**: 배포자 환경(정본 AI 프로젝트가 실디렉터리인 머신)에서만 실행한다. 배포 repo 를 소유하지 않은 환경에서 호출되면 즉시 중단한다. 수신자 머신의 갱신은 `/oUpdate` 다.
> **목적**: 자격증명 유출 없이 배포 repo 를 git 에 모두 올리고(push), 수신자 갱신을 확실히 트리거한다.
> **끝나는 지점**: push 다. 별도 설치본·dist·릴리스 첨부는 만들지 않는다. 다른 머신은 배포 repo 의 `install-online.sh` 로 설치하고 `/oUpdate` 로 갱신한다.

---

## 0. 실행 전 확인

### 0.1 AI 루트와 배포 repo 경로 확정

AI 루트는 `HARNESS_AI_ROOT` 환경변수, 없으면 `harness_ai_root.py resolve` 결과다. 배포 repo 는 다음 순서로 처음 정해지는 값을 쓴다.

1. 사용자가 준 인자 경로
2. `HARNESS_DIST_REPO` 환경변수
3. `<AI 루트>/claude-harness`

```bash
bash -c 'A="${HARNESS_AI_ROOT:-}";
  if [ -z "$A" ]; then for s in "$PWD/.claude/scripts/harness_ai_root.py" "${HARNESS_HOME:-$HOME/.harness}/current/scripts/harness_ai_root.py"; do
    [ -f "$s" ] && A="$(python3 -B "$s" resolve)" && break; done; fi;
  [ -n "$A" ] || { echo AI_ROOT_NOT_FOUND; exit 2; };
  REPO="${1:-${HARNESS_DIST_REPO:-$A/claude-harness}}";
  echo "AI_ROOT=$A"; echo "REPO=$REPO"; git -C "$REPO" rev-parse --show-toplevel' -- "<인자 repo 경로, 없으면 생략>"
```

이하 명령의 `<AI 루트>`·`<배포 repo>` 는 위에서 확정한 절대경로를 리터럴로 넣는다. oio bash_exec 는 최상위 `&&` 구간을 따로 실행할 수 있으므로 앞 명령의 변수에 기대지 않는다. 셸은 dash 일 수 있으므로 명령은 `bash -c` 로 감싼다.

### 0.2 중단 조건

다음 중 하나라도 해당하면 **즉시 중단하고 사용자에게 보고**한다.
- git repo 가 아니다.
- `scripts/credential_scan.sh` 가 없다 (게이트 부재 = fail-closed).
- `plugins/harness/.claude-plugin/plugin.json` 이 없다.
- `.claude-plugin/marketplace.json` 이 없다.
- `install-online.sh`·`requires.txt` 가 없다 (새 머신 설치 경로 부재).
- `<AI 루트>/.claude/scripts/harness_update.py` 가 없다 (RELEASE.json 작성·검사 불가).
- 현재 브랜치가 배포 브랜치가 아니다 (사용자 확인 필요).

---

## Step 0.5. 배포본 빌드

AI 정본에서 배포 repo 로 플러그인 배포본을 만든다. 먼저 dry-run 으로 관리 경로를 확인한다.

```bash
bash -c 'python3 -B "<AI 루트>/.claude/scripts/harness_bundle_build.py" --src "<AI 루트>" --out "<배포 repo>" --dry-run --report /tmp/oupload_build_report.json; echo "RC=$?"'
```

```bash
bash -c 'python3 -B "<AI 루트>/.claude/scripts/harness_bundle_build.py" --src "<AI 루트>" --out "<배포 repo>"; echo "RC=$?"'
```

- rc=3 은 배포 repo 에 미커밋 변경이 있다는 뜻이다. `git -C "<배포 repo>" status --short` 로 확인해 미커밋 변경이 빌더 관리 경로(보고서의 관리 영역) 안에만 있으면 `--allow-dirty` 를 붙여 다시 실행한다. 관리 경로 밖 변경이 있으면 중단하고 사용자에게 보고한다.
- 빌더는 git 이 추적하는 파일만 싣는다. 새로 만든 정본 파일이 빠졌으면 AI 저장소에서 그 파일을 명시 경로로 스테이징한 뒤 다시 빌드한다.

---

## Step 1. 자격증명 스캔 게이트  ★차단 지점★

```bash
bash -c 'bash "<배포 repo>/scripts/credential_scan.sh" "<배포 repo>"; echo "RC=$?"'
```

| 결과 | 조치 |
|---|---|
| rc = 0 | Step 1.5 로 진행 |
| rc ≠ 0 | **즉시 중단.** 발견 목록(파일:줄번호)을 사용자에게 보고하고 종료. push 절대 금지 |

**절대 규칙**
- 우회 불가다. "이번만 넘어가자", "테스트용이라 괜찮다" 는 금지다.
- 자격증명 **값 자체를 화면에 출력하지 마라.** 스크립트가 파일:줄번호만 출력하므로 그 출력을 그대로 전달한다.
- 화이트리스트를 넓혀서 게이트를 통과시키는 행위는 금지다. 값을 실제로 제거하는 것이 유일한 정답이다.

### Step 1.5. pre-commit hook 배선 확인 (필수)

`.git/hooks` 는 clone 으로 전파되지 않으므로 매 실행마다 확인한다.

```bash
bash -c 'GD="$(git -C "<배포 repo>" rev-parse --git-dir)"; case "$GD" in /*) ;; *) GD="<배포 repo>/$GD";; esac;
  [ -e "$GD/hooks/pre-commit" ] && echo "WIRED" || echo "NOT_WIRED"'
```

`NOT_WIRED` 이면 즉시 배선한 후 진행한다.

```bash
bash -c 'GD="$(git -C "<배포 repo>" rev-parse --git-dir)"; case "$GD" in /*) ;; *) GD="<배포 repo>/$GD";; esac;
  ln -sfn "<배포 repo>/scripts/pre-commit" "$GD/hooks/pre-commit";
  chmod +x "<배포 repo>/scripts/pre-commit"; echo WIRED'
```

---

## Step 2. 제외 목록 재검증

배포 제외 대상이 repo 에 섞여 들어가지 않았는지 확인한다.

```bash
bash -c 'find "<배포 repo>" -maxdepth 6 \( -name ".venv" -o -name "__pycache__" -o -name "*.bak" -o -name "*.bak.*" \) \
       -not -path "*/.git/*" | head -20'
```

- `.venv/`, `__pycache__/`, `*.bak*` 가 발견되면 `.gitignore` 등재 여부를 확인하고, 추적 중이면 제거한다.
- 프로젝트 고유 스킬(개인 인프라 스킬, 개인 업무 자동화 스킬)이 `plugins/harness/skills/` 에 남아 있지 않은지 확인한다.
- 원본 `.mcp.json` 을 복사한 흔적이 없는지 확인한다 (배포본 `.mcp.json` 은 신규 작성분이어야 한다).

---

## Step 3. 무결성 검증

| # | 검증 항목 | 확인 방법 |
|---|---|---|
| 1 | `plugin.json` JSON 파싱 성공 | `python3 -m json.tool` |
| 2 | `marketplace.json` JSON 파싱 성공 | `python3 -m json.tool` |
| 3 | `hooks/hooks.json` JSON 파싱 성공 | `python3 -m json.tool` |
| 4 | 전 hook shebang 이 bash 계열 | 아래 명령 |
| 5 | `rules/harness.md` 존재 | `[ -f ... ]` |
| 6 | `bin/` 실행기 6종 존재(cc·ccc·lcc·lccc·claude-as·cas) | 아래 명령 |
| 7 | `install-online.sh` 문법·`requires.txt` 존재 | `sh -n`·`[ -f ... ]` |

```bash
bash -c 'R="<배포 repo>";
  for f in "$R/plugins/harness/.claude-plugin/plugin.json" "$R/.claude-plugin/marketplace.json" "$R/plugins/harness/hooks/hooks.json"; do
    python3 -m json.tool "$f" >/dev/null 2>&1 && echo "JSON_OK $f" || echo "JSON_FAIL $f"; done;
  for b in cc ccc lcc lccc claude-as cas; do [ -e "$R/bin/$b" ] && echo "BIN_OK $b" || echo "BIN_MISSING $b"; done;
  sh -n "$R/install-online.sh" && echo INSTALL_ONLINE_SYNTAX_OK || echo INSTALL_ONLINE_SYNTAX_FAIL;
  [ -f "$R/requires.txt" ] && echo REQUIRES_OK || echo REQUIRES_MISSING'
```

```bash
bash -c 'BAD=0;
  for f in "<배포 repo>"/plugins/harness/hooks/*.sh; do
    head -1 "$f" | grep -qE "^#!(/bin/bash|/usr/bin/env bash)" || { echo "SHEBANG_BAD $f"; BAD=1; }
  done; [ "$BAD" -eq 0 ] && echo SHEBANG_ALL_OK'
```

하나라도 실패하면 **중단하고 사용자에게 보고**한다. 임의 수정 후 무단 진행 금지다.

---

## Step 4. version 범프  ★자동갱신의 유일한 트리거 — 2파일 동기 필수★

**두 파일을 반드시 함께 올린다.**

- `plugins/harness/.claude-plugin/plugin.json` 의 `version`
- `.claude-plugin/marketplace.json` 의 `plugins[0].version`

이 두 값은 항상 같아야 한다. 한쪽만 올리면 불일치가 남고 수신자 자동갱신 판정이 어긋난다.
(2026-09-15 실측: 수동 배포 v1.1.0 시점에 marketplace.json 누락이 발견되어 본 스킬에 동기화 단계를 추가함.)

| 인자 | 증가 방식 | 예 |
|---|---|---|
| (없음) / `patch` | patch 증가 (기본) | 0.1.3 → 0.1.4 |
| `minor` | minor 증가, patch=0 | 0.1.3 → 0.2.0 |
| `major` | major 증가, minor=patch=0 | 0.1.3 → 1.0.0 |

권장 절차는 다음 4단계다. 셸 안에 파이썬 코드를 인라인으로 밀어넣지 않는다 (인용 파괴 위험).

1) 현재 두 버전을 확인하고 일치 여부를 먼저 검사한다.

```bash
bash -c 'R="<배포 repo>";
  V1=$(python3 -c "import json;print(json.load(open(\"$R/plugins/harness/.claude-plugin/plugin.json\",encoding=\"utf-8\"))[\"version\"])");
  V2=$(python3 -c "import json;print(json.load(open(\"$R/.claude-plugin/marketplace.json\",encoding=\"utf-8\"))[\"plugins\"][0][\"version\"])");
  echo "plugin.json=$V1 marketplace.json=$V2";
  [ "$V1" = "$V2" ] && echo PRE_BUMP_MATCH || echo "PRE_BUMP_MISMATCH — 범프 전부터 불일치, 사용자 보고 필요"'
```

범프 전부터 불일치이면 즉시 사용자에게 보고하고 어느 값을 기준으로 맞출지 확인 후 진행한다.

2) `file_edit` 으로 **두 파일 모두** version 한 줄씩 치환한다. 이 방식은 JSON 의 나머지 필드·포매팅·주석 순서를 건드리지 않으므로 가장 안전하다.

```
# plugin.json
old_string:  "version": "0.1.3",
new_string:  "version": "0.1.4",

# marketplace.json (plugins[0].version)
old_string:  "version": "0.1.3",
new_string:  "version": "0.1.4",
```

3) 치환 후 반드시 JSON 파싱을 재확인한다.

```bash
bash -c 'R="<배포 repo>";
  python3 -m json.tool "$R/plugins/harness/.claude-plugin/plugin.json" >/dev/null && echo PLUGIN_JSON_OK;
  python3 -m json.tool "$R/.claude-plugin/marketplace.json" >/dev/null && echo MARKETPLACE_JSON_OK'
```

4) 두 값이 실제로 동일한 새 버전으로 일치하는지 최종 검증한다.

```bash
bash -c 'R="<배포 repo>";
  V1=$(python3 -c "import json;print(json.load(open(\"$R/plugins/harness/.claude-plugin/plugin.json\",encoding=\"utf-8\"))[\"version\"])");
  V2=$(python3 -c "import json;print(json.load(open(\"$R/.claude-plugin/marketplace.json\",encoding=\"utf-8\"))[\"plugins\"][0][\"version\"])");
  [ "$V1" = "$V2" ] && echo "POST_BUMP_MATCH $V1" || echo "POST_BUMP_MISMATCH plugin=$V1 marketplace=$V2 — 중단 필요"'
```

`POST_BUMP_MISMATCH` 이면 커밋하지 말고 즉시 중단, 사용자에게 보고한다.

**절대 규칙**: 두 파일 중 하나라도 범프하지 않으면 수신자에게 갱신이 **전파되지 않거나 불일치가 남는다.** 생략 금지다.
범프 전후 값(양쪽 파일 모두)을 사용자에게 반드시 보고한다.

---

## Step 4.5. 판별 메타 RELEASE.json 작성 ★oUpdate 의 판정 근거★

수신자 `/oUpdate` 는 배포 repo 루트의 `RELEASE.json` 으로 큰 변경·요구 도구·마이그레이션·해야 할 일을 판단한다. 매 배포마다 새로 쓴다.

1) 사용자에게 다음 3가지를 받는다(메인 화면 세션이면 AskUserQuestion, 자율 세션이면 변경 내역에서 작성하고 보고에 명시).
- 변경 요약 1~3줄
- 큰 변경(breaking) 여부 — 구조 변경·수동 조치 필요·호환이 깨지는 변경이면 예
- 해야 할 일(post_actions) — `new_shell`(새 셸)·`restart_cc`(cc 재시작)·`reload_plugin`(플러그인 재로드)·`note`(그 밖의 안내) 중 필요한 것과 문구

2) write-release 로 작성한다. `--source-commit` 은 AI 저장소 HEAD sha 다. 요구 도구는 배포 repo 의 `requires.txt` 가 정본이며 write-release 가 읽어 옮긴다.

```bash
bash -c 'python3 -B "<AI 루트>/.claude/scripts/harness_update.py" write-release --repo "<배포 repo>" --version "<새버전>" \
  --summary "<변경 요약>" --source-commit "$(git -C "<AI 루트>" rev-parse HEAD)" [--breaking] [--post-action new_shell:"<문구>"]; echo "RC=$?"'
```

3) lint-release 를 통과해야 한다. rc≠0 이면 중단하고 사용자에게 보고한다.

```bash
bash -c 'python3 -B "<AI 루트>/.claude/scripts/harness_update.py" lint-release --repo "<배포 repo>" "<배포 repo>/RELEASE.json"; echo "RC=$?"'
```

- lint-release 는 필수 키·타입, plugin.json·marketplace.json·RELEASE.json 3개 version 일치, 마이그레이션 스크립트 존재, requires 형식, history 단조 증가를 검사한다.
- 마이그레이션은 누적 목록이다. 과거 id 와 스크립트를 지우지 않는다. 새 마이그레이션 스크립트는 멱등이어야 하고 사용자 데이터·자격증명·settings.json 을 건드리지 않아야 한다.

---

## Step 5. 커밋 · 태그 · 푸시

**전체 스테이징 금지.** 배포 대상 경로를 명시해서만 add 한다. 관리 밖 파일·다른 작업의 미커밋 파일이 섞이는 것을 막기 위해서다.

```bash
bash -c 'cd "<배포 repo>" && git add -- plugins bin install.sh install-online.sh requires.txt README.md .claude-plugin RELEASE.json scripts && git status --short | head -30'
```

- `git status --short` 에 위 경로 밖의 스테이징 항목이 있으면 중단하고 확인한다.
- 위 목록에 없는 새 최상위 경로가 생겼으면 사용자 확인 뒤 그 경로만 명시해 추가한다.

커밋 메시지는 한국어 + 이모지로 작성하고, 제목 마지막에 `by {모델계열}` 을 붙인다.

```bash
bash -c 'cd "<배포 repo>" && git commit -m "🚀 하네스 배포 v<새버전> — <변경 요약> by <모델계열>"'
```

- pre-commit hook 이 다시 스캔을 돌린다. 여기서 차단되면 **강제 우회(`--no-verify`) 금지**다.

커밋 성공 후 주석 태그를 달고 태그와 함께 push 한다. 수신자 oUpdate 는 최신 `v*` 태그를 대상 판으로 쓴다.

```bash
bash -c 'cd "<배포 repo>" && git tag -a "v<새버전>" -m "하네스 v<새버전>" && git push origin "$(git rev-parse --abbrev-ref HEAD)" --follow-tags'
```

push 가 끝나면 배포는 끝난다.

---

## Step 6. 완료 보고

다음 항목을 사용자에게 보고한다.
- 빌드 결과(rc, `--allow-dirty` 사용 여부)
- 스캔 결과 (통과 / 발견 0건)
- version: 이전 → 새 버전 (plugin.json / marketplace.json / RELEASE.json 모두 명시, 일치 확인 포함)
- RELEASE.json 요약·큰 변경 여부·해야 할 일, lint-release 결과
- 커밋 해시 + 변경 파일 수, 태그 `v<새버전>`
- push 대상 원격/브랜치
- **수신자 안내**
  - 새 머신: 배포 repo 루트의 `install-online.sh` 1줄 설치(curl·wget·clone 후 실행 3가지, 형식은 `/oUpdate` 스킬 "새 머신 설치" 절과 README).
  - 이미 설치된 머신: `/oUpdate` 로 받는다. 큰 변경이면 수신자 쪽에서 확인을 받은 뒤 적용된다.
  - 플러그인 본체(hook·oio)는 마켓플레이스 갱신으로도 전파되지만, 스킬 facade·`bin` 실행기·rc 설정은 `/oUpdate` 가 맞춘다.

---

## 금지 사항

- 자격증명 스캔 실패 상태에서의 push (예외 없음).
- `--no-verify` 로 pre-commit 우회.
- version 범프 생략 (plugin.json 또는 marketplace.json 어느 한쪽이라도).
- 세 파일(plugin.json·marketplace.json·RELEASE.json) version 불일치 상태에서의 커밋/push.
- lint-release 실패 상태에서의 커밋/push.
- 전체 스테이징(배포 대상 경로를 명시하지 않은 add).
- 자격증명 값 화면 출력.
- 스캔 화이트리스트를 넓혀 게이트 통과시키기.
- 무결성 검증 실패 항목을 임의 판단으로 무시하고 진행.
