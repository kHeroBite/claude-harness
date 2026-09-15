#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# 한자/일본어 혼용 차단 가드 — 모든 에이전트 최종 출력 검증

readonly FORBIDDEN_PATTERNS=(
  '完了'           # 완료 (일본어 한자)
  '送信'           # 송신 (한자)
  '再'             # 재 (일본어 한자)
  '検証'           # 검증 (일본어 한자)
  '報告'           # 보고 (일본어 한자)
  '確認'           # 확인 (일본어 한자)
  '提出'           # 제출 (일본어 한자)
  '処理'           # 처리 (일본어 한자)
  '実行'           # 실행 (일본어 한자)
  '開始'           # 개시 (일본어 한자)
  '終了'           # 종료 (일본어 한자)
  '削除'           # 삭제 (일본어 한자)
  '更新'           # 갱신 (일본어 한자)
  '作成'           # 작성 (일본어 한자)
)

check_korean_only() {
  local text="$1"
  local found_violation=0
  
  for pattern in "${FORBIDDEN_PATTERNS[@]}"; do
    if echo "$text" | grep -q "$pattern"; then
      echo "❌ 한자 혼용 감지: $pattern" >&2
      found_violation=1
    fi
  done
  
  return $found_violation
}

# 메인 에이전트 최종 출력 직전 호출
# 사용: check_korean_only "$(cat final_output.txt)" || exit 1

export -f check_korean_only
