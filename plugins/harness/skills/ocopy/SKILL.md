---
name: ocopy
description: "새 프로젝트 기본 환경 구축. AI 원본의 공용 파일/폴더를 심볼릭링크로 연결."
invocation:
  user_callable: true
  pipeline_callable: false
  called_by: [사용자]
  calls: []
---

# ocopy — 새 프로젝트 기본 환경 구축

AI 프로젝트 원본의 공용 파일/폴더를 대상 프로젝트에 심볼릭링크로 연결하여 기본 환경을 한 번에 구축하는 유틸리티 스킬.

> **수동 전용**: `/ocopy {프로젝트명}` 또는 "XX 프로젝트에 기본환경 구축해줘"로만 실행.
> Auto-activates 없음 — 자동 발동 절대 금지.

---

## 호출 방식

```yaml
슬래시_커맨드:
  - /ocopy tmuxMon             # 프로젝트명 → <프로젝트 루트>/tmuxMon
  - /ocopy <절대경로>          # 절대경로 직접 지정

자연어:
  - "tmuxMon 프로젝트에 기본환경 구축해줘"
  - "<절대경로> 에 기본환경 구축해줘"
```

---

## 인자 파싱

```yaml
규칙:
  1. 절대경로 (/로 시작): 그대로 사용
  2. 프로젝트명 (단어): <프로젝트 루트>/{프로젝트명} 으로 변환. 정확히 일치하는 폴더가 없으면 대소문자 무시로 1건만 찾는다
  3. 인자 없음: 사용자에게 프로젝트명 질문
```

---

## AI 루트·프로젝트 루트 해석

경로는 스킬 문서에 박지 않는다. 링크 실행기 `ocopy_link.py` 가 공용 해석 모듈 `harness_ai_root.py` 로 정한다.

```yaml
AI_루트 (링크 원본, 대문자 AI):
  순서: --ai-root 인자 > HARNESS_AI_ROOT 환경변수 > ${CLAUDE_CONFIG_DIR:-~/.claude}/harness_ai_root 파일
        > ~/.config/claude-harness/project_home 첫 줄 + /AI > realpath(${HARNESS_HOME:-$HOME/.harness}/current/hooks) 가 <X>/.claude/hooks 이고 <X>/CLAUDE.md 가 있으면 <X>
  정본_머신: 기존 정본 AI 폴더(실디렉터리)로 풀린다
  설치_머신: <프로젝트홈>/AI facade 로 풀린다(install-online.sh·oUpdate 가 만든 폴더)

프로젝트_루트 (프로젝트명 인자의 부모):
  순서: --projects-root 인자 > CLAUDE_PROJECT_ROOTS 첫 항목 > ~/.config/claude-harness/project_home
        > AI 루트 INFRA.md INFRA-FIELDS 의 projects_root > AI 루트의 부모
```

> 실제 값은 `--dry-run` 출력의 JSON 요약(`ai_root`·`target`)으로 확인한다.

---

## 링크 실행기 찾기

다음 순서로 처음 찾은 파일을 쓴다. 경로를 추정하지 말고 실제로 있는지 확인한다.

1. `<AI 루트>/.claude/scripts/ocopy_link.py`
2. `${HARNESS_HOME}/active/plugins/harness/scripts/ocopy_link.py`
3. `${HARNESS_HOME:-$HOME/.harness}/current/scripts/ocopy_link.py`

```bash
bash -c 'A="${HARNESS_AI_ROOT:-}"; H="${HARNESS_HOME:-$HOME/.harness}";
  for f in ${A:+"$A/.claude/scripts/ocopy_link.py"} "$H/active/plugins/harness/scripts/ocopy_link.py" "${HARNESS_HOME:-$HOME/.harness}/current/scripts/ocopy_link.py"; do
    [ -f "$f" ] && { echo "OCOPY_LINK=$f"; exit 0; }; done; echo OCOPY_LINK_NOT_FOUND; exit 2'
```

`OCOPY_LINK_NOT_FOUND` 이면 중단하고 사용자에게 보고한다(하네스 설치·갱신 필요 — `/oUpdate`).

---

## 링크 대상

### 심볼릭링크 (전체 — 절대경로)

| 원본 | 대상 | 링크 값(절대경로) |
|------|------|----------|
| `AI/CLAUDE.md` | `{대상}/CLAUDE.md` | `<AI 루트>/CLAUDE.md` |
| `AI/CLAUDE.md` | `{대상}/AGENTS.md` | `<AI 루트>/CLAUDE.md` |
| `AI/.mcp.json` | `{대상}/.mcp.json` | `<AI 루트>/.mcp.json` |
| `AI/.claude/settings.json` | `{대상}/.claude/settings.json` | `<AI 루트>/.claude/settings.json` |
| `AI/.claude/settings.local.json` | `{대상}/.claude/settings.local.json` | `<AI 루트>/.claude/settings.local.json` |
| `AI/.claude/commands` | `{대상}/.claude/commands` | `<AI 루트>/.claude/commands` |
| `AI/.claude/skills` | `{대상}/.claude/skills` | `<AI 루트>/.claude/skills` |
| `${HARNESS_HOME:-$HOME/.harness}/current/hooks` | `{대상}/.claude/hooks` | `${HARNESS_HOME:-$HOME/.harness}/current/hooks` (없으면 `<AI 루트>/.claude/hooks`) |

> **모든 공용 파일을 심볼릭링크로 통일**: AI 원본 수정 시 전체 프로젝트에 즉시 반영.
> **해석된 AI 루트 절대경로 사용 (2026-10-28 정정)**: 대상 프로젝트가 AI 와 다른 파일시스템(예: Windows 쪽 프로젝트 폴더)에 있으면 상대경로 `../AI/...` 는 그 옆의 옛 AI 사본으로 풀릴 수 있다. 그래서 링크 값은 항상 해석된 AI 루트의 절대경로다. 대문자 `AI` 통일 필수.
> **hooks는 절대경로 symlink 필수** (2026-05-02): settings.json hook command가 매크로(`$CLAUDE_PROJECT_DIR/...`)에서 절대경로로 전환된 후, 활성 세션이 옛 매크로 캐시를 들고 호출하면 프로젝트 로컬 `.claude/hooks/`로 fallback됨. symlink가 없으면 22일간 6개 프로젝트 1,122회 silent fail 같은 사고 재발. (출처: settings_changelog.md 2026-05-02)
> **원본이 없는 항목은 건너뛴다**: 설치 머신의 AI facade 에는 `.mcp.json`·`settings.local.json` 이 없을 수 있다(플러그인이 oio 를 제공). 이때 `SKIP_NOSRC` 로 보고된다.
> **스킬 이중 표시**: 플러그인이 설치된 머신에서는 같은 스킬이 `harness:oplan` 과 `oplan` 두 이름으로 보일 수 있다. 플러그인 스킬과 프로젝트 `.claude/skills` 링크가 함께 읽히기 때문이며, 둘 다 같은 원본이므로 그대로 둔다.

---

## 실행 절차

### Step 1: 대상 경로 결정 (dry-run)

```bash
bash -c 'python3 -B "<OCOPY_LINK 경로>" "<프로젝트명 또는 절대경로>" --dry-run; echo "RC=$?"'
```

- 출력 마지막 줄 JSON 의 `target` 이 대상 절대경로(TARGET_PATH), `ai_root` 가 링크 원본이다. 사용자에게 함께 보여 준다.
- `ERR` 줄이 있거나 rc≠0 이면 중단하고 보고한다. 대상이 AI 루트 자신이거나 그 안이면 `ERR` 로 거부된다.
- 프로젝트 루트·AI 루트를 바꿔야 하면 `--projects-root`·`--ai-root` 를 붙인다.

### Step 2~3: 디렉토리 준비 + 심볼릭링크 생성

```bash
bash -c 'python3 -B "<OCOPY_LINK 경로>" "<프로젝트명 또는 절대경로>"; echo "RC=$?"'
```

출력 코드는 다음과 같다.

| 코드 | 뜻 |
|---|---|
| `MKDIR` | 대상 폴더·`.claude`·`.claude/locks` 생성 |
| `LINK_OK` | 링크 생성(dry-run 이면 끝에 `(dry-run)`) |
| `SKIP_EXISTS` | 이미 있음 — 덮어쓰지 않음 |
| `SKIP_NOSRC` | 원본 없음 — 건너뜀 |
| `ERR` | 실패 — rc=1 |

> 이미 있는 파일·폴더·링크는 덮어쓰지 않는다.
> `locks/`는 파이프라인 잠금 파일 저장소 — 항상 실제 디렉토리로 생성된다.
> 마지막 줄 JSON 요약의 `counts` 를 결과 보고에 쓴다.

### Step 5.5: INFRA.md·문서지도·정본 골격 생성

프로젝트명({project})을 인자에서 추출하여 `{TARGET}/INFRA.md`(실행 환경 — INFRA-FIELDS v1 헤더 골격)와 `{TARGET}/.claude/rules/docs-map.md`(문서 지도 골격)를 생성한다. 이미 있으면 스킵한다. 이어서 `plan_init.py` 로 `plan/` 정본 골격을 만든다.

> **변경 이력 (2026-04-09)**: obuild_/orun_/orules_ 스킬은 프로젝트 인프라 스킬에 통합되어 제거됨. 코딩 규칙은 각 프로젝트 PROJECT.md에 기재.
> **변경 이력 (2026-10-26)**: 구 프로젝트 인프라 스킬은 INFRA.md 로 이관. INFRA.md 는 자격증명을 담으므로 커밋하지 않는다.

```bash
PROJECT="{project}"  # 인자에서 추출한 프로젝트명
TARGET="{TARGET_PATH}"

# 1) INFRA.md — 헤더 형식은 hook 이 파싱하므로 바꾸지 않는다 (값은 none/false 골격)
if [ -e "$TARGET/INFRA.md" ]; then
  echo "이미 존재: INFRA.md — 스킵"
else
  cat > "$TARGET/INFRA.md" << INFRAEOF
# INFRA.md — ${PROJECT} 실행 환경
> 이 파일은 자격증명을 포함하므로 저장소에 커밋하지 않는다(.git/info/exclude). 역할 밖 내용(코드 구조·코딩 규칙)은 PROJECT.md 로.

<!-- INFRA-FIELDS v1 : hook 이 파싱한다. 형식을 바꾸지 마라. -->
\`\`\`yaml
infra_fields_version: 1
project: ${PROJECT}
ntfy_topic: none
ui_test: false
\`\`\`
<!-- /INFRA-FIELDS -->

## 목차
- 1. 프로젝트 메타 / 2. 접속·서버 / 3. 빌드 / 4. 배포·기동·중지 / 5. 헬스체크·로그 / 6. 테스트 역량 / 7. 계정 / 8. 알림 / 9. 보조 스크립트
INFRAEOF
  echo "✅ 생성: INFRA.md"
fi

# 2) git 저장소면 INFRA.md 추적 제외 (.git/info/exclude — 커밋 불필요)
if git -C "$TARGET" rev-parse --git-dir >/dev/null 2>&1; then
  EXCL="$(git -C "$TARGET" rev-parse --git-path info/exclude)"
  case "$EXCL" in /*) ;; *) EXCL="$TARGET/$EXCL" ;; esac
  mkdir -p "$(dirname "$EXCL")"
  grep -qxF '/INFRA.md' "$EXCL" 2>/dev/null || echo '/INFRA.md' >> "$EXCL"
fi

# 3) 문서 지도 — .claude/rules/ 는 세션 시작 시 공식 자동 로딩된다
mkdir -p "$TARGET/.claude/rules"
if [ -e "$TARGET/.claude/rules/docs-map.md" ]; then
  echo "이미 존재: docs-map.md — 스킵"
else
  cat > "$TARGET/.claude/rules/docs-map.md" << MAPEOF
# 문서 지도 — ${PROJECT}

## 현행 문서
| 경로 | 역할 | 읽을 시점 |
|---|---|---|
| \`CLAUDE.md\` | Tier1 범용 규칙(공용 정본 symlink) | 세션 시작(자동 로딩) |
| \`INFRA.md\` | 실행 환경(커밋 금지) | 빌드·배포·시험·접속 시(목차 Grep→절) |

## 보관 문서
| 경로 | 역할 | 읽을 시점 |
|---|---|---|
MAPEOF
  echo "✅ 생성: .claude/rules/docs-map.md"
fi

# 4) 정본 문서 골격(plan/) — Skill('ocanon') 규칙. 기본 dry-run 으로 제안 프로파일을 확인한 뒤 --apply
python3 -B ${HARNESS_HOME:-$HOME/.harness}/current/scripts/plan_init.py --project "$TARGET"
python3 -B ${HARNESS_HOME:-$HOME/.harness}/current/scripts/plan_init.py --project "$TARGET" --profile <제안값 또는 지정값> --apply
```

> plan_init 은 docs-map 에 색인 행을 넣으므로 위 3) 다음에 실행한다. 멱등이며 기존 파일을 덮어쓰지 않는다.
> `--profile` 은 dry-run 이 제안한 값(product|tool|small)을 기본으로 쓰고, 사용자가 프로젝트 성격을 밝혔으면 그 값을 쓴다. 적용 후 `plan_audit.py --project "$TARGET"` rc=0 을 확인한다.

### Step 5.7: bash 이동 alias 등록

`mars` 를 치면 Mars 폴더로 가는 것처럼, 프로젝트 이름만 쳐서 대상 폴더로 이동하는 alias 를 `~/.bashrc` 에 추가한다(2026-10-28 사용자 지시로 기본 단계화).

```yaml
alias_이름: 프로젝트명 소문자 (예: pd → pd, Mars → mars). 사용자가 이름을 지정하면 그 이름.
위치: ~/.bashrc 의 기존 프로젝트 alias 묶음(alias ai=/mars=/know= ... 줄들) 마지막 줄 바로 다음
형식: alias {이름}='cd {TARGET_PATH}'   # 기존 줄과 동일 형식
스킵_조건:
  - 같은 TARGET_PATH 로 가는 alias 가 이미 있으면 스킵 ("이미 존재: alias {이름} — 스킵")
  - 그 이름이 이미 다른 명령·alias·함수로 쓰이면 등록하지 않고 보고 (덮어쓰기 금지 — 다른 이름 제안)
수정_도구: oio file_edit (묶음 마지막 alias 줄을 old 로 잡아 그 뒤에 한 줄 추가)
```

```bash
# 사전 확인 — 둘 다 비어 있어야 추가한다
grep -nF "cd {TARGET_PATH}'" ~/.bashrc
bash -ic 'type {이름}' 2>&1 | tail -1     # "not found" 여야 함

# (oio file_edit 로 1줄 추가 후) 검증 — 새 셸에서 이동되는지 확인
bash -ic 'type {이름}; {이름}; pwd' 2>&1 | grep -v -e 'job control' -e 'process group'
# 기대: "{이름} is aliased to `cd {TARGET_PATH}'" + "{TARGET_PATH}"
```

> 이미 열려 있는 터미널에는 반영되지 않는다. 결과 보고에 `source ~/.bashrc` 또는 새 터미널 안내를 넣는다.

### Step 6: 검증

```bash
# 심볼릭링크 확인 (원본 없는 SKIP_NOSRC 항목은 없어도 정상)
for f in CLAUDE.md AGENTS.md .mcp.json; do
  ls -la "{TARGET_PATH}/$f"
done
ls -la "{TARGET_PATH}/.claude/settings.json"
ls -la "{TARGET_PATH}/.claude/settings.local.json"
ls -la "{TARGET_PATH}/.claude/commands"
ls -la "{TARGET_PATH}/.claude/skills"

# locks 디렉토리 확인
ls -la "{TARGET_PATH}/.claude/locks"

# INFRA.md·문서지도 확인 (git 저장소면 INFRA.md 추적 제외 rc=0 확인)
ls -la "{TARGET_PATH}/INFRA.md" "{TARGET_PATH}/.claude/rules/docs-map.md"
if git -C "{TARGET_PATH}" rev-parse --git-dir >/dev/null 2>&1; then
  git -C "{TARGET_PATH}" check-ignore -q INFRA.md && echo "✅ INFRA.md 추적 제외" || echo "❌ INFRA.md 추적 제외 실패"
fi

# 읽기 테스트
head -1 "{TARGET_PATH}/CLAUDE.md"

# 링크가 해석된 AI 루트를 가리키는지 확인 (다른 AI 사본으로 풀리면 실패)
readlink "{TARGET_PATH}/CLAUDE.md"   # 기대: <AI 루트>/CLAUDE.md (Step 1 JSON 의 ai_root)
ls -la "{TARGET_PATH}/.claude/hooks"

# 이동 alias 확인 (Step 5.7)
bash -ic 'type {이름}' 2>&1 | tail -1
```

### Step 7: 결과 보고 + 프로젝트 문서 안내

```yaml
출력_형식:
  완료_요약:
    - "✅ {TARGET_PATH} 기본 환경 구축 완료"
    - 심볼릭링크 최대 8개 (CLAUDE.md, AGENTS.md, .mcp.json, settings.json, settings.local.json, commands, skills, hooks) — ocopy_link.py JSON 요약 counts 의 LINK_OK·SKIP_EXISTS·SKIP_NOSRC 수를 함께 적는다
    - 실제 디렉토리 1개 (.claude/locks)
    - "✅ 이동 alias: {이름} → cd {TARGET_PATH} (~/.bashrc) — 열려 있는 터미널은 source ~/.bashrc 또는 새 터미널"

  프로젝트_문서_안내:
    - "✅ INFRA.md·문서지도 골격 자동 생성됨 (내용은 직접 채워야 함):"
    - "  - INFRA.md: 프로젝트 메타·빌드/실행/중지/배포/접속·API·로그·테스트 역량(커밋 금지)"
    - "  - 문서 지도: .claude/rules/docs-map.md (세션 시작 시 자동 로딩)"
    - "  - 정본 문서: plan/ (plan_init 프로파일 {profile} — README·index.json 등, 이후 문서는 사이클마다 주문형 추가)"
    - "📝 코딩 규칙은 {project}/PROJECT.md '코딩 규칙' 섹션에 기재"

  추가_안내:
    - "📝 PROJECT.md, ADVANCED.md, DATABASE.md 등 프로젝트 문서도 별도 생성 필요"
    - "📝 .claude/settings.json은 AI 원본 심볼릭링크 — 프로젝트별 커스터마이징 필요 시 링크 제거 후 독립 파일 생성"
    - "📝 .claude/settings.local.json도 AI 원본 심볼릭링크 — 프로젝트별 로컬 설정 필요 시 링크 제거 후 독립 파일 생성"
```

---

## 에러 처리

```yaml
이미_존재:
  - 하드링크/심볼릭링크 대상이 이미 존재하면 스킵 + 안내
  - "이미 존재: {파일명} — 스킵"

원본_없음:
  - AI 원본 파일/폴더가 없으면 경고 + 계속 진행
  - "⚠️ 원본 없음: {경로} — 스킵"

권한_오류:
  - NTFS 권한 문제 시 안내
  - "❌ 권한 오류: {경로} — 수동 확인 필요"
```

---

## .gitignore 안내

```yaml
안내_내용:
  - "대상 프로젝트의 .gitignore에 다음 추가 권장:"
  - "  CLAUDE.md"
  - "  AGENTS.md"
  - "  .mcp.json"
  - "  .claude/"
```

---

## 금지 사항

```yaml
금지:
  - 대상 프로젝트의 기존 파일 덮어쓰기
  - AI 원본 파일 수정
  - 링크 경로에 소문자 ai 사용 (대문자 AI로 통일)
  - 상대경로 ../AI/... 링크 (다른 파일시스템의 옛 AI 사본으로 풀릴 수 있음 — 해석된 AI 루트 절대경로만)
  - ocopy_link.py 를 거치지 않고 ln 으로 직접 링크 (덮어쓰기·경로 해석 규칙이 어긋남)
  - ~/.bashrc 의 기존 alias·다른 줄 수정 (이동 alias 1줄 추가만 허용)
```
