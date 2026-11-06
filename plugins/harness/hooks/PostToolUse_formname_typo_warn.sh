#!/bin/bash
# [훅] PostToolUse — Fn새창열기("X") 신규 추가 시 Mars.X 클래스 실존 경고
# 배경: Type.GetType("Mars."+fName) 은 클래스가 없으면 null 을 반환하고 예외를 던지지
#   않는다(1054 결함 유형). 이 hook 은 차단하지 않는다 — 기존 레거시 폼명 15건
#   (사이클131/132 실측: Browser/ST설정/ST전일상한가 등 주식 거래 시절 잔재)이
#   0000_메인.cs 에 이미 살아 있어 PreToolUse 차단은 그 파일 편집 자체를 봉쇄한다.
#   대신 "이번 편집으로 새로 추가된 줄"만 검사해 경고만 출력한다(exit 0, 작업 미차단).
# 2026-09-15 사이클131/132 odone_review 신설 (reviewer-A ⑦-2 설계).

set -uo pipefail
trap 'exit 0' ERR

INPUT=$(timeout 5 cat 2>/dev/null) || INPUT=""
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || echo "")

case "$TOOL_NAME" in
  Edit|mcp__oio__file_edit)
    FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // .tool_input.filepath // empty' 2>/dev/null || echo "")
    OLD_TEXT=$(echo "$INPUT" | jq -r '.tool_input.old_string // .tool_input.old // .tool_input.old_content // .tool_input.search // empty' 2>/dev/null || echo "")
    NEW_TEXT=$(echo "$INPUT" | jq -r '.tool_input.new_string // .tool_input.new // .tool_input.new_content // .tool_input.replace // empty' 2>/dev/null || echo "")
    ;;
  Write|mcp__oio__file_write)
    FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null || echo "")
    OLD_TEXT=""
    NEW_TEXT=$(echo "$INPUT" | jq -r '.tool_input.content // .tool_input.body // .tool_input.data // .tool_input.text // empty' 2>/dev/null || echo "")
    ;;
  *)
    exit 0
    ;;
esac

[[ -z "$FILE_PATH" ]] && exit 0
# MarsGW/, Mars.Shared/, Mars.Mobile/ 등을 "Mars/" 로 오매칭하지 않도록
# 디렉토리 세그먼트 경계까지 명시(바로 앞이 '/' 또는 문자열 시작, 바로 뒤가 '/').
if echo "$FILE_PATH" | grep -qP '(^|/)Mars/[^/]+\.cs$'; then
  :
else
  exit 0
fi
[[ -z "$NEW_TEXT" ]] && exit 0

# 검색 범위: Mars/ 폼 소스 디렉토리 자체로 한정(프로젝트 루트 전체 grep은
# TinyMCE 등 비-.cs 대용량 트리를 순회해 timeout(5s) 초과 위험 — NTFS 실측 rc=124)
PROJ_MARS_DIR=$(echo "$FILE_PATH" | grep -oP '^.*(^|/)Mars(?=/)' | head -1)
[[ -z "$PROJ_MARS_DIR" ]] && PROJ_MARS_DIR="Mars"
[[ ! -d "$PROJ_MARS_DIR" ]] && exit 0

# "새로 추가된 줄"만 추려서 검사 — Edit은 new_string 전체가 신규 추가분,
# 기존 old_string과 동일한 Fn새창열기 호출은 신규가 아니므로 old_string에 있으면 스킵.
NEW_CALLS=$(echo "$NEW_TEXT" | grep -oP 'Fn새창열기\("\K[^"]+' 2>/dev/null || true)
[[ -z "$NEW_CALLS" ]] && exit 0

OLD_CALLS=$(echo "$OLD_TEXT" | grep -oP 'Fn새창열기\("\K[^"]+' 2>/dev/null || true)

WARN_LIST=""
while IFS= read -r fname; do
  [[ -z "$fname" ]] && continue
  # old_string에 이미 있던 호출은 신규가 아니므로 스킵
  if echo "$OLD_CALLS" | grep -qxF "$fname"; then
    continue
  fi
  # Mars.<fname> 클래스 실존 확인 — timeout 5s로 대형 grep 폭주 방지
  # \b 는 PCRE 기본에서 한글 뒤 word boundary 로 동작하지 않아 사용하지 않는다(실측 확인).
  # grep 매칭 실패(rc=1)가 `set -e`+ERR trap을 발동시키지 않도록 `|| true` 필수
  FOUND=$(timeout 5 grep -rlP "class\s+${fname}(\s|:|\$)" "${PROJ_MARS_DIR}" --include="*.cs" 2>/dev/null | head -1) || true
  if [[ -z "$FOUND" ]]; then
    WARN_LIST="${WARN_LIST}${fname}, "
  fi
done <<< "$NEW_CALLS"

if [[ -n "$WARN_LIST" ]]; then
  WARN_LIST="${WARN_LIST%, }"
  echo "⚠️ [폼명 확인] Fn새창열기(\"${WARN_LIST}\") — 대응하는 Mars.X 클래스를 찾지 못했습니다. Type.GetType 이 null 을 반환해 런타임에 메뉴 클릭이 무반응(예외 없음)이 될 수 있습니다. 오타 여부를 확인하세요." >&2
fi

exit 0
