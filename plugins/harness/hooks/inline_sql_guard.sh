#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# [훅] PreToolUse — 폼 파일에 인라인 SQL 작성 차단
# 적용 대상: Edit|Write|mcp__serena__replace_symbol_body|insert_after_symbol|insert_before_symbol
# 허용 경로: */Queries/, ~/work/*/Queries/, ~/work/*Queries*.cs

set -euo pipefail
trap 'exit 0' ERR

INPUT=$(timeout 5 cat 2>/dev/null) || INPUT=""
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || echo "")

# Serena rename은 SQL과 무관 → 패스
if [[ "$TOOL_NAME" == "mcp__serena__rename_symbol" ]]; then
  exit 0
fi

# 수정 대상 파일 경로 추출
# [F-SQL-OWN-0 선결] mcp__oio__file_edit/file_write 는 CLAUDE.md 가 전 파일 I/O 의
# 유일 경로로 강제하는 도구인데, 이 case 에 누락돼 있으면 규칙을 지킬수록 이 hook 을
# 우회하게 된다(2026-09-15 사이클132 odone_review 실측 발견).
FILE_PATH=""
case "$TOOL_NAME" in
  Edit)
    FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || echo "")
    ;;
  Write)
    FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || echo "")
    ;;
  mcp__oio__file_edit)
    FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.filepath // .tool_input.path // empty' 2>/dev/null || echo "")
    ;;
  mcp__oio__file_write)
    FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null || echo "")
    ;;
  mcp__serena__replace_symbol_body|mcp__serena__insert_after_symbol|mcp__serena__insert_before_symbol)
    FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.filePath // empty' 2>/dev/null || echo "")
    ;;
  *)
    exit 0
    ;;
esac

# 파일 경로가 없으면 패스
if [[ -z "$FILE_PATH" ]]; then
  exit 0
fi

# .cs 파일만 검사
if [[ "$FILE_PATH" != *.cs ]]; then
  exit 0
fi

# 수정 내용(new_string/content/body) 추출 — Queries 예외 판정보다 먼저 뽑아둔다
# (F-SQL-OWN-1 이 Queries 파일 안의 UPDATE SET 절도 검사해야 하므로)
BASENAME=$(basename "$FILE_PATH")
DIRNAME=$(dirname "$FILE_PATH")
IS_QUERIES_FILE=0
if [[ "$DIRNAME" == *"/Queries"* || "$DIRNAME" == *"/Queries" || "$BASENAME" == *Queries*.cs ]]; then
  IS_QUERIES_FILE=1
fi

CONTENT=""
case "$TOOL_NAME" in
  Edit)
    CONTENT=$(echo "$INPUT" | jq -r '.tool_input.new_string // empty' 2>/dev/null || echo "")
    ;;
  Write)
    CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // empty' 2>/dev/null || echo "")
    ;;
  mcp__oio__file_edit)
    CONTENT=$(echo "$INPUT" | jq -r '.tool_input.new // .tool_input.new_content // .tool_input.new_string // .tool_input.new_text // .tool_input.replace // empty' 2>/dev/null || echo "")
    ;;
  mcp__oio__file_write)
    CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // .tool_input.body // .tool_input.data // .tool_input.text // .tool_input.new_content // .tool_input.new_text // empty' 2>/dev/null || echo "")
    ;;
  mcp__serena__replace_symbol_body|mcp__serena__insert_after_symbol|mcp__serena__insert_before_symbol)
    CONTENT=$(echo "$INPUT" | jq -r '.tool_input.body // .tool_input.newBody // empty' 2>/dev/null || echo "")
    ;;
esac

if [[ -z "$CONTENT" ]]; then
  exit 0
fi

# ─────────────────────────────────────────────────────────────────────────
# F-SQL-OWN-1 — 공유 테이블 소유 열 검증 (Queries 파일 전용, 2026-09-15 사이클131/132)
# 배경: t_setMenu 를 1009/1050 화면이 함께 갱신하는데 전체열 UPDATE 를 재사용하면
#   한쪽이 저장할 때 상대 화면의 열이 NULL 로 덮인다(L-1066). 대장(sql_column_owner.tsv)에
#   등재된 테이블의 UPDATE 문은 SET 절 열 집합이 어느 소유자 범위에도 완전 포함돼야 한다.
# 예외 규약: 그 줄에 `-- @sql-owner-exempt: 사유` 주석이 있으면 면제한다(옵션 B, 코드 무변경
#   상태에서 신설 — 사문 enum(MenuOp.Update/Insert) 제거는 이번 사이클 범위 밖으로 보류).
# ─────────────────────────────────────────────────────────────────────────
if [[ "$IS_QUERIES_FILE" -eq 1 ]]; then
  OWNER_TSV="${HARNESS_HOOK_DIR}/data/sql_column_owner.tsv"
  if [[ -f "$OWNER_TSV" ]]; then
    # UPDATE <테이블> SET <열목록> 패턴을 대소문자 무시로 전부 추출
    UPPER_FOR_OWN=$(echo "$CONTENT" | tr '[:lower:]' '[:upper:]')
    while IFS=$'\t' read -r OWN_TABLE OWN_FORM OWN_COLS; do
      [[ -z "$OWN_TABLE" || "$OWN_TABLE" == \#* ]] && continue
      OWN_TABLE_UP=$(echo "$OWN_TABLE" | tr '[:lower:]' '[:upper:]')
      if echo "$UPPER_FOR_OWN" | grep -qP "UPDATE\s+${OWN_TABLE_UP}\s+SET\s+"; then
        # 면제 주석이 있으면 스킵
        if echo "$CONTENT" | grep -qP -- '--\s*@sql-owner-exempt:'; then
          continue
        fi
        # SET 절에서 실제 등장한 열 이름들을 대장의 각 소유자 열집합과 대조.
        # 완전한 SQL 파서가 아니라 문자열 매칭이므로, 대장에 등재된 모든 소유자
        # 열집합 중 하나라도 "그 소유자 열이 아닌 다른 소유자 전용 열"이 SET 절에
        # 함께 등장하면 위반으로 본다(단순화된 교차 오염 탐지).
        VIOLATION=0
        # 이 테이블의 모든 소유자 행을 모아 "각 열이 어느 소유자 소속인지" 맵을 만들고,
        # SET 절에 두 소유자 이상의 전용열이 동시에 등장하면 위반 처리.
        ALL_OWNERS_FOR_TABLE=$(grep -P "^${OWN_TABLE}\t" "$OWNER_TSV" 2>/dev/null || true)
        OWNERS_HIT=""
        while IFS=$'\t' read -r _T _F _COLS; do
          [[ -z "$_T" ]] && continue
          IFS=',' read -ra COL_ARR <<EOF_COLS
$_COLS
EOF_COLS
          for col in "${COL_ARR[@]}"; do
            col_up=$(echo "$col" | tr '[:lower:]' '[:upper:]')
            if echo "$UPPER_FOR_OWN" | grep -qP "\b${col_up}\s*="; then
              if [[ "$OWNERS_HIT" != *"|${_F}|"* ]]; then
                OWNERS_HIT="${OWNERS_HIT}|${_F}|"
              fi
            fi
          done
        done <<< "$ALL_OWNERS_FOR_TABLE"
        OWNER_COUNT=$(echo "$OWNERS_HIT" | grep -oP '\|[^|]+\|' | sort -u | wc -l)
        if [[ "$OWNER_COUNT" -ge 2 ]]; then
          source ${HARNESS_HOOK_DIR}/lib/write_error.sh
          log_hook_error "HOOK_BLOCK_SQL_OWN" "$TOOL_NAME" "테이블($OWN_TABLE) UPDATE 가 복수 소유자 전용열을 동시 SET" "$SESSION_ID"
          echo "{\"decision\":\"block\",\"reason\":\"🚨 [F-SQL-OWN-1] 테이블 ${OWN_TABLE} 의 UPDATE 가 소유자가 다른 열을 동시에 SET 합니다(대장: ${OWNERS_HIT}). 각 화면은 자신이 소유한 열만 SET 하는 전용 쿼리로 분리하세요(예: UpdateNoAi/UpdateAiOnly). 정당한 이유가 있으면 -- @sql-owner-exempt: 사유 주석을 그 줄에 추가하세요.\"}" | tee /dev/stderr
          exit 2
        fi
      fi
    done < "$OWNER_TSV"
  fi
fi

if [[ "$IS_QUERIES_FILE" -eq 1 ]]; then
  exit 0
fi

# SQL 키워드 패턴 감지 (대소문자 무시)
# SELECT ... FROM, INSERT INTO, UPDATE ... SET, DELETE FROM 패턴
UPPER_CONTENT=$(echo "$CONTENT" | tr '[:lower:]' '[:upper:]')

HAS_SQL=0
if echo "$UPPER_CONTENT" | grep -qP 'SELECT\s+.+\s+FROM\s+'; then
  HAS_SQL=1
elif echo "$UPPER_CONTENT" | grep -qP 'INSERT\s+INTO\s+'; then
  HAS_SQL=1
elif echo "$UPPER_CONTENT" | grep -qP 'UPDATE\s+\S+\s+SET\s+'; then
  HAS_SQL=1
elif echo "$UPPER_CONTENT" | grep -qP 'DELETE\s+FROM\s+'; then
  HAS_SQL=1
fi

if [[ "$HAS_SQL" -eq 1 ]]; then
  # 허용 예외: Queries 클래스 참조만 하는 경우 (문자열이 아닌 코드)
  # DashboardQueries.XXX, MemberQueries.XXX 등의 참조는 SQL이 아닌 코드
  # 실제 SQL 문자열은 따옴표 안에 있음 → @" 또는 $@" 또는 $" 또는 " 로 시작
  if echo "$CONTENT" | grep -qP '(@"|(\$@"|(\$")|"))\s*(SELECT|INSERT|UPDATE|DELETE)'; then
    source ${HARNESS_HOOK_DIR}/lib/write_error.sh
    log_hook_error "HOOK_BLOCK_INLINE_SQL" "$TOOL_NAME" "폼 파일($BASENAME)에 인라인 SQL 작성 시도" "$SESSION_ID"
    echo "{\"decision\":\"block\",\"reason\":\"🚨 인라인 SQL 차단! 폼 파일($BASENAME)에 SQL 문자열 직접 작성 금지. 공유 라이브러리 Queries/ 에 const/빌더로 정의 후 참조하세요. 규칙: orules_{project} 'SQL 위치 규칙' 참조.\"}" | tee /dev/stderr
    exit 2
  fi
fi

exit 0
