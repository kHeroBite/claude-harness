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
  - /ocopy tmuxMon           # 프로젝트명 → /mnt/c/DATA/Project/tmuxMon
  - /ocopy /mnt/c/DATA/Project/tmuxMon  # 절대경로 직접 지정

자연어:
  - "tmuxMon 프로젝트에 기본환경 구축해줘"
  - "/mnt/c/DATA/Project/tmuxMon 에 기본환경 구축해줘"
```

---

## 인자 파싱

```yaml
규칙:
  1. 절대경로 (/로 시작): 그대로 사용
  2. 프로젝트명 (단어): /mnt/c/DATA/Project/{프로젝트명} 으로 변환
  3. 인자 없음: 사용자에게 프로젝트명 질문
```

---

## AI 원본 경로

```yaml
원본: /mnt/c/DATA/Project/AI/   # 대문자 AI — 링크 경로 표기 대문자로 통일
```

---

## 링크 대상

### 심볼릭링크 (전체 — ln -s, 상대경로)

| 원본 | 대상 | 상대경로 |
|------|------|----------|
| `AI/CLAUDE.md` | `{대상}/CLAUDE.md` | `../AI/CLAUDE.md` |
| `AI/CLAUDE.md` | `{대상}/AGENTS.md` | `../AI/CLAUDE.md` |
| `AI/.mcp.json` | `{대상}/.mcp.json` | `../AI/.mcp.json` |
| `AI/.claude/settings.json` | `{대상}/.claude/settings.json` | `../../AI/.claude/settings.json` |
| `AI/.claude/settings.local.json` | `{대상}/.claude/settings.local.json` | `../../AI/.claude/settings.local.json` |
| `AI/.claude/commands` | `{대상}/.claude/commands` | `../../AI/.claude/commands` |
| `AI/.claude/skills` | `{대상}/.claude/skills` | `../../AI/.claude/skills` |
| `~/.claude/hooks` | `{대상}/.claude/hooks` | `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks` (절대경로) |

> **모든 공용 파일을 심볼릭링크로 통일**: AI 원본 수정 시 전체 프로젝트에 즉시 반영.
> **상대경로 사용**: `../AI/...` 형태로 이식성 확보. 대문자 `AI` 통일 필수 (기존 프로젝트 실측 기준).
> **hooks는 절대경로 symlink 필수** (2026-05-02): settings.json hook command가 매크로(`$CLAUDE_PROJECT_DIR/...`)에서 절대경로로 전환된 후, 활성 세션이 옛 매크로 캐시를 들고 호출하면 프로젝트 로컬 `.claude/hooks/`로 fallback됨. symlink가 없으면 22일간 6개 프로젝트 1,122회 silent fail 같은 사고 재발. (출처: settings_changelog.md 2026-05-02)

---

## 실행 절차

### Step 1: 대상 경로 결정

```yaml
입력: 사용자 인자 (프로젝트명 또는 절대경로)
출력: TARGET_PATH (절대경로)
변환: 프로젝트명이면 /mnt/c/DATA/Project/{프로젝트명}
```

### Step 2: 디렉토리 준비

```bash
# 프로젝트 루트
mkdir -p "{TARGET_PATH}"

# .claude 디렉토리 (skills는 심볼릭링크로 생성되므로 mkdir 불필요)
mkdir -p "{TARGET_PATH}/.claude"
```

### Step 3: 심볼릭링크 생성 (일괄)

```bash
cd "{TARGET_PATH}"

# 프로젝트 루트 파일 (상대경로, 대문자 AI)
[ -L CLAUDE.md ] || ln -s ../AI/CLAUDE.md CLAUDE.md
[ -L AGENTS.md ] || ln -s ../AI/CLAUDE.md AGENTS.md
[ -L .mcp.json ] || ln -s ../AI/.mcp.json .mcp.json

# .claude 내부 파일 (상대경로, 대문자 AI)
[ -L .claude/settings.json ] || ln -s ../../AI/.claude/settings.json .claude/settings.json
[ -L .claude/settings.local.json ] || ln -s ../../AI/.claude/settings.local.json .claude/settings.local.json

# .claude 내부 폴더 (상대경로, 대문자 AI)
[ -L .claude/commands ] || ln -s ../../AI/.claude/commands .claude/commands
[ -L .claude/skills ] || ln -s ../../AI/.claude/skills .claude/skills

# .claude/hooks symlink (절대경로 — 2026-05-02 hook 캐시 fallback 사고 재발방지)
[ -L .claude/hooks ] || ln -sfn "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks" .claude/hooks

# .claude/locks 디렉토리 생성 (모든 프로젝트 공통)
mkdir -p .claude/locks
```

> 이미 심볼릭링크면 스킵.
> **hooks는 절대경로 symlink 필수**: settings.json hook 캐시 fallback이 프로젝트 로컬 .claude/hooks/로 가는 사고를 방지 (2026-05-02 1,122회 silent fail 종식 조치).
> `locks/`는 파이프라인 잠금 파일 저장소 — 항상 실제 디렉토리로 생성.

### Step 5.5: 프로젝트스킬 빈 파일 생성

프로젝트명({project})을 인자에서 추출하여 `oinfra_{project}` 프로젝트스킬 파일을 빈 내용으로 생성.

> **변경 이력 (2026-04-09)**: obuild_/orun_/orules_ 스킬은 oinfra_에 통합되어 제거됨. 코딩 규칙은 각 프로젝트 PROJECT.md에 기재.

```bash
PROJECT="{project}"  # 인자에서 추출한 프로젝트명 (예: rtx5070)
SKILLS_DIR="/mnt/c/DATA/Project/AI/.claude/skills"

skill="oinfra_${PROJECT}"
SKILL_DIR="$SKILLS_DIR/$skill"
if [ -d "$SKILL_DIR" ]; then
  echo "이미 존재: $skill — 스킵"
else
  mkdir -p "$SKILL_DIR"
  cat > "$SKILL_DIR/SKILL.md" << SKILLEOF
# ${skill} — TODO

> 프로젝트스킬 자동 생성됨. 내용을 채워주세요.
> 빌드/실행/중지/배포/접속 방법 + 코딩 규칙 참조 포함.
SKILLEOF
  echo "✅ 생성: $skill/SKILL.md"
fi
```

### Step 6: 검증

```bash
# 심볼릭링크 확인 (전체 7개)
for f in CLAUDE.md AGENTS.md .mcp.json; do
  ls -la "{TARGET_PATH}/$f"
done
ls -la "{TARGET_PATH}/.claude/settings.json"
ls -la "{TARGET_PATH}/.claude/settings.local.json"
ls -la "{TARGET_PATH}/.claude/commands"
ls -la "{TARGET_PATH}/.claude/skills"

# locks 디렉토리 확인
ls -la "{TARGET_PATH}/.claude/locks"

# 읽기 테스트
head -1 "{TARGET_PATH}/CLAUDE.md"
```

### Step 7: 결과 보고 + 프로젝트스킬 안내

```yaml
출력_형식:
  완료_요약:
    - "✅ {TARGET_PATH} 기본 환경 구축 완료"
    - 심볼릭링크 7개 (CLAUDE.md, AGENTS.md, .mcp.json, settings.json, settings.local.json, commands, skills)
    - 실제 디렉토리 1개 (.claude/locks)

  프로젝트스킬_안내:
    - "✅ 프로젝트스킬 빈 파일 자동 생성됨 (내용은 직접 채워야 함):"
    - "  - oinfra_{project}: 프로젝트 메타, 빌드/실행/중지/배포/접속 방법, API, 로그, MCP 설정"
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
```
