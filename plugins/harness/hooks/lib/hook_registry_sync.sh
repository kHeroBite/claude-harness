#!/bin/bash
# 정본(AI) settings.json 의 범용 hook 등록을 REGULAR 파생본 전체에 자동 동기화하는 라이브러리.
# 배경: hook 신규 생성 시 한 프로젝트에만 등록해 정책이 갈리는 드리프트를 물리적으로 소멸시킨다.
#       사전 차단(PreToolUse)은 구조적으로 불가능하다 — 6개 파일 등록은 6회 개별 쓰기이므로
#       첫 쓰기 시점에 나머지가 미등록인 것이 정상 상태이고, 이를 block 하면 등록 자체가 막힌다.
#       따라서 "드리프트 발생"이 아니라 "드리프트 잔존"을 불가능하게 만드는 사후 집행 방식을 쓴다.
# 연관: L-578 (문서/경고만으로는 재발방지 실패 실증) · 2026-05-02 settings.json hooks 변경 정책

HOOK_REGISTRY_SYNC_PY="${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/hook_registry_sync.py"

# 정본 대비 파생본 드리프트를 감지하고 자동 반영한다.
# 인자: 없음. 출력: 변경이 있을 때만 stdout 요약. 반환: 항상 0 (세션 시작을 막지 않는다).
hook_registry_sync() {
  local canon="${HARNESS_HOME:-$HOME/.harness}/current/.claude/settings.json"
  [[ -f "$canon" ]] || return 0
  [[ -f "$HOOK_REGISTRY_SYNC_PY" ]] || return 0
  command -v python3 >/dev/null 2>&1 || return 0

  # 세션당 1회만 (멱등성)
  if [[ -n "$CURRENT_UUID" ]]; then
    local stamp="${SESSION_ENV}/${CURRENT_UUID}/hook_registry_synced"
    [[ -f "$stamp" ]] && return 0
    mkdir -p "$(dirname "$stamp")" 2>/dev/null
    touch "$stamp" 2>/dev/null
    # 사이클143 축② — 반대편 base 미러. 이 스탬프는 "세션당 1회" 멱등성의 근거이므로
    # 한쪽에만 남으면 반대편 base 로 읽는 경로에서 동기화가 중복 실행된다.
    source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/session_mirror.sh" 2>/dev/null
    declare -F _mirror_file >/dev/null 2>&1 && _mirror_file "$stamp"
  fi

  local out rc
  out=$(python3 "$HOOK_REGISTRY_SYNC_PY" --apply 2>&1)
  rc=$?
  if [[ $rc -eq 10 ]]; then
    echo "🔧 [hook 등록 자동 동기화] 정본(AI) 대비 파생본 드리프트를 반영했습니다."
    echo "$out" | sed 's/^/    /'
    echo "    ⚠️ 활성 세션은 옛 hook 캐시를 들고 있을 수 있습니다 — 자연 종료 후 재시작 권장(강제 재시작 금지)."
    echo "    변경 사유를 .claude/settings_changelog.md 에 기록하세요."
  elif [[ $rc -ne 0 ]]; then
    echo "⚠️ [hook 등록 동기화 실패] 수동 확인 필요: python3 $HOOK_REGISTRY_SYNC_PY --check"
    echo "$out" | sed 's/^/    /'
  fi
  return 0
}
