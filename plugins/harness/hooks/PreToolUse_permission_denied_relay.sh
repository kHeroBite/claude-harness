#!/usr/bin/env bash
# 직전 안전분류기 거부(PermissionDenied) 판정 안내를 다음 도구 호출 때 additionalContext 로 모델에게 1회 중계하는 PreToolUse hook
# 표식이 없으면 fork 없이(bash 내장 검사만) 즉시 rc 0. 표식은 거부당한 에이전트 자신의 session-env/<최상위 session_id>/logs/pd_relay.json 이다.
# permissionDecision 을 내지 않으므로 도구 호출은 평소 권한 흐름 그대로 진행된다.
_in="$(cat)"
_m=""
if [[ "${PD_TEST:-}" == 1 && -n "${PD_STATE_DIR:-}" && "${PD_STATE_DIR}" == /* && -d "${PD_STATE_DIR}" ]]; then
  # 시험 전용 — PD_TEST=1 과 함께, 실재하는 /tmp·/var/tmp 아래만 받는다(판정기 test_state_dir 와 같은 규칙)
  _r="$(realpath -e -- "${PD_STATE_DIR}" 2>/dev/null)"
  [[ "${_r}/" == /tmp/* || "${_r}/" == /var/tmp/* ]] && _m="${_r}/logs/pd_relay.json"
fi
if [[ -z "$_m" ]]; then
  _cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  # 1단계(무 fork): 입력 안 모든 "session_id" 후보의 표식 존재만 본다. 하나도 없으면 즉시 종료.
  #   큰 본문(file_write 수 MB)에서 정규식 반복이 느려지지 않게 입력 앞 4KB + 끝 4KB 만 본다(최상위 키는 보통 양 끝에 있다).
  #   놓치면 중계만 생략된다(차단 없음 — fail-open).
  if (( ${#_in} > 8192 )); then _s="${_in:0:4096} ${_in: -4096}"; else _s="$_in"; fi
  _hit=0
  while [[ "$_s" =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\"(.*) ]]; do
    [[ -f "${_cfg}/session-env/${BASH_REMATCH[1]}/logs/pd_relay.json" ]] && { _hit=1; break; }
    _s="${BASH_REMATCH[2]}"
  done
  [[ "$_hit" == 1 ]] || exit 0
  # 2단계(세션 격리): tool_input 안의 같은 이름 키가 아니라 ★최상위★ session_id 만 쓴다
  _sid="$(printf '%s' "$_in" | jq -r 'if type=="object" then (.session_id // empty) else empty end' 2>/dev/null)"
  [[ "$_sid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || exit 0
  _m="${_cfg}/session-env/${_sid}/logs/pd_relay.json"
fi
# 읽을 수 없는 표식(권한 000 등)은 소비하지 않는다 — 가져간 뒤 못 읽어 안내가 사라지는 것을 막는다
[[ -f "$_m" && -r "$_m" ]] || exit 0
# 원자적 소비: 이름을 바꿔 가져온 쪽만 전달한다(동시 호출 중복 전달 방지)
_c="${_m}.c$$"
mv -f -- "$_m" "$_c" 2>/dev/null || exit 0
_PD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 -I "${_PD_DIR}/lib/permission_denied_judge.py" --relay "$_c"
exit 0
