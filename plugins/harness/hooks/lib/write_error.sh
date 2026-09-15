#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# write_error.sh — UUID 기반 공통 에러 기록 라이브러리
# PreToolUse hook 등에서 source하여 사용
# 함수: init_error_md / write_error / write_user_request
# 경로: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/logs/errors.md

# ─────────────────────────────────────────────
# _get_error_log: UUID 기반 에러 로그 경로 반환
# SESSION_ID를 full UUID로 사용 (12자 슬라이스 제거)
# ─────────────────────────────────────────────
_get_error_log() {
  local session_id="${1:-${SESSION_ID:-unknown}}"
  local uuid="$session_id"
  local log_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${uuid}/logs"
  mkdir -p "$log_dir" 2>/dev/null
  echo "${log_dir}/errors.md"
}

# ─────────────────────────────────────────────
# init_error_md: error md 헤더 초기화
# 인자: $1=OOID  $2=SESSION_ID  $3=TRANSCRIPT_PATH(optional)
# ─────────────────────────────────────────────
init_error_md() {
  local ooid="${1:-unknown}"
  local session_id="${2:-unknown}"
  local transcript_path="${3:-}"

  local error_log
  error_log=$(_get_error_log "$session_id")
  local uuid="$session_id"

  # 이미 존재하면 헤더 재생성 안 함
  if [ -f "$error_log" ]; then
    return 0
  fi

  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')

  cat > "$error_log" << HEADER
# 오류 추적 로그
- 세션: ${uuid}
- ooid: ${ooid}
- 생성: ${timestamp}
- 트랜스크립트: ${transcript_path:-없음}

---

HEADER
}

# ─────────────────────────────────────────────
# write_error: 에러 항목 추가
# 인자: $1=CATEGORY  $2=MESSAGE  $3=TOOL(optional)  $4=SKILL(optional)
# ─────────────────────────────────────────────
write_error() {
  local category="${1:-UNKNOWN}"
  local message="${2:-}"
  local tool="${3:-Skill}"
  local skill="${4:-}"

  local error_log
  error_log=$(_get_error_log)

  # 파일 없으면 간단한 헤더 생성
  if [ ! -f "$error_log" ]; then
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    local uuid="$SESSION_ID"
    printf "# 오류 추적 로그\n- 세션: %s\n- 생성: %s\n\n---\n\n" \
      "$uuid" "$ts" > "$error_log"
  fi

  # 에러 순번 (grep -c는 매칭 없을 때 exit 1 → "0\n0" 문제 방지)
  local err_count=0
  if [ -f "$error_log" ]; then
    err_count=$(grep -c '^### ERR-' "$error_log" 2>/dev/null) || err_count=0
  fi
  local err_id=$((err_count + 1))
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')

  # HOOK_BLOCK 카테고리는 "정상 차단(방어 성공)"이므로 즉시 해결 처리
  local status="**미해결**"
  if [[ "$category" == HOOK_BLOCK* ]]; then
    status="**해결됨(정상차단)**"
  fi

  cat >> "$error_log" << ENTRY
### ERR-${err_id}: ${category}
- 시각: ${ts}
- 도구: ${tool}${skill:+
- 스킬: ${skill}}
- 상세:
\`\`\`
$(echo "$message" | head -c 500)
\`\`\`
- 상태: ${status}

---

ENTRY
}

# ─────────────────────────────────────────────
# write_user_request: 사용자 요청 원문 기록 (ok 진입 시)
# 인자: $1=SESSION_ID  $2=PROMPT_TEXT  $3=OOID(optional)
# ─────────────────────────────────────────────
write_user_request() {
  local session_id="${1:-}"
  local prompt_text="${2:-}"
  local ooid="${3:-unknown}"

  if [ -z "$session_id" ]; then
    session_id="${SESSION_ID:-unknown}"
  fi

  local error_log
  error_log=$(_get_error_log "$session_id")
  local uuid="$session_id"

  # 파일 없으면 헤더 생성
  if [ ! -f "$error_log" ]; then
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    printf "# 오류 추적 로그\n- 세션: %s\n- 생성: %s\n\n---\n\n" \
      "$uuid" "$ts" > "$error_log"
  fi

  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')

  # 요청 순번 (USER_REQ- 패턴)
  local req_count=0
  req_count=$(grep -c '^## USER_REQ-' "$error_log" 2>/dev/null) || req_count=0
  local req_id=$((req_count + 1))

  cat >> "$error_log" << REQ
## USER_REQ-${req_id} [${ts}]
- ooid: ${ooid}
- 요청:
\`\`\`
$(echo "$prompt_text" | head -c 2000)
\`\`\`

---

REQ
}

# ─────────────────────────────────────────────
# log_hook_error: hook 파일에서 호출하는 래퍼 함수
# 인자: $1=CATEGORY  $2=TOOL_NAME  $3=REASON  $4=SESSION_ID
# 내부에서 write_error() 호출 (SESSION_ID를 파라미터로 받아 처리)
# ─────────────────────────────────────────────
log_hook_error() {
  local category="${1:-UNKNOWN}"
  local tool_name="${2:-Bash}"
  local reason="${3:-}"
  local session_id="${4:-${SESSION_ID:-unknown}}"

  # write_error()는 SESSION_ID 환경변수를 참조하므로 임시 설정
  local _prev_session_id="${SESSION_ID:-}"
  SESSION_ID="$session_id"

  write_error "$category" "$reason" "$tool_name"

  # 복원
  SESSION_ID="$_prev_session_id"

  # stderr 출력 없음 — Claude Code는 훅의 stderr를 "hook error"로 표시하므로 전면 금지
  # decision:block의 reason은 stdout JSON으로 Claude에게 전달됨 (stderr 불필요)
  # 오류 기록은 write_error()가 ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/logs/errors.md에 저장함
}

# ─────────────────────────────────────────────
# fix_hook_block_errors: 기존 errors.md의 미해결 HOOK_BLOCK 에러 일괄 해결 처리
# 인자: $1=SESSION_ID (optional, 기본값: $SESSION_ID 환경변수)
# 용도: 이전에 기록된 HOOK_BLOCK 에러 중 미해결 상태인 것을 일괄 해결 마킹
# ─────────────────────────────────────────────
fix_hook_block_errors() {
  local session_id="${1:-${SESSION_ID:-}}"

  # [P2-isolation] §(a) 방어: session_id 없이 전체 세션 순회 금지 — fail-closed (Fix 20, 2026-04-24)
  if [[ -z "${session_id:-}" ]]; then
    echo "[write_error] fix_hook_block_errors: session_id 필수 — 전체 세션 수정 금지" >&2
    return 1
  fi

  # 특정 세션 지정 시 해당 세션만, 미지정 시 전체 세션 대상
  local session_dirs=()
  local base_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env"

  if [ -n "$session_id" ]; then
    session_dirs=("${base_dir}/${session_id}")
  else
    # [P2-isolation] §(a) DEAD CODE — 위의 fail-closed guard(Fix 20)로 절대 도달 불가 (2026-04-24)
    # 이 else 브랜치(전체 세션 errors.md 순회)는 session_id 없으면 return 1이 선행하므로 실행 안됨.
    # 향후 guard 제거 시 §(a) 위반 발생 — 절대 guard 제거 금지.
    # 전체 세션 디렉토리 순회
    if [ -d "$base_dir" ]; then
      for d in "$base_dir"/*/; do
        [ -d "$d" ] && session_dirs+=("${d%/}")
      done
    fi
  fi

  local fixed_count=0
  for sdir in "${session_dirs[@]}"; do
    local elog="${sdir}/logs/errors.md"
    [ -f "$elog" ] || continue

    # HOOK_BLOCK 패턴이 있고 미해결인 항목이 있는지 확인
    if grep -q 'HOOK_BLOCK' "$elog" && grep -q '상태: \*\*미해결\*\*' "$elog"; then
      # Python으로 ERR 블록 단위 파싱 — HOOK_BLOCK 헤더를 가진 블록만 정확히 처리
      python3 - "$elog" << 'PYEOF'
import sys, re

path = sys.argv[1]
with open(path, encoding='utf-8') as f:
    content = f.read()

# ERR 블록을 ### ERR-N: ... ~ --- 단위로 분리
# 각 블록에서 헤더(### ERR-N: HOOK_BLOCK*)이면 미해결→해결됨(정상차단) 치환
def fix_blocks(text):
    # 블록 경계: ### ERR-N: 또는 ### ERR-N이 시작하는 줄
    block_pattern = re.compile(r'(### ERR-\d+:.*?)(?=### ERR-\d+:|\Z)', re.DOTALL)
    def replace_block(m):
        block = m.group(0)
        # 이 블록의 헤더 라인에 HOOK_BLOCK이 있는지 확인
        first_line = block.split('\n', 1)[0]
        if 'HOOK_BLOCK' in first_line:
            block = block.replace('상태: **미해결**', '상태: **해결됨(정상차단)**')
        return block
    return block_pattern.sub(replace_block, text)

new_content = fix_blocks(content)
if new_content != content:
    with open(path, 'w', encoding='utf-8') as f:
        f.write(new_content)
PYEOF
      fixed_count=$((fixed_count + 1))
    fi
  done

  if [ "$fixed_count" -gt 0 ]; then
    echo "fix_hook_block_errors: ${fixed_count}개 세션의 HOOK_BLOCK 에러 일괄 해결 처리 완료"
  fi
}
