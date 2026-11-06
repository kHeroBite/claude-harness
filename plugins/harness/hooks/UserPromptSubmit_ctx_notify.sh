#!/bin/bash
# 컨텍스트 사용률 55/60/65%(자동압축 AC-15/-10/-5) 도달 시 자동압축 임박 안내를 additionalContext 로 단계당 1회 알리는 UserPromptSubmit/PostToolUse hook
# 입력: stdin JSON(session_id, hook_event_name). 사용률은 statusline.py 가 기록한 session-env/<id>/ctx_used_pct (epoch|pct)
# 항상 rc 0. 자기 세션 디렉터리만 읽고 쓴다(타 세션·teams 무접촉).

# 단계별 안내 문구 생성부(문구 조정은 이 함수 한 곳만 고친다). 인자: 단계 사용률 자동압축값
_ctx_notify_text() {
  local stage="$1" pct="$2" ac="$3"
  case "$stage" in
    3) printf '%s' "[컨텍스트 경고-임박] 사용률 ${pct}%. 곧 자동 압축(${ac}%)이 실행된다. 지금 진행 상태·미완 항목·다음 행동을 파일에 기록하라. 사용자가 직접 /compact 로 먼저 압축하는 것도 가능하다. 모델이 /compact 를 실행하려 하지 말 것." ;;
    2) printf '%s' "[컨텍스트 경고] 사용률 ${pct}%. 자동 압축(${ac}%) 접근 중. 압축되면 세부가 사라지니 진행 상태·결정 사항·미완 항목을 파일(checkpoint/handoff 등 세션 기록)에 남겨라. 모델이 /compact 를 실행하려 하지 말 것." ;;
    *) printf '%s' "[컨텍스트 알림] 사용률 ${pct}%. 자동 압축(${ac}%)까지 여유가 있다. 작업 단락이 나오면 진행 상태를 정리해 두라. 모델이 /compact 를 실행하려 하지 말 것." ;;
  esac
}

_ctx_notify_main() {
  local input sid base sdir f mt now pct stage want msg ev ac t1 t2 t3 reset
  input=$(cat 2>/dev/null)
  [ -n "$input" ] || return 0
  sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
  [ -n "$sid" ] || return 0
  ev=$(printf '%s' "$input" | jq -r '.hook_event_name // empty' 2>/dev/null)
  case "$ev" in UserPromptSubmit|PostToolUse) ;; *) ev="UserPromptSubmit" ;; esac
  # 팀에이전트(PIPELINE_UUID 가 session_id 와 다름)는 알림 대상 아님
  if [ -n "${PIPELINE_UUID:-}" ] && [ "$PIPELINE_UUID" != "$sid" ]; then
    return 0
  fi
  # 자동압축 값 AC(1~100 정수만 인정, 아니면 70)에서 세 단계 경계를 한 곳에서 산출
  ac="${CLAUDE_AUTOCOMPACT_PCT_OVERRIDE:-70}"
  case "$ac" in ''|*[!0-9]*) ac=70 ;; esac
  { [ "$ac" -ge 1 ] && [ "$ac" -le 100 ]; } 2>/dev/null || ac=70
  t1=$((ac - 15)); t2=$((ac - 10)); t3=$((ac - 5))
  reset=40; [ "$t1" -lt "$reset" ] && reset=$t1

  base="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  sdir="$base/session-env/$sid"
  f="$sdir/ctx_used_pct"
  [ -f "$f" ] || return 0
  mt=$(stat -c %Y "$f" 2>/dev/null) || return 0
  now=$(date +%s)
  [ $((now - mt)) -le 21600 ] || return 0
  pct=$(cut -d'|' -f2 "$f" 2>/dev/null | tr -dc '0-9')
  [ -n "$pct" ] || return 0

  stage=0
  [ -f "$sdir/ctx_notify_stage" ] && stage=$(tr -dc '0-9' < "$sdir/ctx_notify_stage" 2>/dev/null)
  [ -n "$stage" ] || stage=0

  if [ "$pct" -lt "$reset" ]; then
    rm -f "$sdir/ctx_notify_stage" 2>/dev/null
    return 0
  fi

  want=0
  if [ "$pct" -ge "$t3" ]; then want=3
  elif [ "$pct" -ge "$t2" ]; then want=2
  elif [ "$pct" -ge "$t1" ]; then want=1
  fi
  [ "$want" -gt "$stage" ] || return 0
  msg=$(_ctx_notify_text "$want" "$pct" "$ac")
  echo "$want" > "$sdir/ctx_notify_stage" 2>/dev/null
  jq -n --arg m "$msg" --arg e "$ev" '{hookSpecificOutput:{hookEventName:$e,additionalContext:$m}}' 2>/dev/null
  return 0
}

_ctx_notify_main
exit 0
