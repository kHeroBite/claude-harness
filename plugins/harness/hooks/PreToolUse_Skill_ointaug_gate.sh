#!/bin/bash
# PreToolUse_Skill_ointaug_gate.sh — PreToolUse:Skill hook
# 목적: IDLE 상태에서 ointaug 미경유 파이프라인 스킬 호출을 물리 차단 (F-INTAUG-1)
#
# 배경 (2026-09-02 실사고):
#   UserPromptSubmit.sh:174 가 "📌 [ointaug 필수]" 를 출력했음에도 메인이 이를 무시하고
#   ointaug 없이 /oto 를 직접 호출한 사례가 한 세션에서 반복 발생했다.
#   메시지는 안내일 뿐 강제력이 없었다 — CLAUDE.md 재발방지 정책상 "LLM 의지 의존"은 재발방지가 아니다.
#
# 설계 (oi_route_guard.sh 와 동일한 검증된 패턴):
#   ointaug 가 실행되면 마커 생성 → 이후 파이프라인 스킬 통과.
#   마커 없이 파이프라인 스킬을 호출하면 block(rc=2) + ointaug 선행 안내.
#
# 예외 (차단 제외):
#   - ointaug 자신 (마커 생성 주체)
#   - ox (o시리즈 완전 바이패스 — UserPromptSubmit.sh 가 명시 예외 처리)
#   - 비파이프라인 스킬 (ostatus/ocontext/oinit/ofinish 등 정리·조회류)
#   - 팀에이전트/서브에이전트 (PIPELINE_UUID 보유)
#   - IDLE 이 아닌 상태 (파이프라인 진행 중 내부 호출)

trap 'exit 0' ERR
INPUT=$(timeout 5 cat 2>/dev/null) || INPUT=""
SKILL_NAME=$(echo "$INPUT" | jq -r '(.tool_input.skill // .tool_input.skill_name // empty)' 2>/dev/null)
SKILL_NAME="${SKILL_NAME##*:}"
[[ -z "$SKILL_NAME" ]] && exit 0

# 차단 대상 = 파이프라인 진입 스킬만 (화이트리스트 방식이 아니라 대상 명시)
case "$SKILL_NAME" in
  ok|oto|oroof|oralph|o1|o2|o3|o4|o5|okconsult|okdebate|okdeep|odeep|oconsult|odebate|oplan|onormal|osimple) ;;  # ROOF-COMPAT(deprecation window 1주기 — 구 RALPH/oralph_active 인식 제거 예정)
  *) exit 0 ;;
esac

source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/session_id.sh" 2>/dev/null || exit 0
source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/state_machine.sh" 2>/dev/null || true
resolve_uuid "$INPUT" || exit 0
[[ -z "$UUID" ]] && exit 0

# 팀/서브에이전트 스킵
if [[ -n "${PIPELINE_UUID:-}" && "${PIPELINE_UUID:-}" != "$MY_UUID" ]] || [[ "$MY_UUID" != "$UUID" ]]; then
  exit 0
fi

SESSION_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}"
[[ -f "${SESSION_DIR}/state" ]] || exit 0

CURRENT_STATE=$(state_read "${SESSION_DIR}/state" 2>/dev/null | awk '{print $1}' | tr -d '\r')
[[ "$CURRENT_STATE" == "__LOCK_FAIL__" ]] && exit 0
# IDLE 에서만 강제 (진행 중 내부 호출은 대상 아님)
[[ "$CURRENT_STATE" == "IDLE" || -z "$CURRENT_STATE" ]] || exit 0

# 마커 확인 — 양쪽 base 모두 인정 (경로 이중화 대응)
# ★[2026-10-10 사이클174 F-INTAUG-3] 판정 대상을 ointaug_done → ointaug_invoked(hook 이 쓰는 호출 증표)로 교체★
#   실사고: 메인이 Skill('ointaug') 없이 session_state 로 ointaug_done 을 직접 써서 이 게이트를 통과할 수 있었다.
#   ointaug_done 은 메인이 쓰는 파일이라 Skill 호출의 증거가 아니다(L-467 자기신고 판정축과 같은 결함).
#   ointaug_invoked 는 PostToolUse_Skill_ointaug_format.sh 가 Skill('ointaug') 실행 직후에만 쓰고,
#   메인의 쓰기·삭제는 PreToolUse_ointaug_turn_gate.sh 가 막는다. 아래 mtime·기준점 판정 로직은 그대로다.
# 인자 없는 슬래시 명령 면제 — UserPromptSubmit 이 기록한 ointaug_exempt 의 mtime 이 이번 턴 기준점(last_prompt_epoch) 이상이면 통과한다.
#   미래 mtime(+120초 초과)은 무효로 본다. 판정 정의는 lib/intaug_exempt.sh 한 곳이며 여기서는 재구현하지 않는다.
_EXF="${SESSION_DIR}/ointaug_exempt"
_EXB="${SESSION_DIR}/last_prompt_epoch"
if [[ -f "$_EXF" && -f "$_EXB" ]]; then
  _EXT=$(stat -c %Y "$_EXF" 2>/dev/null)
  _EXBT=$(stat -c %Y "$_EXB" 2>/dev/null)
  _EXNOW=$(date +%s)
  if [[ "$_EXT" =~ ^[0-9]+$ && "$_EXBT" =~ ^[0-9]+$ ]] && (( _EXT >= _EXBT && _EXT - _EXNOW <= 120 )); then
    exit 0
  fi
fi
MARK1="${SESSION_DIR}/ointaug_invoked"
MARK2="$HOME/.claude/session-env/${UUID}/ointaug_invoked"
NOW=$(date +%s)
for M in "$MARK1" "$MARK2"; do
  [[ -f "$M" ]] || continue
  # ★[2026-09-13 사이클127] 첫 줄만 읽는다 — 마커 2~5행에 F-INTAUG-2 형식 증거가 담기기 때문이다.
  #   사이클125 에서 PostToolUse_Skill_ointaug_format.sh(F-INTAUG-2)를 신설하며 마커에
  #   "대상/조건/성공기준/컨텍스트" 4항목을 추가하도록 SKILL.md 를 바꿨는데,
  #   여기서 전체를 tr -d 로 뭉쳐 숫자 검사하던 탓에 "1789278700대상:운영MIG..." 가 되어
  #   ★정상 마커가 무효 판정★ 되고 파이프라인 진입이 전면 차단됐다(실측 재현).
  #   ⇒ 두 hook 이 같은 파일을 다른 형식으로 읽고 있었다. head -1 로 epoch 만 취한다.
  #
  # ★[2026-09-15 사이클133 F-INTAUG-1] 판정축을 "마커 첫 줄 자기신고 epoch" → "파일 mtime(시스템 실측)" 으로 교체★
  #   실사고: /o3·/o4 등 파이프라인 진입이 "TTL 600초 초과"로 반복 차단됨.
  #   원인: 검증 대상(에이전트)이 본문 첫 줄에 직접 적은 숫자를 TTL 기준으로 삼았다.
  #     epoch 를 date 실측 없이 기억/계산으로 적으면, 파일은 방금 생성됐는데
  #     내용상 이미 만료된 마커가 됐다(실측: ts=1789451094 / mtime=1789451107, 13초 괴리 —
  #     두 값이 다른 소스임의 증명. 메인 직전 턴은 780초 괴리로 실제 차단됨).
  #   ⇒ CLAUDE.md 메모리 교훈 L-467 "선언은 검증을 이길 수 없다" 와 구조적으로 동일한 결함 —
  #     자기신고 필드를 검증 없이 판정 기준으로 쓴 것이 원인이다.
  #   조치: head -1 로 본문을 읽는 대신 stat -c %Y 로 파일 mtime 을 직접 실측한다.
  #     에이전트가 epoch 를 추정 기입하는 경로가 구조적으로 소멸한다(자기신고 제거).
  #   ⚠️ 마커 첫 줄 epoch 텍스트 자체는 삭제하지 않는다(ointaug/SKILL.md 참조) —
  #     F-INTAUG-2(PostToolUse_Skill_ointaug_format.sh)의 4항목 검사는 `grep -q '대상:'` 로
  #     행 위치 무관하게 동작하고, 구형식 하위호환 분기는 `^[0-9]+$`(전체가 숫자)만 참이 되므로
  #     이 게이트가 첫 줄을 읽지 않게 바꾸는 것만으로 두 hook 형식 정합에 영향이 없다(실측 확인).
  TS=$(stat -c %Y "$M" 2>/dev/null)
  [[ "$TS" =~ ^[0-9]+$ ]] || continue
  AGE=$((NOW - TS))
  # ★[2026-09-13 사이클128 T-B1] 미래 epoch 상한 검사 — fail-open 차단★
  #   기존 코드는 `(NOW - TS) -le 600` 단일 하한만 봤다. TS 가 미래면 AGE 가 ★음수★ 라
  #   -le 600 이 ★항상 참★ 이 되어 ★TTL 무한 = 게이트 영구 개방★ 이었다.
  #   실측 재현(원본 게이트): NOW+99999 마커 주입 → rc=0 통과.
  #   ⇒ 부호가 반대였을 뿐 같은 오차인데, 이쪽 방향은 ★아무도 모른다★.
  #     과거 오차는 즉시 만료·차단돼 발견되지만(fail-safe),
  #     미래 오차는 조용히 게이트를 무력화한다(fail-open). 후자가 훨씬 위험하다.
  #   허용 스큐 +120초 근거: 마커 생성·검증이 ★동일 호스트(WSL2 단일 머신)★ 에서 일어나므로
  #   원리상 스큐는 0 이다. 120초는 date 호출~파일 기록 지연 + mtime 해상도를 흡수하는
  #   안전 마진이며, 그 이상 미래는 "추정으로 쓴 값"으로 간주해 거부한다.
  #   ⇒ 유효 구간은 -120 <= AGE <= 600 의 ★양방향★ 이다.
  #
  # ★[2026-09-15 사이클133] 판정축을 mtime 으로 바꾼 후에도 이 분기는 존치한다★
  #   "시스템이 자동으로 찍는 mtime 은 원리상 미래 불가"까지는 제거 논리가 서지만,
  #   실측 결과 `touch -d "@$((NOW+99999))"` 로 ★미래 mtime 강제가 실제로 가능★ 했다
  #   (AGE=-99999 재현). touch 는 에이전트가 일상적으로 쓰는 명령이라 이 경로는 현실적이다.
  #   이 분기가 막는 방향은 여전히 fail-open(게이트 영구 개방 — 조용히 아무도 모름)이므로
  #   8줄 유지 비용보다 오제거 피해가 압도적으로 크다. ⇒ 삭제하지 않는다.
  #   mtime 기반에서는 touch 를 통한 인위 조작만이 미래 값을 만들 수 있다는 점만 다를 뿐,
  #   판정 로직(AGE < -120 거부)은 이전과 동일하게 유효하다.
  if [[ $AGE -lt -120 ]]; then
    # T-B2: fail-open 이 다시 생기면 관측되게 한다 (조용한 무효화 금지)
    _ANOM_DIR="${SESSION_DIR}/logs"
    mkdir -p "$_ANOM_DIR" 2>/dev/null
    printf '%s F-INTAUG-1 future-epoch rejected: marker=%s ts=%s now=%s age=%s skill=%s\n' \
      "$(date -Is 2>/dev/null)" "$M" "$TS" "$NOW" "$AGE" "$SKILL_NAME" \
      >> "$_ANOM_DIR/ointaug_marker_anomaly.log" 2>/dev/null
    echo "⚠️ [F-INTAUG-1] 마커 epoch 가 미래다 (${AGE}초) — 무효 처리. date 실측 없이 추정으로 쓴 값이다: $M" >&2
    continue
  fi

  # ★[2026-09-18 사이클134 F-INTAUG-1] TTL 600초 하한 판정을 "기준점 대조" 판정으로 승격★
  #   실사고: 정당하게 ointaug 를 경유했는데도 AskUserQuestion 응답 대기·자리 비움 등으로
  #   벽시계 700초가 흐르면 TTL 600초에 걸려 오차단됐다(oplan 격리 재현: rc=2, 기대 rc=0).
  #   원인: 게이트가 재려는 명제는 "이번 턴에 ointaug 를 경유했는가" 인데, 실제로 재는 명제는
  #   "마커가 몇 초 전에 만들어졌는가" 였다. TTL 은 턴 경계를 모르기 때문에 쓰인 대용물(proxy)일 뿐이다.
  #   조치: UserPromptSubmit.sh 가 매 턴 기록하는 기준점(last_prompt_epoch, mtime 전용)과
  #   마커 mtime 을 직접 비교한다. 기준점 이후 생성된 마커는 유휴 시간과 무관하게 통과시킨다.
  #   이 경로는 "이번 턴에 실제로 ointaug 를 실행했다"를 TTL 없이 직접 증명하므로 대용물이 불필요해진다.
  #   TTL 600초는 기준점 부재/미래(신규 도입 직후 구세션, 시계 왜곡) 시의 폴백으로 강등한다 —
  #   폴백 경로는 현행 동작과 완전히 동일하므로 회귀가 없다(oplan AC-C/D 로 실증).
  #   판정 순서가 안전성이다: 미래 마커 검사(위 블록)가 반드시 기준점 판정보다 앞에 와야 한다.
  #   뒤로 가면 미래 마커가 "mtime>=기준점"을 항상 참으로 만들어 게이트가 영구 개방된다(조용한 fail-open).
  _BASE1="${SESSION_DIR}/last_prompt_epoch"
  _BASE2="$HOME/.claude/session-env/${UUID}/last_prompt_epoch"
  # 기준점도 마커와 같은 base 쌍에서 읽는다 — 마커가 MARK1 이면 _BASE1 우선, MARK2 면 _BASE2 우선.
  if [[ "$M" == "$MARK1" ]]; then
    _BASE_PRIMARY="$_BASE1"; _BASE_FALLBACK="$_BASE2"
  else
    _BASE_PRIMARY="$_BASE2"; _BASE_FALLBACK="$_BASE1"
  fi
  _BASE_FILE=""
  if [[ -f "$_BASE_PRIMARY" ]]; then
    _BASE_FILE="$_BASE_PRIMARY"
  elif [[ -f "$_BASE_FALLBACK" ]]; then
    _BASE_FILE="$_BASE_FALLBACK"
  fi

  if [[ -n "$_BASE_FILE" ]]; then
    _BASE_TS=$(stat -c %Y "$_BASE_FILE" 2>/dev/null)
    if [[ "$_BASE_TS" =~ ^[0-9]+$ ]]; then
      _BASE_SKEW=$((_BASE_TS - NOW))
      if [[ $_BASE_SKEW -gt 120 ]]; then
        # 기준점 자체가 미래 — 신뢰하지 않고 TTL 폴백 (영구 차단 고착 방지)
        if [[ $AGE -le 600 ]]; then exit 0; fi
      elif [[ $TS -ge $_BASE_TS ]]; then
        # 마커가 이번 턴 기준점 이후 생성됨 — 유휴 시간 무관 통과 (신규 구제 경로)
        exit 0
      else
        # 마커가 기준점보다 과거 — TTL 600초 보조 상한으로만 구제
        if [[ $AGE -le 600 ]]; then exit 0; fi
      fi
      continue
    fi
  fi

  # 기준점 파일 부재 — TTL 600초 판정 (= 현행 동작, 회귀 없음)
  if [[ $AGE -le 600 ]]; then exit 0; fi
done

cat <<EOF >&2
⛔ [F-INTAUG-1] ointaug 미경유 파이프라인 진입 차단 — Skill('${SKILL_NAME}')

CLAUDE.md 「ointaug 필수 호출 규칙」: 모든 입력의 첫 번째 행동은 Skill('ointaug') 다.
UserPromptSubmit.sh 가 출력한 "📌 [ointaug 필수]" 안내를 건너뛰었다.

조치: 먼저 Skill('ointaug') 를 호출해 확장 질의를 출력한 뒤, 다시 ${SKILL_NAME} 을 호출하라.
(ointaug 실행 시 마커가 생성되어 이 차단이 자동 해제된다. 이번 턴 기준점 이후 마커는 유휴 시간과
무관하게 통과하며, TTL 600초는 기준점 부재/미래 시의 폴백으로만 작동한다.)
EOF
exit 2
