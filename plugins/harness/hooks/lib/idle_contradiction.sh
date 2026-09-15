#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# state=IDLE 인데 파이프라인이 실제로 살아있는 "모순 상태"를 감지하는 공용 라이브러리 (사이클123-E13)
#
# 배경 (실사고 — 2026-09-13):
#   메인이 사이클123 계약(goal.json locked=true / oralph_active / status=RALPH)을 만들고
#   팀에이전트를 spawn 했으나 state 를 DEV 로 전이하지 않아 IDLE 로 남았다.
#   ⇒ UserPromptSubmit.sh 가 "💬 [IDLE 직접처리]" 를 출력해 oi 라우팅이 통째로 바이패스됐고,
#     담당 에이전트 판별·SendMessage 전달·큐잉이 전부 생략됐다.
#   "에이전트는 도는데 state 는 IDLE" 은 정의상 모순이며, 지금까지 아무도 잡지 않았다.
#
# 설계 판단 (team-lead 권고 (b)+(a) 중 (b)+라우팅전환만 채택, (a) 자동 state 전이는 배제):
#   - 자동으로 state 를 DEV 로 써버리면(=(a)) 잘못된 전이가 원래 사고보다 위험하다.
#     특히 IDLE 은 ofinish 직후의 정상 종료 상태이기도 해서, 잔존 증거만 보고 DEV 로 되돌리면
#     끝난 파이프라인이 되살아난다. 그래서 state 파일은 절대 쓰지 않는다(읽기 전용).
#   - 대신 "라우팅 판정"만 활성으로 바꾼다. 즉 IDLE 바이패스를 하지 않고 oi 를 태운다.
#     state 축은 건드리지 않으므로 부작용이 없고, oi 는 원래 활성 상태에서 도는 라우터라 안전하다.
#   - 사용자 입력은 절대 막지 않는다((c) 배제). 이 hook 은 모든 입력이 거치는 경로다.
#
# ★핵심 판정 근거는 "살아있는 프로세스" 하나뿐이다★
#   agents/ 등록 파일은 최대 10시간까지 잔존하는 것을 실측했다(정리 주체가 없음).
#   goal.json / oralph_active / status=RALPH 도 ofinish 이후까지 남는다.
#   ⇒ 이 파일들만 보면 "끝난 파이프라인"을 활성으로 오판한다. 그래서 파일 증거는
#     단독 판정 근거로 쓰지 않고, 프로세스가 살아있을 때 사유 표시용으로만 덧붙인다.
#   (MEMORY: "Agent spawn 성공은 팀에이전트의 증거가 아니다 — 판별은 --parent-session-id 프로세스 유무로만")

# 자기 UUID 하위의 살아있는 팀에이전트 수를 센다 (세션 격리 불변식 (a) 준수 — 읽기만).
# 자기 자신(검사 프로세스)을 문자열로 배제하면 안 된다 —
# 검사 명령줄 자체가 UUID 와 "--agent-name" 을 포함해 오카운트된다(실측 확인).
# 따라서 claude 설치 경로(versions/)를 포함한 실제 에이전트 프로세스만 인정한다.
_ic_live_agent_count() {
  local _uuid="$1"
  [[ -n "$_uuid" ]] || { echo 0; return; }
  ps -eo pid=,args= 2>/dev/null | awk \
    -v u="--parent-session-id ${_uuid}" \
    -v self="$$" -v pp="$PPID" '
      index($0, u) > 0 && index($0, "--agent-name ") > 0 {
        pid = $1
        if (pid == self || pid == pp) next   # 검사 프로세스 자신/부모 제외
        if ($0 !~ /versions\//) next          # claude 실행 바이너리 경로가 없으면 에이전트가 아니다
        n++
      }
      END { print n + 0 }' 2>/dev/null || echo 0
}

# 모순 여부 판정.
#   인자: $1=SESSION_DIR  $2=UUID  $3=현재 state
#   반환: 0 = 모순 (IDLE 인데 살아있는 에이전트 존재) / 1 = 모순 아님
#   부수효과: 전역 _IC_AGENTS(살아있는 수), _IC_REASON(부가 증거 문자열) 설정
_ic_detect() {
  local _dir="$1" _uuid="$2" _state="$3"
  _IC_AGENTS=0
  _IC_REASON=""

  # IDLE 이 아니면 애초에 모순이 아니다. (정상 활성 상태는 이미 oi 가 라우팅한다)
  [[ "$_state" == "IDLE" ]] || return 1
  [[ -n "$_dir" && -d "$_dir" ]] || return 1

  _IC_AGENTS=$(_ic_live_agent_count "$_uuid")
  # 살아있는 에이전트가 0 이면 진짜 IDLE 이다 — 잔존 파일이 있어도 모순으로 보지 않는다.
  # (ofinish 직후 goal.json/oralph_active 잔존이 정상 종료의 일반적 모습이다)
  [[ "${_IC_AGENTS:-0}" -gt 0 ]] || return 1

  # 여기부터는 모순 확정. 사용자에게 보여줄 부가 증거를 모은다(판정에는 영향 없음).
  local _ev=""
  if [[ -f "${_dir}/oralph_active" ]]; then
    _ev="${_ev}oralph_active "
  fi
  if [[ -f "${_dir}/goal.json" ]] && grep -q '"locked"[[:space:]]*:[[:space:]]*true' "${_dir}/goal.json" 2>/dev/null; then
    _ev="${_ev}goal.json(locked) "
  fi
  if [[ -f "${_dir}/status" ]] && grep -q 'RALPH' "${_dir}/status" 2>/dev/null; then
    _ev="${_ev}status=RALPH "
  fi
  _IC_REASON="${_ev% }"
  return 0
}
