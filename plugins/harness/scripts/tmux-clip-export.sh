#!/bin/bash
# tmux paste-buffer를 Windows 클립보드(PowerShell Set-Clipboard)에 export (UTF-8 보존)
#
# 변천사:
#   v1: clip.exe 직접 — CJK + 이모지 깨짐 (Microsoft WSL #4852)
#   v2: iconv UTF-16LE → clip.exe — 한국어 Windows + 한국 코드페이지에서 일부 환경 깨짐 발생
#   v3 (현재): PowerShell Set-Clipboard + base64 전송
#       - base64로 인자 전달 → 명령줄 인코딩(시스템 코드페이지) 영향 0
#       - PS 안에서 UTF-8 byte stream을 직접 디코드 → Set-Clipboard에 Unicode string 전달
#       - 출처: https://medium.com/@socrateslee/unix-pipe-to-clipboard-with-wsl-and-in-utf-8-45f51f1ac81e
#               https://valarmorghulis.io/tech/202404-unix-pipe-to-clipboard-with-wsl-and-in-utf8/
#   fallback: PS 실패 시 iconv UTF-16LE + clip.exe (v2 방식 유지 — 일부 환경에서는 작동)
# [harness_bundle_build W1] Windows 클립보드 연동은 WSL 전용이다. 일반 리눅스에서는 아무것도 하지 않고 끝낸다(tmux 버퍼에는 그대로 남는다).
grep -qi microsoft /proc/version 2>/dev/null || exit 0

PS="/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
CLIP="/mnt/c/Windows/System32/clip.exe"

# 호출 패턴 1: hook (인자 없음, tmux save-buffer)
# 호출 패턴 2: 키 바인딩 (인자 "-", stdin 파이프)
if [ "${1:-}" = "-" ]; then
  CONTENT=$(cat)
else
  CONTENT=$(tmux save-buffer - 2>/dev/null)
fi

[ -z "$CONTENT" ] && exit 0

# v3: PowerShell + base64 (1순위)
if [ -x "$PS" ]; then
  B64=$(printf '%s' "$CONTENT" | base64 -w0 2>/dev/null)
  if [ -n "$B64" ]; then
    # PowerShell 안에서 UTF-8 byte stream을 디코드하여 Set-Clipboard
    # -EncodedCommand 사용 안 함 (UTF-16LE 인코딩 부담) — -Command + base64 문자열 인자
    "$PS" -NoProfile -NonInteractive -Command \
      "\$b = [Convert]::FromBase64String('$B64'); \$s = [System.Text.Encoding]::UTF8.GetString(\$b); Set-Clipboard -Value \$s" \
      </dev/null >/dev/null 2>&1 && exit 0
  fi
fi

# v2: iconv + clip.exe (fallback — PS 실패 시)
if [ -x "$CLIP" ]; then
  printf '%s' "$CONTENT" | iconv -f UTF-8 -t UTF-16LE 2>/dev/null | "$CLIP"
fi
