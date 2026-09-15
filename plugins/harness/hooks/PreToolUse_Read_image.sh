#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# PreToolUse_Read_image.sh — Read 도구 이미지 크기 차단 (재발방지)
# PreToolUse hook: Read 도구로 이미지 파일 열 때 1MB 이상이면 block
# 배경: 1.9MB PNG → base64 ~2.6MB → Claude API 400 "Could not process image"
# 공식 한계: 최대 5MB / 8000x8000px (출처: platform.claude.com/docs/en/build-with-claude/vision)
# 그러나 실제 Claude Code Read는 base64 인코딩 후 요청 크기로 인해 더 작은 이미지에서도 실패
# → 1MB 이상 이미지는 mcp__oio__image_resize 또는 python/convert 사용 권고

trap 'exit 0' ERR

# stdin JSON 파싱
INPUT=$(timeout 2 cat 2>/dev/null) || INPUT=""
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null) || TOOL_NAME=""

# Read 도구가 아니면 즉시 통과
if [ "$TOOL_NAME" != "Read" ] && [ "$TOOL_NAME" != "mcp__oio__file_read" ]; then
    exit 0
fi

# file_path 추출 (tool_name별 키 다름)
if [ "$TOOL_NAME" = "Read" ]; then
    FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null) || FILE_PATH=""
else
    # mcp__oio__file_read: path / filepath / file_path 폴백 체인
    FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.path // .tool_input.filepath // .tool_input.file_path // empty' 2>/dev/null) || FILE_PATH=""
fi

if [ -z "$FILE_PATH" ]; then
    exit 0
fi

# 이미지 확장자 체크 (.png / .jpg / .jpeg / .webp / .gif)
LOWER_PATH=$(echo "$FILE_PATH" | tr '[:upper:]' '[:lower:]')
case "$LOWER_PATH" in
    *.png|*.jpg|*.jpeg|*.webp|*.gif)
        # 이미지 파일 — 크기 확인
        ;;
    *)
        # 이미지 아님 — 통과
        exit 0
        ;;
esac

# 파일 존재 확인
if [ ! -f "$FILE_PATH" ]; then
    exit 0
fi

# 파일 크기 확인 (바이트)
FILE_SIZE=$(stat -c%s "$FILE_PATH" 2>/dev/null) || FILE_SIZE=0

# 1MB = 1048576 바이트 임계값
THRESHOLD=1048576

if [ "$FILE_SIZE" -lt "$THRESHOLD" ]; then
    # 1MB 미만 — 통과
    exit 0
fi

# 크기 초과 — block 응답
SIZE_MB=$(echo "scale=2; $FILE_SIZE / 1048576" | bc 2>/dev/null) || SIZE_MB="?"

# 리사이즈 경로 제안 (확장자 보존)
BASE_NAME=$(basename "$FILE_PATH")
DIR_NAME=$(dirname "$FILE_PATH")
EXT="${BASE_NAME##*.}"
NO_EXT="${BASE_NAME%.*}"
SMALL_PATH="${DIR_NAME}/${NO_EXT}_small.${EXT}"

# block reason prefix (tool_name별 분기)
if [ "$TOOL_NAME" = "Read" ]; then
    BLOCK_PREFIX="[Read 이미지 차단]"
else
    BLOCK_PREFIX="[oio file_read 이미지 차단]"
fi

echo "{\"decision\":\"block\",\"reason\":\"🚫 ${BLOCK_PREFIX} ${FILE_PATH}\\n크기: ${SIZE_MB}MB — Claude API 400 \\\"Could not process image\\\" 유발 임계 초과.\\n\\n▶ 해결: mcp__oio__image_resize 도구로 리사이즈 후 Read 하라:\\n  {\\\"path\\\": \\\"${FILE_PATH}\\\", \\\"output_path\\\": \\\"${SMALL_PATH}\\\", \\\"max_width\\\": 1280, \\\"max_height\\\": 720}\\n\\n▶ 대안 (Python): python3 -c \\\"from PIL import Image; img=Image.open('${FILE_PATH}'); img.thumbnail((1280,720)); img.save('${SMALL_PATH}')\\\"\\n\\n그 후: Read '${SMALL_PATH}'\"}" | tee /dev/stderr

exit 2
