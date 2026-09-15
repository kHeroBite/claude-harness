#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# docker-compose.yml 수정 시 rtx5070-app 핵심 마운트 통합 검증 hook (L-RTX5070-33)
# 트리거: PostToolUse on Edit|Write|mcp__oio__file_edit|mcp__oio__file_write
# 동작: docker-compose.yml에 5개 핵심 마운트 중 1개라도 누락 시 stderr 경고 + exit 2

set -e

# stdin JSON에서 tool_input.file_path 추출 (jq fallback to grep)
INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | grep -oE '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*"file_path"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/')

# path 파라미터도 확인 (oio file_edit은 path 사용)
if [ -z "$FILE_PATH" ]; then
  FILE_PATH=$(echo "$INPUT" | grep -oE '"path"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*"path"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/')
fi

# 대상 파일 검사 (docker-compose.yml 또는 docker-compose.*.yml)
case "$FILE_PATH" in
  */docker-compose.yml|*/docker-compose.*.yml) ;;
  *) exit 0 ;;
esac

# RTX5070 프로젝트만 대상 (다른 프로젝트 docker-compose 영향 없음)
case "$FILE_PATH" in
  */RTX5070/*|*/rtx5070/*) ;;
  *) exit 0 ;;
esac

[ ! -f "$FILE_PATH" ] && exit 0

# rtx5070-app 서비스 블록에서 5개 핵심 마운트 통합 검증 (L-RTX5070-33)
REQUIRED_MOUNTS=(':/app/main.py' ':/app/api' ':/app/services' ':/app/config.py' ':/app/scripts' ':/app/src/models' ':/app/tests')
MISSING=()
for mount in "${REQUIRED_MOUNTS[@]}"; do
  if ! grep -q "$mount" "$FILE_PATH"; then
    MISSING+=("$mount")
  fi
done

if [ ${#MISSING[@]} -eq 0 ]; then
  exit 0
fi

# 위반 감지 (1개라도 누락 시)
cat >&2 <<EOF
[L-RTX5070-33/37] docker-compose.yml volumes에 핵심 마운트 ${#MISSING[@]}개 누락 감지
  누락: ${MISSING[*]}
  필수 7개: ${REQUIRED_MOUNTS[*]}
  근거: host 소스가 컨테이너 런타임에 영향을 미치는 모든 파일은 volumes 마운트 필수
  4차 재발 누적: L-RTX5070-23 → L-RTX5070-32 → L-RTX5070-33
  L-RTX5070-35 (models/ 마운트 강제화) + L-RTX5070-37 (tests/ 마운트 강제화) 추가
EOF
exit 2
