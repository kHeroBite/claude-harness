#!/bin/bash
# auto=ON 세션이 IDLE 에서 잔업(carryover next_action / 잔여 phase batch)을 두고 턴을 끝내려 하면 차단하는 Stop hook
#
# 배경: oto 는 잔여를 다음 사이클로 이월(handoff_kind=carryover)할 수 있고, 이월 기록이 있으면
#   사용자 입력 없이 즉시 다음 /oto 를 실행해야 한다. 이 hook 은 그 "즉시 착수"를 턴 종료 차단으로 강제한다.
# 차단 출력: stdout {"decision":"block","reason":"…"} 1줄 + exit 2 (Stop_askq_guard.sh 와 동일 규격).
# fail-open: 모든 경로의 기본은 exit 0. set -e 는 쓰지 않는다.
#
# 입구(위에서부터, 하나라도 해당하면 exit 0 무출력)
#   E0 DISABLE_OTO_GUARD 존재 / E1 jq·python3 부재 / E2 빈 stdin / E3 stop_hook_active=true
#   E4 agent_id 존재 또는 PIPELINE_UUID 가 자기 session_id 와 다름(팀에이전트) / E5 auto=ON 아님
#   E6 state 첫 토큰이 IDLE 아님 / E7 status 에 ABORT 또는 PAUSE
# 차단 사유: R1 미소비 carryover next_action.json / R2 phase_batches 잔여(current < total)
# 교착 방지: 같은 서명으로 2회 차단한 뒤 3회차는 통과하고 evidence/oto_residual_escape.log 에 기록한다.
#   카운터는 ${SD}/oto_residual_block_count (askq 카운터와 분리). E3 때문에 stop_hook_active=false 인
#   서로 다른 턴 체인에서만 증가한다(2초 디바운스는 쓰지 않는다).
# 한계: 턴 종료만 막을 뿐 메인이 실제로 /oto 를 호출하는지는 판정하지 못한다. 3회차 탈출구가 있어 완전 강제는 아니다.

set -u

HOOKS_DIR="${HARNESS_HOME:-$HOME/.harness}/current/hooks"

# E0 — 비상 스위치
[[ -f "${HOOKS_DIR}/DISABLE_OTO_GUARD" ]] && exit 0

# E1 — 의존 도구 부재 시 통과
command -v jq >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

# E2 — 빈 입력 통과
INPUT="$(cat 2>/dev/null)" || exit 0
[[ -z "$INPUT" ]] && exit 0

# E3 — stop_hook_active 이면 통과
SHA="$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null)" || exit 0
[[ "$SHA" == "true" ]] && exit 0

# E4 — 팀에이전트 통과
AID="$(printf '%s' "$INPUT" | jq -r '.agent_id // empty' 2>/dev/null)" || exit 0
[[ -n "$AID" ]] && exit 0
UUID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)" || exit 0
[[ -z "$UUID" ]] && exit 0
if [[ -n "${PIPELINE_UUID:-}" && "${PIPELINE_UUID}" != "$UUID" ]]; then
    exit 0
fi

# 세션 디렉토리 후보(두 base) — 존재하는 것만
DIRS=()
if [[ -n "${CLAUDE_CONFIG_DIR:-}" && -d "${CLAUDE_CONFIG_DIR}/session-env/${UUID}" ]]; then
    DIRS+=("${CLAUDE_CONFIG_DIR}/session-env/${UUID}")
fi
if [[ -d "${HOME}/.claude/session-env/${UUID}" ]]; then
    DIRS+=("${HOME}/.claude/session-env/${UUID}")
fi
[[ ${#DIRS[@]} -eq 0 ]] && exit 0

# E5 — auto=ON 판정(두 base OR)
AUTO_ON=0
for _d in "${DIRS[@]}"; do
    if [[ -f "${_d}/auto" ]]; then
        _v="$(tr -d '[:space:]' < "${_d}/auto" 2>/dev/null)"
        [[ "$_v" == "ON" ]] && AUTO_ON=1 && break
    fi
done
[[ "$AUTO_ON" -eq 1 ]] || exit 0

# 판독 대상 SD — state 파일이 있는 첫 디렉토리
SD="${DIRS[0]}"
for _d in "${DIRS[@]}"; do
    if [[ -f "${_d}/state" ]]; then SD="$_d"; break; fi
done

# E6 — IDLE 일 때만 판정
STATE_TOK=""
if [[ -f "${SD}/state" ]]; then
    read -r STATE_TOK _ < "${SD}/state" 2>/dev/null
fi
[[ "$STATE_TOK" == "IDLE" ]] || exit 0

# E7 — ABORT/PAUSE 통과
if [[ -f "${SD}/status" ]]; then
    _st="$(tr -d '[:space:]' < "${SD}/status" 2>/dev/null)"
    case "$_st" in
        *ABORT*|*PAUSE*) exit 0 ;;
    esac
fi

# E8 — 주간 한도 게이트 '중단' 유지 중이면 통과(이번 주 stop 기록이 마지막 사용자 입력 이후)
_LP="${SD}/last_prompt_epoch"
_CL="${SD}/logs/askq_approval_consumed.log"
if [[ -f "$_LP" && -f "$_CL" ]]; then
    _lpm="$(stat -c %Y "$_LP" 2>/dev/null)"
    if [[ "$_lpm" =~ ^[0-9]+$ ]]; then
        while IFS=$'\t' read -r _id _tg _ts; do
            case "$_tg" in
                WEEKLY_*_stop@*@*)
                    _ep="${_tg##*@}"
                    if [[ "$_ep" =~ ^[0-9]+$ && "$_ep" -ge "$_lpm" ]]; then exit 0; fi
                    ;;
            esac
        done < "$_CL"
    fi
fi

COUNT_FILE="${SD}/oto_residual_block_count"
EVID="${SD}/evidence"

REASON=""
SIG=""

# R1 — 미소비 carryover
NA="${SD}/next_action.json"
if [[ -f "$NA" ]]; then
    _kind="$(jq -r '.handoff_kind // empty' "$NA" 2>/dev/null)"
    if [[ "$_kind" == "carryover" ]]; then
        _cmd="$(jq -r '.slash_command // "/oto"' "$NA" 2>/dev/null)"
        _task="$(jq -r '.task_description // ""' "$NA" 2>/dev/null)"
        SIG="na:$(sha256sum "$NA" 2>/dev/null | cut -d' ' -f1)"
        REASON="🔁 [잔업 이월] 잔업 사이클 있음 — 사용자 입력 대기 없이 즉시 ${_cmd} ${_task} 을 실행하세요. (미소비 carryover next_action.json 존재, 다음 /oto 진입부가 소비합니다.)"
    fi
fi

# R2 — 잔여 phase batch
if [[ -z "$REASON" && -f "${SD}/plans/phase_batches.json" ]]; then
    _cur="$(jq -r '.current_phase_batch // empty' "${SD}/plans/phase_batches.json" 2>/dev/null)"
    _tot="$(jq -r '.total_batches // empty' "${SD}/plans/phase_batches.json" 2>/dev/null)"
    if [[ "$_cur" =~ ^[0-9]+$ && "$_tot" =~ ^[0-9]+$ && "$_cur" -lt "$_tot" ]]; then
        SIG="pb:${_cur}/${_tot}"
        REASON="🔁 [잔여 phase batch] 잔여 phase batch(${_cur}/${_tot}) — 사용자 입력 대기 없이 다음 batch 를 즉시 진행하세요."
    fi
fi

# 잔업 없음 — 카운터 초기화 후 통과
if [[ -z "$REASON" ]]; then
    rm -f "$COUNT_FILE" 2>/dev/null
    exit 0
fi

# 서명별 연속 차단 횟수 — 2회 차단 후 3회차 통과
PRIOR=0
if [[ -f "$COUNT_FILE" ]]; then
    _csig="$(sed -n '1p' "$COUNT_FILE" 2>/dev/null)"
    _cn="$(sed -n '2p' "$COUNT_FILE" 2>/dev/null)"
    if [[ "$_csig" == "$SIG" && "$_cn" =~ ^[0-9]+$ ]]; then
        PRIOR="$_cn"
    fi
fi

if [[ "$PRIOR" -ge 2 ]]; then
    mkdir -p "$EVID" 2>/dev/null
    printf '%s ESCAPE sig=%s uuid=%s (연속 2회 차단 후 3회차 통과)\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$SIG" "$UUID" >> "${EVID}/oto_residual_escape.log" 2>/dev/null
    rm -f "$COUNT_FILE" 2>/dev/null
    exit 0
fi

printf '%s\n%s\n' "$SIG" "$((PRIOR + 1))" > "$COUNT_FILE" 2>/dev/null
jq -cn --arg r "$REASON" '{decision:"block",reason:$r}'
exit 2
