#!/bin/bash
# 에이전트(메인·팀)의 운영 배포·승격·운영 데몬 조작을 물리 차단하는 범용 PreToolUse 가드 (차단 목록은 프로젝트 설정)
#
# 배경(2026-10-10 사용자 결정, 적대 검토 H5): 에이전트는 운영 배포·강제업데이트를 실행하지 않는다.
#   에이전트가 스스로 설정할 수 있는 환경변수 확인 방식은 우회가 되므로 쓰지 않는다.
#   차단된 배포 단계는 건너뛰고 나머지를 끝까지 진행하며, 최종 보고의 운영 배포 보류 목록에 명령 1줄을 남긴다.
#   예외(2026-10-24): 메인 에이전트에 한해 AskUserQuestion 화면 승인 채널(header 승인:PROD_DEPLOY·고정 문구·옵션 승인/거부·
#     차단 명령 원문 블록)로 사용자가 승인하면 10분·1회·원문 완전 일치로 통과한다. 팀에이전트 호출에는 적용되지 않는다.
#     상세: docs/prd/prod-deploy-approval-2026-10-24.md (판정은 코어 lib/prod_deploy_guard.py)
# 코어: lib/prod_deploy_guard.py — 판정 규칙·설정 형식은 그 파일 머리말 참조.
# 차단 목록: <프로젝트>/.claude/prod_deploy_guard.json (이 hook 에는 프로젝트명·경로·포트가 없다)
# 등록: PreToolUse matcher Bash|mcp__oio__bash_exec|파일 쓰기·복사·이동 도구 — 메인·팀에이전트 모두 적용(PIPELINE_UUID 면제 없음)
# 비상 해제 스위치: <이 hook 디렉토리>/DISABLE_PROD_DEPLOY_GUARD (mtime 30분 이내만 유효) — 에이전트는 만들거나 지우지 않는다.
# 가드 교체: 코어·이 hook 은 lib/guard_promote.sh 승격 경로(고정 회귀 시험 전체 통과 시 원자 교체)로만 바뀐다.
# 로그: <이 hook 디렉토리>/logs/prod_deploy_guard.log
# 실패 정책: python3·코어 부재 또는 코어 비정상 종료·시간 초과 시, 셸 명령에 배포·재시작 계열 단어가 있으면 fail-closed(차단)한다.

INPUT=$(timeout 5 cat 2>/dev/null) || exit 0

HOOK_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
LIB="$HOOK_DIR/lib/prod_deploy_guard.py"

OUT=""
RC=0
if [[ -f "$LIB" ]] && command -v python3 >/dev/null 2>&1; then
  OUT=$(printf '%s' "$INPUT" | PDG_HOOK_DIR="$HOOK_DIR" timeout 8 python3 -I "$LIB" 2>/dev/null)
  RC=$?
else
  RC=127
fi

if [[ -n "$OUT" ]]; then
  printf '%s' "$OUT"
  exit 0
fi

# 코어가 판정하지 못한 경우(부재·시간 초과): 셸 명령에 운영 배포 흔적 단어가 있으면 차단(fail-closed), 아니면 통과
if [[ $RC -ne 0 ]]; then
  CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // .tool_input.cmd // empty' 2>/dev/null)
  if [[ -n "$CMD" ]] && printf '%s' "$CMD" | grep -qiE 'deploy|promote|rollout|kill|restart'; then
    printf '%s' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"🚫 [운영 배포 가드] 판정 코어를 실행하지 못해(부재·시간 초과) 배포·재시작 계열 명령을 보수적으로 차단했다. 이 단계만 건너뛰고 나머지를 끝까지 진행하라. 최종 보고의 운영 배포 보류 목록에 명령 1줄을 적어라. 코어가 없어 화면 승인(승인:PROD_DEPLOY)도 판정할 수 없다 — 코어 복구 후 재시도."}}'
  fi
fi
exit 0
