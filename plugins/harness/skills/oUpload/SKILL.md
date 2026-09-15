---
name: oUpload
description: 하네스 배포 repo를 안전하게 publish하는 배포자 전용 스킬. 자격증명 스캔 게이트 통과 → plugin.json + marketplace.json 2파일 동기 version 범프 → 커밋 → push 순서로 진행한다. 두 파일의 version이 일치해야 하며, 한쪽만 올리면 불일치가 남아 수신자 자동갱신이 깨진다. 사용자가 '/oUpload', '하네스 배포', '배포본 올려', '플러그인 배포' 요청 시 사용.
---

# oUpload — 하네스 배포 publish (배포자 전용)

> **전제**: 배포자 환경에서만 실행한다. 수신자 환경(배포 repo 소유자가 아닌 환경)에서 호출되면 즉시 중단한다.
> **목적**: 자격증명 유출 없이 배포 repo 를 publish 하고, 수신자 자동갱신을 확실히 트리거한다.

---

## 0. 실행 전 확인

배포 repo 루트를 먼저 특정한다. 이후 모든 경로는 이 값을 기준으로 한다.

```bash
bash -c 'cd "<배포 repo 경로>" && git rev-parse --show-toplevel'
```

다음 중 하나라도 해당하면 **즉시 중단하고 사용자에게 보고**한다.
- git repo 가 아니다.
- `scripts/credential_scan.sh` 가 없다 (게이트 부재 = fail-closed).
- `plugins/harness/.claude-plugin/plugin.json` 이 없다.
- 현재 브랜치가 배포 브랜치가 아니다 (사용자 확인 필요).

---

## Step 1. 자격증명 스캔 게이트  ★차단 지점★

```bash
bash -c 'bash "<REPO>/scripts/credential_scan.sh" "<REPO>"; echo "RC=$?"'
```

| 결과 | 조치 |
|---|---|
| rc = 0 | Step 2 로 진행 |
| rc ≠ 0 | **즉시 중단.** 발견 목록(파일:줄번호)을 사용자에게 보고하고 종료. push 절대 금지 |

**절대 규칙**
- 우회 불가다. "이번만 넘어가자", "테스트용이라 괜찮다" 는 금지다.
- 자격증명 **값 자체를 화면에 출력하지 마라.** 스크립트가 파일:줄번호만 출력하므로 그 출력을 그대로 전달한다.
- 화이트리스트를 넓혀서 게이트를 통과시키는 행위는 금지다. 값을 실제로 제거하는 것이 유일한 정답이다.

### Step 1.5. pre-commit hook 배선 확인 (필수)

`.git/hooks` 는 clone 으로 전파되지 않으므로 매 실행마다 확인한다.

```bash
bash -c 'REPO="<REPO>"; GD="$(git -C "$REPO" rev-parse --git-dir)";
  [ -e "$GD/hooks/pre-commit" ] && echo "WIRED" || echo "NOT_WIRED"'
```

`NOT_WIRED` 이면 즉시 배선한 후 진행한다.

```bash
bash -c 'REPO="<REPO>"; GD="$(git -C "$REPO" rev-parse --git-dir)";
  ln -sfn "$REPO/scripts/pre-commit" "$GD/hooks/pre-commit";
  chmod +x "$REPO/scripts/pre-commit"; echo WIRED'
```

---

## Step 2. 제외 목록 재검증

배포 제외 대상이 repo 에 섞여 들어가지 않았는지 확인한다.

```bash
bash -c 'REPO="<REPO>";
  find "$REPO" -maxdepth 6 \( -name ".venv" -o -name "__pycache__" -o -name "*.bak" -o -name "*.bak.*" \) \
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
| 6 | `bin/` 3종 존재 | `ls bin/` |

```bash
bash -c 'REPO="<REPO>";
  for f in "$REPO/plugins/harness/.claude-plugin/plugin.json" \
           "$REPO/.claude-plugin/marketplace.json" \
           "$REPO/plugins/harness/hooks/hooks.json"; do
    python3 -m json.tool "$f" >/dev/null 2>&1 && echo "JSON_OK $f" || echo "JSON_FAIL $f"
  done'
```

```bash
bash -c 'REPO="<REPO>"; BAD=0;
  for f in "$REPO"/plugins/harness/hooks/*.sh; do
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
bash -c 'REPO="<REPO>";
  V1=$(python3 -c "import json;print(json.load(open(\"$REPO/plugins/harness/.claude-plugin/plugin.json\",encoding=\"utf-8\"))[\"version\"])");
  V2=$(python3 -c "import json;print(json.load(open(\"$REPO/.claude-plugin/marketplace.json\",encoding=\"utf-8\"))[\"plugins\"][0][\"version\"])");
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
bash -c 'REPO="<REPO>";
  python3 -m json.tool "$REPO/plugins/harness/.claude-plugin/plugin.json" >/dev/null && echo PLUGIN_JSON_OK;
  python3 -m json.tool "$REPO/.claude-plugin/marketplace.json" >/dev/null && echo MARKETPLACE_JSON_OK'
```

4) 두 값이 실제로 동일한 새 버전으로 일치하는지 최종 검증한다.

```bash
bash -c 'REPO="<REPO>";
  V1=$(python3 -c "import json;print(json.load(open(\"$REPO/plugins/harness/.claude-plugin/plugin.json\",encoding=\"utf-8\"))[\"version\"])");
  V2=$(python3 -c "import json;print(json.load(open(\"$REPO/.claude-plugin/marketplace.json\",encoding=\"utf-8\"))[\"plugins\"][0][\"version\"])");
  [ "$V1" = "$V2" ] && echo "POST_BUMP_MATCH $V1" || echo "POST_BUMP_MISMATCH plugin=$V1 marketplace=$V2 — 중단 필요"'
```

`POST_BUMP_MISMATCH` 이면 커밋하지 말고 즉시 중단, 사용자에게 보고한다.

**절대 규칙**: 두 파일 중 하나라도 범프하지 않으면 수신자에게 갱신이 **전파되지 않거나 불일치가 남는다.** 생략 금지다.
범프 전후 값(양쪽 파일 모두)을 사용자에게 반드시 보고한다.

---

## Step 5. 커밋 & 푸시

커밋 메시지는 한국어 + 이모지로 작성하고, 제목 마지막에 `by {모델버전}` 을 붙인다.

```bash
bash -c 'REPO="<REPO>"; cd "$REPO" && git add -A && git status --short | head -30'
```

```bash
bash -c 'REPO="<REPO>"; cd "$REPO" && git commit -m "🚀 하네스 배포 v<새버전> — <변경 요약> by <모델버전>"'
```

- pre-commit hook 이 다시 스캔을 돌린다. 여기서 차단되면 **강제 우회(`--no-verify`) 금지**다.
- 커밋 성공 후 push 한다.

```bash
bash -c 'REPO="<REPO>"; cd "$REPO" && git push'
```

---

## Step 6. 완료 보고

다음 항목을 사용자에게 보고한다.
- 스캔 결과 (통과 / 발견 0건)
- version: 이전 → 새 버전 (plugin.json / marketplace.json 양쪽 모두 명시, 일치 확인 포함)
- 커밋 해시 + 변경 파일 수
- push 대상 원격/브랜치
- **수신자 전파 안내**: "플러그인 본체(스킬/hook/규칙/oio)는 마켓플레이스가 자동갱신하며,
  수신자 환경에 최대 10분 내 전파된다. `bin` 3종과 `install.sh` 는 자동갱신 대상이 아니므로
  수신자가 `/oDownload` 를 실행해야 한다."

---

## 금지 사항

- 자격증명 스캔 실패 상태에서의 push (예외 없음).
- `--no-verify` 로 pre-commit 우회.
- version 범프 생략 (plugin.json 또는 marketplace.json 어느 한쪽이라도).
- 두 파일 version 불일치 상태에서의 커밋/push.
- 자격증명 값 화면 출력.
- 스캔 화이트리스트를 넓혀 게이트 통과시키기.
- 무결성 검증 실패 항목을 임의 판단으로 무시하고 진행.
