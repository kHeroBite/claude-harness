#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# user_feedback_detector.sh — 소스 C: 사용자 피드백 실시간 감지
# 호출: UserPromptSubmit.sh의 UserPromptSubmit에서 source
# 입력: 함수 인자 $1=사용자 입력 텍스트, $2=UUID
# 출력: 피드백 감지 시 errors.md에 기록

detect_user_feedback() {
  local input="$1"
  local uuid="$2"

  # 슬래시 명령 필터 — /ok, /o3 등 파이프라인 명령은 피드백 아님
  if echo "$input" | grep -qP '^\s*/([a-zA-Z][a-zA-Z0-9_-]*)(\s|$)'; then
    return 0
  fi

  # 피드백 키워드 패턴
  local feedback_patterns=(
    "틀렸" "잘못" "다시" "아니야" "아니잖아" "왜 이렇게"
    "왜 안" "안 되잖아" "고쳐" "수정해" "틀린 것 같"
    "실수" "오류" "잘못됐" "다르잖아" "아니라고"
    "아직도" "또 이렇게" "계속 이렇게" "왜 또"
    "wrong" "incorrect" "fix this" "you missed" "that's wrong"
    "no," "not what i" "that's not right" "you forgot"
  )
  
  local detected=false
  local matched_pattern=""
  
  for pattern in "${feedback_patterns[@]}"; do
    if echo "$input" | grep -qi "$pattern"; then
      detected=true
      matched_pattern="$pattern"
      break
    fi
  done
  
  [ "$detected" = false ] && return 0
  
  # errors.md 경로 (프로젝트별)
  local errors_file="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${uuid}/logs/errors.md"
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  local session_short="${uuid:0:8}"
  
  # 중복 방지: 최근 동일 입력 기록 여부 확인 (hash 단위)
  local input_hash=$(echo "$input" | md5sum | cut -c1-8)
  if [ -f "$errors_file" ]; then
    local recent=$(grep -c "hash:${input_hash}" "$errors_file" 2>/dev/null || echo 0)
    [ "$recent" -gt 0 ] && return 0
  fi

  # 패턴 cooldown: 동일 패턴이 60초 내에 재기록되지 않도록 차단 (재발 방지)
  # 위반 사례: 사용자가 "왜 자꾸 나오나?"라고 물을 만큼 같은 패턴이 errors.md에 누적되는 현상
  local cooldown_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${uuid}/logs/.feedback_cooldown"
  mkdir -p "$cooldown_dir" 2>/dev/null
  local pattern_key=$(echo -n "$matched_pattern" | md5sum | cut -c1-8)
  local cooldown_file="$cooldown_dir/${pattern_key}"
  if [ -f "$cooldown_file" ]; then
    local last_ts=$(cat "$cooldown_file" 2>/dev/null || echo 0)
    local now_ts=$(date +%s)
    local elapsed=$((now_ts - last_ts))
    if [ "$elapsed" -lt 60 ]; then
      # cooldown 활성: 동일 패턴 재기록 차단
      return 0
    fi
  fi
  # cooldown 갱신 (기록 직전)
  date +%s > "$cooldown_file"
  
  # 기록
  cat >> "$errors_file" << FEEDBACK_EOF

## [$(date '+%Y%m%d_%H%M%S')] USER_FEEDBACK — 소스C 사용자 피드백
- **시각**: ${timestamp}
- **세션**: ${session_short}
- **패턴**: ${matched_pattern}
- **입력 (앞 200자)**: $(echo "$input" | head -c 200)
- **hash**: ${input_hash}
- **상태**: 미처리
FEEDBACK_EOF
  
  echo "📝 [user_feedback_detector] 피드백 감지 → errors.md 기록 (패턴: $matched_pattern)"
}
