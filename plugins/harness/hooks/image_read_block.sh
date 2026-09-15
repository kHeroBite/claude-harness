#!/usr/bin/env bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# image_read_block.sh — PNG/JPG 등 이미지 Read 차단 (API 400 재발방지)
# PreToolUse hook (matcher=Read)
# 입력: stdin JSON {"tool_name":"Read","tool_input":{"file_path":"..."}}
#
# 2026-07-31 개정: 스크린샷 전용 디렉토리는 허용 (oss 스킬 복구).
#   허용 경로에서도 API 400의 실제 원인(용량/해상도 초과)은 계속 차단한다.
#   - 용량 4MB 초과 → 차단
#   - 가로/세로 8000px 초과 → 차단 (identify 있을 때만 검사)
#   - SVG는 허용 경로여도 항상 차단 (API 미지원 포맷)
set -euo pipefail

MAX_BYTES=4194304   # 4MB
MAX_DIM=8000        # px

INPUT="$(cat)"
TOOL="$(echo "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null || true)"
if [ "$TOOL" != "Read" ]; then
  exit 0  # Read 외에는 통과
fi

FILE_PATH="$(echo "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null || true)"
LOWER="${FILE_PATH,,}"

# 이미지가 아니면 통과
if [[ ! "$LOWER" =~ \.(png|jpg|jpeg|webp|gif|bmp|tiff?|heic|svg)$ ]]; then
  exit 0
fi

block() {
  printf '{"decision":"block","reason":%s}\n' "$(jq -Rn --arg m "$1" '$m')"
  exit 0
}

# SVG는 허용 경로여도 차단 (API가 받지 않는 포맷)
if [[ "$LOWER" =~ \.svg$ ]]; then
  block "🚫 SVG는 이미지로 전달 불가 — 텍스트로 읽거나 PNG로 변환하라. (image_read_block.sh)"
fi

# ── 허용 경로 (스크린샷 전용) ────────────────────────────────────────────
# 한국어 Windows + OneDrive KFM 경로(그림/스크린샷)도 허용해야 한다.
# 소문자 변환은 한글에 영향이 없으므로 $LOWER 매칭으로 함께 처리된다.
ALLOWED=0
case "$LOWER" in
  /tmp/screenshot/*)        ALLOWED=1 ;;
  /mnt/c/temp/cc/*)         ALLOWED=1 ;;
  /mnt/c/data/screenshot/*) ALLOWED=1 ;;   # 캡처 도구 자동저장 전용 폴더 (C:\DATA\ScreenShot)
  */pictures/screenshots/*) ALLOWED=1 ;;
  */그림/스크린샷/*)         ALLOWED=1 ;;
  */사진/스크린샷/*)         ALLOWED=1 ;;
esac

if [ "$ALLOWED" -eq 1 ]; then
  if [ ! -f "$FILE_PATH" ]; then
    exit 0  # 없는 파일은 Read가 알아서 오류 반환
  fi

  SIZE="$(stat -c%s "$FILE_PATH" 2>/dev/null || echo 0)"
  if [ "$SIZE" -gt "$MAX_BYTES" ]; then
    block "🚫 이미지 용량 초과 (${SIZE}B > ${MAX_BYTES}B) — API 400 방지. 크롭하거나 리사이즈 후 다시 읽어라. (image_read_block.sh)"
  fi

  if command -v identify >/dev/null 2>&1; then
    DIMS="$(identify -format '%w %h' "${FILE_PATH}[0]" 2>/dev/null || echo "")"
    if [ -n "$DIMS" ]; then
      W="${DIMS% *}"; H="${DIMS#* }"
      if [ "${W:-0}" -gt "$MAX_DIM" ] || [ "${H:-0}" -gt "$MAX_DIM" ]; then
        block "🚫 이미지 해상도 초과 (${W}x${H} > ${MAX_DIM}px) — API 400 방지. 크롭 후 다시 읽어라. (image_read_block.sh)"
      fi
    fi
  fi

  exit 0  # 허용
fi

# ── 그 외 모든 이미지 경로: 기존대로 차단 ────────────────────────────────
block "🚫 이미지 직접 읽기 금지 — API 400 재발방지. 경로만 보고하거나 UI Dump XML/logcat 텍스트로 변환하라. 스크린샷은 /tmp/screenshot/ 또는 Pictures/Screenshots/ 경유. (image_read_block.sh)"
