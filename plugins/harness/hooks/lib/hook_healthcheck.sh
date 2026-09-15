#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# hook_healthcheck.sh — Hook 파일 건전성 + 공유 자원 동일성 자동 점검
# 수동 유틸리티 — 필요 시 bash ~/.claude/hooks/hook_healthcheck.sh 직접 실행
# 항상 exit 0 (차단하지 않음)

HOOK_DIR="$HOME/.claude/hooks"
TOTAL=0
FIXED=0
ERRORS=0
ERROR_FILES=""

for f in "$HOOK_DIR"/*.sh; do
  [[ ! -f "$f" ]] && continue
  TOTAL=$((TOTAL + 1))

  # 1. CRLF 검사 및 자동 제거
  if grep -qP '\r' "$f" 2>/dev/null; then
    sed -i 's/\r$//' "$f"
    FIXED=$((FIXED + 1))
  fi

  # 2. 실행 권한 검사 및 자동 부여
  if [[ ! -x "$f" ]]; then
    chmod +x "$f"
    FIXED=$((FIXED + 1))
  fi

  # 3. bash 구문 검사
  if ! bash -n "$f" 2>/dev/null; then
    ERRORS=$((ERRORS + 1))
    ERROR_FILES="$ERROR_FILES $(basename "$f")"
  fi
done

# 결과 출력
if [[ $ERRORS -gt 0 ]]; then
  echo "❌ Hook 헬스체크: 구문 오류 ${ERRORS}개 — 수동 확인 필요:${ERROR_FILES}"
elif [[ $FIXED -gt 0 ]]; then
  echo "⚠️ Hook 헬스체크: ${FIXED}개 자동 수정 (CRLF/권한), 전체 ${TOTAL}개"
else
  echo "✅ Hook 헬스체크: 전체 정상 (${TOTAL}개 파일)"
fi

# ═══════════════════════════════════════════════════════════
# 4. CLAUDE.md 하드링크 동일성 검증
# ═══════════════════════════════════════════════════════════
PROJECT_BASE="/mnt/c/DATA/Project"
# 하드링크로 CLAUDE.md 를 공유하는 프로젝트 디렉토리명을 나열한다.
# 환경변수 HARNESS_LINKED_PROJECTS 로 재정의 가능 (공백 구분).
# 미설정 시 PROJECT_BASE 하위에서 .claude/ 를 가진 디렉토리를 자동 탐지한다.
if [[ -n "${HARNESS_LINKED_PROJECTS:-}" ]]; then
  read -r -a PROJECTS <<< "$HARNESS_LINKED_PROJECTS"
else
  PROJECTS=()
  for _d in "$PROJECT_BASE"/*/; do
    [[ -d "${_d}.claude" ]] && PROJECTS+=("$(basename "$_d")")
  done
fi
CLAUDE_INODES=""
CLAUDE_MISMATCH=false

for proj in "${PROJECTS[@]}"; do
  CFILE="$PROJECT_BASE/$proj/CLAUDE.md"
  if [[ -f "$CFILE" ]]; then
    INODE=$(stat --format="%i" "$CFILE" 2>/dev/null)
    CLAUDE_INODES="$CLAUDE_INODES $INODE"
  else
    CLAUDE_MISMATCH=true
    echo "⚠️ CLAUDE.md 누락: $proj"
  fi
done

UNIQUE_INODES=$(echo "$CLAUDE_INODES" | tr ' ' '\n' | sort -u | grep -v '^$' | wc -l)
if [[ "$UNIQUE_INODES" -gt 1 ]]; then
  CLAUDE_MISMATCH=true
  echo "🚨 CLAUDE.md 하드링크 불일치! inode:${CLAUDE_INODES}"
  echo "  → 원본 기준으로 재연결 필요: rm + ln \${원본프로젝트}/CLAUDE.md"
fi

if [[ "$CLAUDE_MISMATCH" == false ]] && [[ -n "$CLAUDE_INODES" ]]; then
  echo "✅ CLAUDE.md 하드링크: ${#PROJECTS[@]}개 프로젝트 동일 (inode:$(echo $CLAUDE_INODES | awk '{print $1}'))"
fi

# ═══════════════════════════════════════════════════════════
# 5. settings.json 등록 hook 파일 존재 검사 (L-113 재발방지)
# ═══════════════════════════════════════════════════════════
MISSING_HOOKS=""
MISSING_COUNT=0
SETTINGS_CHECKED=0

# user-level settings.json 검사 (hook 등록의 실제 소스)
USER_SETTINGS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
ALL_SETTINGS=("$USER_SETTINGS")

# 프로젝트별 settings.json도 검사
for proj in "${PROJECTS[@]}"; do
  PROJ_SETTINGS="$PROJECT_BASE/$proj/.claude/settings.json"
  [[ -f "$PROJ_SETTINGS" ]] && ALL_SETTINGS+=("$PROJ_SETTINGS")
done

for SETTINGS_FILE in "${ALL_SETTINGS[@]}"; do
  [[ ! -f "$SETTINGS_FILE" ]] && continue
  SETTINGS_CHECKED=$((SETTINGS_CHECKED + 1))
  LABEL=$(basename "$(dirname "$(dirname "$SETTINGS_FILE")")")

  while IFS= read -r cmd; do
    [[ -z "$cmd" ]] && continue
    if [[ ! -f "$cmd" ]]; then
      MISSING_HOOKS="$MISSING_HOOKS\n  ❌ [$LABEL] $cmd"
      MISSING_COUNT=$((MISSING_COUNT + 1))
    fi
  done < <(python3 -c "
import json, sys
with open('$SETTINGS_FILE') as f:
    d = json.load(f)
hooks = d.get('hooks', {})
for event, handlers in hooks.items():
    for h in handlers:
        for hook in h.get('hooks', []):
            cmd = hook.get('command', '')
            if cmd:
                print(cmd)
" 2>/dev/null)
done

if [[ $SETTINGS_CHECKED -gt 0 ]]; then
  if [[ $MISSING_COUNT -gt 0 ]]; then
    echo -e "🚨 settings.json 등록 hook 파일 누락 ${MISSING_COUNT}개 (→ PreToolUse hook error 원인):$MISSING_HOOKS"
    echo "  → 해당 hook을 생성하거나 settings.json에서 제거하세요"
  else
    echo "✅ settings.json hook 파일: 전체 존재 확인 (${SETTINGS_CHECKED}개 settings)"
  fi
fi

exit 0
