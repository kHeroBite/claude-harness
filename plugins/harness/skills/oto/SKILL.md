---
name: oto
description: "ok 파이프라인 + 자율주행(auto) 강제 + 목표 계약 기반 반복 검증 완주 — '/oto' 호출 시 ok와 동일한 파이프라인(oplan→odev→otest→odone→ofinish)을 실행하되 auto 플래그를 세션에 기록하여 사용자 확인 없이 끝까지 완주한다. 동시에 oroof Phase 0/Phase 2와 동일한 검증 루프를 인라인으로 수행하여(팀에이전트 spawn 없음), goal.json이 있으면 acceptance를 soft 병합하고 없으면 criteria_detail만으로 판정하며, 검증 미달 시 최대 반복까지 FINISH→DEV를 자동 재진입한다. 선택·판단·에스컬레이션은 전부 메인이 자율 결정하고, 에이전트가 원출 불가능한 외부 사실(자격증명·미공개 URL·사용자만 아는 값)만 사용자에게 질문한다. 팀에이전트 질문은 메인이 대리 답변한다. 'auto'와 동음이의어."
invocation:
  user_callable: true
  pipeline_callable: false
  called_by: [사용자]
  calls: [ok]
---
# oto — ok + 자율주행(auto) 강제

사용자가 `/oto` 호출 시 ok 파이프라인을 실행하되, **auto 플래그**를 세션에 기록하여
메인·팀·서브 에이전트 전원이 사용자 확인 없이 ofinish까지 완주한다.

## 절대 규칙

> **파이프라인 강제**: /oto 호출 시 내용과 무관하게 파이프라인 100% 실행 필수. 직접 답변 금지.
> **자율 완주 강제**: "사용자에게 확인 후 진행하겠습니다" 류의 대기 행위 금지. 스스로 최선을 선택하고 끝까지 진행하라.

## 설계 근거

ok와 파이프라인 구조가 100% 동일하다. 유일한 차이는 **auto 플래그의 유무**다.
따라서 ok/ok_pipeline을 수정하지 않고, 플래그를 읽는 쪽(메인)의 행동만 바꾼다.

**팀/서브에이전트는 수정 대상이 아니다.** 팀에이전트의 모든 보고·질의는
`SendMessage(to:"team-lead")`로 메인에게 전달되므로(agent_profiles 기본 규칙 블록),
메인이 대리 답변하면 팀에이전트 코드·프롬프트를 건드리지 않아도 자율성이 확보된다.
질문이 사용자에게 도달하는 실제 경로는 **메인 자신의 AskUserQuestion 호출뿐**이다.

## 동작

```yaml
0_잔업_이어받기:
  시점: /oto 진입 직후(state IDLE→PLAN 직후), 아래 1단계보다 먼저.
  내용: next_action.json 이 handoff_kind="carryover" 면 B1~B4로 소비하고 새 goal 로 시작한다.
        절차 전문은 "## 잔업 이월과 자동 이어받기" 절 B 단계를 따른다.
        carryover 가 없으면 이 단계는 건너뛴다.

1_auto_플래그_기록:
  시점: ok 로딩 직전 (pipeline_state 설정과 동일 시점)
  명령: |
    mcp__oio__session_state(uuid="${UUID}", key="auto", value="ON")
  경로: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/auto
  값: "ON" (한 줄)
  주의_경로: |
    반드시 ${CLAUDE_CONFIG_DIR:-$HOME/.claude} 형식을 쓴다.
    $HOME/.claude 하드코딩 금지 — CLAUDE_CONFIG_DIR가 설정된 세션에서 경로가 어긋난다
    (실측: SESSION_ENV_BASE가 /tmp/cc-*/session-env로 해석되는 세션 존재).
    session_state 도구 사용 시에는 uuid만 넘기면 되므로 경로 문제가 없다.
  정리: ofinish 종료 시 삭제 (다음 파이프라인에 자율모드 누출 방지)
  주의: |
    status 축(ABORT|PAUSE|ROOF, 구 RALPH 도 인식 — ROOF-COMPAT)에 등재하지 않는다.
    state_machine.sh의 _STATUS_VALID_TOKENS 화이트리스트에 없는 토큰은
    status_add가 "invalid token"으로 return 1 하여 조용히 실패한다.
    별도 파일 축으로 두면 공유 제어면(state_machine.sh) 수정이 불필요하다.

1_5_목표계약_세팅 (goal+반복검증 흡수):
  시점: auto 플래그 기록과 동일 시점 (ok 로딩 직전)
  동작:
    1. goal.json 생성 (필수 — 미생성 시 세션 종료가 물리 차단된다):
       Skill('goal') 로딩 → lock_request=true 전달 → locked=true로 생성
       이유: o4/o5의 oplan_deep/consult/debate는 goal.json을 읽기만 하고 생성하지 않는다.
             oto가 직접 만들지 않으면 계약 문서가 아예 없고,
             PreToolUse_oto_completion_guard.sh F-OTO-1이 IDLE 전이를 차단한다.
       acceptance 작성: goal/SKILL.md §3.1(스키마) + §3.2(완주 불가 3분류) 준수.
         · blocked/blocked_by 제외 전 항목에 auto_script 필수
           (없으면 게이트가 no-op이 되어 locked의 의미가 사라진다)
         · 각 항목에 §3.2 판정 질문을 적용하여 depends_on 확정
         · 권한 밖 항목만 status:"blocked" + 열거값 blocked_reason + 실측 blocked_evidence
         · blocked_전파 규칙 1회 계산 → blocked_by 확정. 나머지는 전부 open.
    2. oroof Phase 0 Step 2~3과 동일한 절차를 인라인 수행 (oroof_active + status_add ROOF)
    3. 경로 단일화 확인 (필수):
       goal.json / oroof_active / status / auto 네 파일이 모두 같은 session-env
       디렉토리에 있는지 기록 직후 검증한다.
       배경: /tmp/cc-*/session-env/${UUID}/ 와 $HOME/.claude/session-env/${UUID}/ 가
             동시 실존하며 내용이 갈린 사고가 실측되었다(2026-08-24).
             auto만 한쪽에 있고 나머지가 다른 쪽에 있으면 ofinish Step 8의 ROOF gate가
             발동하지 않아 검증 루프가 통째로 건너뛰어진다.
       불일치 시: 즉시 사용자에게 보고하고 중단한다 (자율 진행 금지 — 계약 자체가 깨진 상태).
  상세: "## 목표 계약 + 반복 검증 완주" 섹션 참조

2_ok_로딩:
  Skill('ok') 로딩 후 아래 지시를 전달:
  "/ok 자율모드(auto=ON)로 진행하라 — {사용자 원본 요청}"
  tier: oplan이 실규모로 결정 (ok와 동일 — /oto는 tier를 강제하지 않음)

3_자율_진행:
  파이프라인 전 구간에서 아래 "자율 결정 원칙" 적용
```

## 목표 계약 + 반복 검증 완주 (goal + oroof 통합)

oto는 Skill('oroof')를 호출하지 않는다. oroof Phase 0/Phase 2와 동일한 알고리즘을
메인이 직접 인라인으로 수행한다(팀에이전트 spawn 없음). 이렇게 하면 oroof/goal/ok/ok_pipeline/
ofinish/state_machine.sh를 전혀 수정하지 않고도 목표 달성까지 반복 검증을 흡수할 수 있다.

```yaml
oroof_active_세팅 (Phase 0 Step 2~3과 동일 — auto 플래그 기록과 동일 시점):
  1. 검증 기준 도출 (사용자 요청 텍스트에서):
     - 빌드 성공 여부 (소스코드 변경 시 기본 포함)
     - 테스트 통과 여부 (테스트가 있는 경우)
     - 사용자 요청의 핵심 기능 동작 확인
  2. mcp__oio__file_write(
       path="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/oroof_active",
       content='{
         "session_uuid": "{UUID}",
         "criteria": "{검증 기준 1줄 요약}",
         "criteria_detail": ["{조건 1}", "{조건 2}", "{조건 3}"],
         "max_iterations": 5,
         "current_iteration": 0,
         "original_request": "{사용자 원문 요청}"
       }',
       overwrite=true
     )
  3. status 축에 ROOF 등록 (재사용 — 신규 토큰 생성 절대 금지):
     bash -c 'source ${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/state_machine.sh; status_add "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/status" ROOF'
     이유: state_machine.sh의 _STATUS_VALID_TOKENS는 "ABORT PAUSE RALPH ROOF" 4토큰이다.
           미등록 토큰은 status_add가 조용히 return 1로 거부한다. oto는 기존 토큰을 재사용하여
           ofinish Step 8의 기존 gate 로직을 그대로 탄다.
     ROOF-COMPAT(deprecation window 1주기): 생성값은 ROOF/oroof_active 이고, 검사(status_has·존재 판정)는
           구 RALPH/oralph_active(.json) 도 인식한다. 구 이름 플래그 파일이 있으면 roof_flag_path 가
           돌려주는 파일을 그대로 갱신하며 RALPH→ROOF 재기록(정규화)은 하지 않는다.

goal_json_병합 (oroof Phase 2 Step 1.5와 동일 알고리즘):
  전제: oto는 1_5_목표계약_세팅에서 goal.json을 locked=true로 직접 생성하므로
        정상 흐름에서는 항상 존재하고 항상 locked==true다.
  goal.json 존재 + locked==true (정상 경로):
    _GOAL_PATH = "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/goal.json"
    goal.acceptance[] 중 status가 blocked/blocked_by가 **아닌** 항목만 criteria_detail에
    append(중복 제외)하여 검증 판정에 포함한다(hard gate).
    ⚠️ blocked/blocked_by 항목은 append하지 않는다 — fail로 세면 루프가 끝나지 않는다.
  goal.json 존재 + locked==false (타 스킬이 만든 경우):
    acceptance는 참고용 시드로만 병합하고 criteria_detail 판정을 그대로 유지한다.
  goal.json 부재:
    비정상이다. PreToolUse_oto_completion_guard.sh F-OTO-1이 세션 종료를 차단한다.
    1_5_목표계약_세팅으로 돌아가 goal.json을 생성한 뒤 진행하라.

검증_루프_진입 (Phase 2와 동일 — 인라인, 팀에이전트 spawn 없음):
  ofinish Step 8이 "⏳ [oroof] ... → oroof Phase 2 즉시 수행"을 출력하면,
  이는 oto 자신의 반복 검증 신호다. oto는 즉시 아래 절차를 메인이 직접 수행한다
  (oroof/SKILL.md "Phase 2: oroof 내장 검증 루프" 절차와 100% 동일):
    1. oroof_active 로드(roof_flag_path 로 찾은 파일 — 구 oralph_active(.json) 도 인식, ROOF-COMPAT) → criteria_detail 항목별 pass/fail 판정
       (goal.json locked=true 시 goal_json_soft_병합에서 추가된 acceptance 항목 포함)
    2. 모두 pass(잔업 0) → 최종 종료. 순서 고정(M4): ① state=IDLE 먼저 → ② oroof_active 삭제 →
       ③ status_remove ROOF → ④ auto 삭제 → ⑤ oto_chain_root 삭제 → 완료 배너.
       근거: oroof_active·ROOF를 먼저 지우면 F-OTO-7b(완주 가드)·F-OTO-7Bb(write_guard)가
       IDLE 전이를 필연 차단한다(실세션 로그 BLOCK 27건). IDLE 전이가 먼저여야 한다.
       잔업이 있으면(open FAIL·판정불가 또는 잔여 phase batch) 이 최종 종료 대신
       "잔업 이월과 자동 이어받기" 절의 A1~A5를 따른다. 잔업 체크 없이 종료하는 것은 금지다.
    3. 일부 fail + 잔여 iteration → current_iteration++ → state=DEV →
       실패 항목 기반 재진입 프롬프트 구성 → Skill('ok_pipeline') 재호출 또는 odev 재spawn
       (재시도 사유·수정 방향도 oto가 스스로 판단 — 질문 금지, 자율 결정 원칙 적용)
    4. max_iterations 도달(또는 EARLY_TERM)인데 fail이 남음 → max_iterations 는 종료 사유가 아니다.
       "잔업 이월과 자동 이어받기" 절로 이월한다(A1~A5, 체인 사이클 상한 미만일 때).
       EARLY_TERM·cycle_cap·no_progress 에 해당할 때만 oto_incomplete.json 작성 → state=IDLE →
       oroof_active 삭제 → status_remove ROOF (M4 순서) → "상한·EARLY_TERM 미완료 보고" 절차로 종료
       (상한 전에는 "모두 fail"이어도 3으로 돌아가 루프를 계속 돈다)
    ※ 루프 도중 새로 찾은 결함·필요 기능은 "자율 발견 처리" 절로 goal.json에 덧붙여 같은 루프에서 처리한다.

status_토큰_재사용_고지:
  ROOF 토큰을 재사용하므로 ofinish Step 8의 출력 문구(예: "⏳ [oroof] ...",
  "→ oroof Phase 2 즉시 수행")가 그대로 표시된다. 이는 oto의 검증 루프가 정상 동작 중이라는
  뜻이며, oroof가 대신 실행되는 것이 아니다. ofinish/state_machine.sh는 무수정이므로
  문구 자체는 바뀌지 않는다.

카운터_상호작용_경고 (필독):
  oroof_active(current_iteration/max_iterations=5), ofinish_recurse_count(상한3),
  reroute_count(상한20)는 서로 다른 축이며 oto가 신규로 만드는 카운터는 없다.
  단, ROOF 활성 중에는 ofinish Step 8 gate 분기가 Step 4(임시파일 정리)를 건너뛰므로
  reroute_count가 라운드마다 리셋되지 않고 누적된다. 이로 인해 reroute_count의 20회 상한
  (EARLY_TERM)이 oroof_active.max_iterations(5)보다 먼저 도달할 수 있다.
  이 특성은 기존 oroof도 동일하게 가지고 있는 것이며 oto가 만드는 신규 버그가 아니다.
  EARLY_TERM이 먼저 발동하면 oto는 이를 "미완료"가 아니라 "강제중단"으로 사용자에게
  다르게 보고해야 한다(정보 정직성 원칙).
```

## 완주 불가 항목 처리 (이탈 금지 — 2026-08-24 신설)

> **사고 계기**: /oto가 완주 불가 항목 1건(타 세션 MCP 서버 재시작 — 정당한 권한 밖)을
> 이유로, **그것에 의존하지 않는 가능 항목까지 묶어서 미루고** 조용히 종료했다.
> 불가 항목의 존재가 가능 항목을 끌고 간 것이 결함의 본질이다.
> 타 세션 제어를 하지 않은 것 자체는 옳다 — 문제는 전염이다. 이를 잡을 장치가 당시 0개였다.

```yaml
3분류_판정 (판정 질문은 단 하나):
  "이 항목을 지금 이 세션의 에이전트가 도구 호출만으로 종료 상태까지 옮길 수 있는가?"

  B1_진짜불가 → status:"blocked"
    아래 enum 사유 중 하나에 정확히 해당할 때만:
      "타세션_프로세스_재시작_필요" | "사용자만_아는_값_필요"
      | "물리장비_외부인력_필요" | "도구_권한거부_로그_존재"
      (+ "선행_blocked_항목_의존" — 전파 전용, 사람이 직접 지정 금지)
    enum 밖 사유는 B1이 될 수 없다.

  B2_조건부가능 → 선행 작업을 별도 acceptance 항목으로 분해하여 둘 다 open
    지금 실행하면 실패하지만 이 세션 안에서 가능한 선행 작업 X가 있는 경우.
    X를 1줄로 특정할 수 없으면 B2가 아니라 B3다.

  B3_가능한데미룸 → 존재하지 않는 분류. 전부 open(완주 대상)이다.
    ⛔ 아래는 전부 B3다 (B1로 위장하지 마라):
      "시간·토큰·컨텍스트 부족" / "위험해 보임" / "범위가 크다" / "확신이 없다"
      / "사용자가 시점을 정해야 함" / "다음 사이클이 적절함"
      / "다른 항목이 불가라 함께 미룸"
    → 전부 B3이며 이탈이다. "사용자가 시점을 정해야 함"은 2026-08-24 이탈에서 실제로 쓴 문구다.
    → 팀에이전트(otest 등)의 "시간 예산 초과 — 미측정 N항목 남기고 마감 보고"도 B3다(L-979, 2026-09-06 사이클88 실례).
      메인은 불수용하고 예산을 해제하며, 측정 수단의 문제(창 경합 등)면 수단을 바꿔 계속한다. 그 8항목 안에 회귀 D-11 이 있었다.

전염_금지 (핵심):
  어떤 항목이 blocked라는 사실은 다른 어떤 항목의 분류에도 영향을 주지 못한다.
  분류는 항목 단위로만 판정하며, blocked는 goal.json의 depends_on 그래프를 타고서만
  전파된다 — "같은 기능의 일부" / "같은 문서의 다음 절" / "순서상 뒤"로는 절대 번지지 않는다.
  "활성화가 불가라서 규칙 작성도 미룬다"는 판단은 정의상 B3 = 이탈이다.
  ⚠️ 방향성 주의: 이번 사고는 오히려 불가 항목(A8 활성화)이 가능 항목(A7 규칙 작성)의
     산출물을 필요로 하는 구조였다. depends_on 그래프를 한 번만 그렸어도 즉시 드러났다.

  의존 판정 질문: "X를 실행하지 않은 상태에서 이 항목의 auto_script를 지금 실행하면 FAIL하는가?"
    → YES 여야만 depends_on에 X를 넣는다. 실행해서 확인할 수 있으면 확인하라.
  ⛔ 의존이 아닌 것: 완성도("X 없으면 전체가 완성 안 됨") / 의미("X 없이 해봐야 의미 없음")
     / 서술 순서("같은 단계에 묶여 있음") / 선호("X 다음이 자연스러움")

종료_가능_조건 ("전 항목 pass"를 대체):
  (모든 status:"open" 항목이 pass) AND (모든 blocked/blocked_by 항목이 근거를 갖춤)
  · blocked/blocked_by는 fail로 세지 않는다 — 세면 루프가 영원히 끝나지 않는다.
  · pass도 blocked도 아닌 항목은 전부 fail이며 루프가 다시 돈다. B3는 존재하지 않는 분류다.

blocked_승격_금지 (자기기만 차단):
  검증 루프 도중 open → blocked 승격은 금지한다.
  물리 근거: locked=true 상태에서 write_guard.sh F-GOAL-1이 goal.json 수정을 block한다.
  덧붙이기(goal_append) 예외는 새 항목을 open으로만 넣게 한다. 기존 항목을 blocked로 바꾸는 길은 없다.
  "해보니 안 되더라"는 blocked 사유가 아니라 fail이며 루프가 다시 돈다.
  진짜로 불가능하면 max_iterations 소진 후 잔업 이월로 이어지고, 체인 상한·진전 없음에 닿으면 미완료 보고로 끝난다. 그것이 정직한 경로다.
  → 작업 시작 전, 회피 동기가 생기기 전에 판정을 확정시키는 것이 이 제약의 목적이다.

미완료_잔여_시_필수_행동 (조용한 종료 금지 — hook이 물리 차단):
  open 항목에 fail(판정불가 포함)이 남아 있으면 검증 루프를 다시 돈다(FINISH→DEV→TEST).
  검증 루프 상한(max_iterations)에 닿아도 잔여가 있으면 종료하지 않고 carryover 로 이월한다.
  "잔업 이월과 자동 이어받기" 절을 따른다.
  선택지는 셋이다 — 이번 사이클에 완주하거나, 유효한 carryover(handoff_kind:"carryover")로
  잔여 id를 이월해 곧바로 다음 사이클을 착수하거나, 애초에 blocked로 등록했거나.
  상한(early_term·cycle_cap·no_progress)에 닿았을 때만 oto_incomplete.json으로 정직하게 보고한다.
  조용한 종료(이월 기록 없는 잔여 종료)는 없다.
  F-OTO-2(PreToolUse_oto_completion_guard.sh)는 잔여가 있는데 유효한 carryover·oto_incomplete가
  없으면 IDLE 전이를 막는다.

blocked_carryover (blocked 항목만 인계 — handoff_kind:"blocked_only"):
  다음 사이클로 넘길 수 있는 것은 blocked enum 사유 항목(사용자 조치가 필요한 것)뿐이다.
  next_action.json은 이 용도로만 쓴다.
  스키마 (기존 4필드 + 3):
    {"slash_command":"/oto", "task_description":"...", "reason":"...", "created_at":"...",
     "handoff_kind":"blocked_only",
     "blocked_ids":["A8"],
     "blocked_carryover":[
       {"id":"A8", "desc":"...", "blocked_reason":"타세션_프로세스_재시작_필요",
        "blocked_evidence":"...", "user_action":"사용자가 할 조치 1줄",
        "prereq_done":["A6 ... ✅","A7 ... ✅"]}]}
  조건: handoff_kind는 반드시 "blocked_only"다. blocked_ids는 goal.json의
        status:"blocked"·"blocked_by" 항목 id만 담는다. open 항목 id를 넣으면 인계가 아니라 이탈이다.
  물리 강제 (F-OTO-9): auto=ON 세션의 next_action.json이 이 조건을 어기면 두 곳에서 막힌다.
    · write_guard.sh는 next_action.json 쓰기 자체(file_write·edit·copy·move, 셸 쓰기)를 막는다.
    · 완주 가드는 IDLE 전이를 막는다.

  ⚠️ 무한 autoloop 방지 (필수 안전망):
    blocked_only 인계는 open 잔여 fail이 0건일 때만 생긴다. 이때 autoloop을 발동시키지 않는다.
    next_action.json은 보존하되 소비하지 않으며, 다음 사용자 입력 시 1회 안내한다.
    이유: 환경이 그대로면 자동 재시도해도 결과가 같다. 사용자 조치가 선행되어야 한다.
          이 분기가 없으면 "묻지 않고 완주"가 "묻지 않고 3회 헛돌기"로 변질된다.
    open 잔여 fail의 이월은 blocked_only 가 아니라 handoff_kind:"carryover" 로만 한다
    ("잔업 이월과 자동 이어받기" 절). 두 종류를 한 파일에 섞지 않는다.

기록_위치 (3곳 분담 — 셋 다 필요하며 대체 불가):
  goal.json          정본. 판정·게이트가 읽는 유일한 출처. locked=true 물리 보호를 받는다.
                     같은 사이클에 찾은 항목은 덧붙이기(goal_append)로만 넣는다.
  next_action.json   이어받기 기록. handoff_kind:"blocked_only"(blocked 항목) 또는 "carryover"(open 잔여 이월).
  oto_incomplete.json 상한(early_term·cycle_cap·no_progress) 미완료 보고. 정직한 종료 기록이다.
  ofinish 최종 배너   사용자 보고. 파일은 사용자가 보지 않는다.
  ⛔ observations.md는 부적합 — 세션 스코프이며 인계 채널이 아니다(파일 자체가 명시).

보고_어법 (질문 아님 — 5요소 필수):
  필수: 사실 + 사유 + 근거 + 사용자 조치 + 인계 위치
  금지: "언제 하시겠습니까" / "진행할까요" / "어떻게 할까요"
        / 선택지를 나열하고 고르라고 요구하는 형태
  이유: oto 자율 원칙(질문 금지)은 blocked 보고에서도 해제되지 않는다.
        보고는 정보 전달이지 승인 요청이 아니다.

  형식 (템플릿):
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    ✅ [oto] 완주 — open 항목 N/N 완료
    🔎 자율 발견 처리 K건
    🚧 사용자 조치 필요 M건 (질문 아님 · 보고)
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
     {id}  {desc}
         불가 사유: {enum} — {1줄 설명}
         근거: {실측 근거}
         선행 완료: {prereq_done}
         사용자 조치: {user_action}
         인계: next_action.json에 기록됨 — 조치 후 /oto로 이어받기 가능
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  출력 예시 (구체 사례):
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    ✅ [oto] 완주 — open 항목 7/7 완료
    🚧 사용자 조치 필요 1건 (질문 아님 · 보고)
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
     A8  oio MCP 서버 재시작 후 필터 활성화
         불가 사유: 타 세션 프로세스 재시작 필요 — 타 세션 제어는 하지 않는다
         근거: 이 세션이 제어 가능한 프로세스 목록에 미포함 (실측)
         선행 완료: A6 골든 스위트 실측 ✅ / A7 필터 규칙 2종 작성 ✅
         사용자 조치: 각 세션 /mcp 재연결 후 활성화 플래그 ON
         인계: next_action.json에 기록됨 — 조치 후 /oto로 이어받기 가능
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

## 자율 발견 처리 (사이클182 신설 — 사용자 지시)

> 사용자 원문: "oto 스킬을 사용하면 자유롭게 새롭게 발견된 결함이나 추가로 필요한 기능이나
> 로직등을 자유롭게 스스로 생각해서 가장 추천하는 방법으로 처리하도록 해달라"
> (이후 사용자 지시로 변경: 잔업은 다음 사이클로 넘겨도 되되 종료 시 잔업을 체크해 곧바로 자동 착수한다)

```yaml
원칙:
  사이클 도중 새로 찾은 결함, 추가로 필요한 기능·로직은 계약(goal.json) 범위 밖이어도 처리한다.
  처리 여부와 방법은 에이전트가 실측 근거로 판단하고, 가장 권장하는 방법을 택한다. 사용자에게 묻지 않는다.
  처리는 가능하면 이번 사이클 안에서 끝낸다. 끝내지 못한 잔여는 "잔업 이월과 자동 이어받기" 절의 carryover 로
  곧바로 다음 사이클에서 이어받는다(조용히 방치하지 않는다).
  범위 확장은 허용한다. 범위 축소 금지는 그대로다(자율_결정_예외 참조).

누가:
  발견은 메인과 팀에이전트 누구나 한다. 팀에이전트는 SendMessage(to:"team-lead")로 보고한다.
  판정·처리 결정과 goal.json 덧붙이기는 메인이 한다.

기록 (auto_decisions.jsonl — 1건마다 3줄, 생략 금지):
  경로: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/auto_decisions.jsonl
  도구: mcp__oio__session_state(uuid, key="auto_decisions.jsonl", value=<1줄>, append=true)
  형식 (키 순서·공백 그대로 — 집계가 문자열로 센다):
    {"ts":"...","phase":"발견","id":"D-1","from":"odev-3","what":"무엇을 찾았나","evidence":"실측 근거(파일:행·rc·로그)"}
    {"ts":"...","phase":"판정","id":"D-1","need":"필요|불필요","reason":"판단 근거"}
    {"ts":"...","phase":"처리","id":"D-1","route":"append|existing|blocked|unneeded","goal_ids":["K1"]}
  route 뜻:
    append    잠긴 goal.json에 새 항목으로 덧붙여 이번 사이클에 구현·검증한다(기본).
    existing  기존 acceptance 항목이 이미 덮는다. goal_ids에 그 id를 적는다.
    blocked   blocked enum 사유에 정확히 해당한다. 덧붙이지 않고 최종 보고에 사용자 조치로 적는다.
              enum 밖 사유는 blocked가 될 수 없다(완주 불가 항목 처리 절 3분류).
    unneeded  실측으로 불필요하다고 판정했다. reason에 근거를 남긴다.

판정 (필요/불필요):
  실측 근거로만 정한다. "있으면 좋겠다"는 필요가 아니다. "범위가 크다"·"다음이 낫다"는 불필요 사유가 아니다.
  확신이 없으면 advisor()를 호출한다(메인). 사용자에게 묻지 않는다.

처리 순서 (route=append — goal_append):
  1. 항목 JSON 작성: plans/ 아래에 덧붙일 항목을 둔다. 형식은 goal/SKILL.md §3.1이다.
     status는 "open"이고 auto_script는 필수다.
  2. 판정 스크립트에 item을 추가한다. 새 auto_script는 그 산출물을 검사해야 한다(auto_script 작성 규칙 참조).
  3. 수정 전 FAIL 확인: 새 auto_script를 지금 실행해 rc=1인지 본다.
     rc=0(이미 충족)이나 rc=3(판정불가)이면 F-GOALAS-8이 기록을 막는다. 항목이나 스크립트를 고친다.
  4. 덧붙이기: 잠긴 goal.json에 "기존 내용 그대로 + acceptance 끝에 새 항목"을
     mcp__oio__file_write로 쓴다. 덧붙이기 조건은 goal/SKILL.md "locked 덧붙이기 예외" 절을 따른다.
     기존 항목의 글자 하나라도 바뀌면 F-GOAL-1이 막는다.
  5. acceptance_criteria.json(AC)에 같은 항목을 반영한다.
  6. DEV 재진입 → 구현 → TEST로 새 항목을 판정받는다. 이 항목도 다른 open 항목과 똑같이 PASS여야 종료할 수 있다.

최종 보고:
  ofinish 배너에 "자율 발견 처리 N건"을 넣는다. 0건이어도 "자율 발견 처리 0건"으로 적는다.
  N = grep -c '"phase":"처리"' auto_decisions.jsonl (파일 부재 시 0)
  각 건은 "D-n {what} → {route} ({goal_ids})" 1줄로 요약한다.

잔존 한계 (정직 고지):
  덧붙이기 조건은 형식 판정이다. 새 항목이 정말 필요한지는 가드가 판정하지 못한다.
  가드가 강제하는 것은 수정 전 FAIL(F-GOALAS-8)뿐이다. 필요성 판정은 위 기록과 사후 검토가 맡는다.
  셸 경로(jq > goal.json 등)의 덧붙이기는 허용하지 않는다. file_write만 쓴다.
```

## 잔업 이월과 자동 이어받기

> 사용자 지시: "필요한 경우 다음 사이클로 넘겨도 된다. 다만 한 사이클이 끝날 때 잔여 작업이나
> 잔여 사이클이 있으면 곧바로 이어서 자동으로 진행" / "auto flag를 켜면 작업 종료 시 항상
> 잔업 사이클이 있는지 체크해야 하고 있으면 무조건 진행해야 한다."

```yaml
규칙:
  oto 모드(auto=ON)에서는 사이클이 끝날 때마다 잔업(open FAIL·판정불가, 잔여 phase batch)이 있는지 반드시 체크한다.
  잔업이 있으면 사용자 입력을 기다리지 않고 곧바로 다음 사이클을 착수한다. 잔업 체크 없이 종료하는 것은 금지다.
  잔업을 다음 사이클로 넘기는 유일한 통로는 next_action.json 의 handoff_kind:"carryover" 기록이다.
  기록 없이 잔여를 남기고 종료하는 것(조용한 종료)은 F-OTO-2 가 물리 차단한다.

carryover_스키마 (next_action.json):
  {"slash_command":"/oto", "task_description":"잔여 A3·A5 이어서 완주", "reason":"이월 사유 1줄",
   "created_at":"ISO", "handoff_kind":"carryover", "chain_root":"G-xxxxxxxx",
   "carry_ids":["A3","A5"], "carry_detail":[{"id":"A3","desc":"...","why":"..."}]}
  조건:
    - slash_command 는 반드시 "/oto" 다(/ok 등으로 대체하면 auto 가 정리되어 일반 모드로 강등된다).
    - carry_ids 는 현 goal.json 의 status:"open" 항목 id만 담는다. FAIL·판정불가 잔여 id 를 전부 포함해야 한다.
      blocked·blocked_by id 는 넣지 않는다(그건 blocked_only 인계다).
    - chain_root 는 첫 사이클의 goal_id 다. 이어받은 사이클은 소비한 carryover 의 chain_root 를 그대로 쓴다
      (진입부가 ${SD}/oto_chain_root 에 보관한다).
  blocked_only 인계(사용자 조치 필요 항목)는 "완주 불가 항목 처리" 절 blocked_carryover 를 따른다. 두 종류는 한 파일에 섞지 않는다.

이월_종료 A (이월 사이클 종료 — Phase 2, state=FINISH 유지 중, 메인이 수행):
  A1. goal.json 의 goal_id 를 file_read 로 확인한 뒤
      mcp__oio__file_copy(source=goal.json, destination=goal_{goal_id}_completed.json). copy 는 locked 와 무관하게 통과한다.
  A2. mcp__oio__file_edit 로 goal.json 의 locked 필드 "한 필드만" true→false 로 바꾼다
      (state==FINISH, 사본 동일 조건 충족). unlock 전에 goal.json 의 locked 직렬화 형식(공백 유무,
      예 "locked":true 와 "locked": true)을 file_read 로 먼저 확인하고 그 형식 그대로 old/new 를 맞춘다.
  A3. carryover next_action.json 을 mcp__oio__file_write 로 작성한다(write_guard F-OTO-9 carryover 분기 통과).
  A4. state=IDLE (단독 호출). 이월 경로는 oroof_active·status ROOF·auto 를 지우지 않는다.
      근거: F-OTO-7(ROOF·oroof_active 둘 다 없으면 IDLE 차단)과 carryover 의 current_iteration 판독 때문이며,
      다음 진입부가 재설정한다. 이월 시 auto 보존의 실효 주체는 oto Phase 2 다
      (oto 는 ROOF 활성이라 ofinish Step 8 이 조기 return 하므로 ofinish 의 auto 삭제는 실행되지 않는다).
  A5. 턴을 끝내려 하면 Stop_oto_residual_guard(R1)가 막는다 → 메인은 즉시 `/oto {task_description}` 를 실행한다.
  이월 전 조건: 이번 사이클에서 검증 루프(FINISH→DEV 재진입)를 최소 1회 돌았어야 한다(oroof_active current_iteration ≥ 1).

진입부_이어받기 B (다음 /oto 진입부 "0_잔업_이어받기", state IDLE→PLAN 직후):
  B1. next_action.json 이 handoff_kind=carryover 면
      mcp__oio__file_move(source=next_action.json, destination=logs/consumed_carryover_<YYYYmmdd_HHMMSS>.json).
      사이클 수는 이 소비 흔적 파일 수로 센다(메인 자기신고 숫자가 아니다).
  B2. goal.json 이 있고 locked=false 이며 같은 goal_id 의 goal_{goal_id}_completed.json 사본이 있으면
      mcp__oio__file_delete(goal.json) 한다(locked=false 라 F-GOAL-1 무관).
      locked=true 로 남아 있으면 삭제·이동하지 말고 "A 단계 누락" 으로 보고하고 중단한다(우회 금지).
  B3. carry_ids 항목(원 goal 의 desc·auto_script)을 시드로 새 goal.json 을 생성한다(locked=true).
  B4. oroof_active current_iteration=0 으로 재설정, ROOF 유지, auto 유지, ${SD}/oto_chain_root 에 chain_root 를 기록한다.

상한과_진전없음:
  체인 사이클 상한 OTO_CYCLE_MAX 기본 5(같은 chain_root 의 consumed_carryover 파일 수 기준).
  상한에 닿았거나(cycle_cap), 같은 체인 최근 소비 2건의 carry_ids 집합이 현재 잔여 집합과 같으면(no_progress)
  더는 이월하지 않고 oto_incomplete.json 으로 정직하게 보고한다.
  cycle_cap 도달 시 순서 고정: ① next_action.json(carryover) 삭제 → ② oto_incomplete.json(reason=cycle_cap) 작성 → ③ IDLE.
  ABORT·PAUSE·사용자 중단은 항상 우선한다(자동 착수하지 않는다).

그대로_두는_장치:
  ofinish autoloop 3회 상한(ofinish_recurse_count)·같은 작업 반복 감지는 blocked_only 인계와
  phase batch(phase_batches.json) 자동 진행에 그대로 적용된다.
  잔여 phase batch 도 잔업이다(F-OTO-10: current_phase_batch < total_batches 면 IDLE 차단).

물리_강제:
  F-OTO-2 (완주 가드): auto=ON에서 open FAIL·판정불가가 남으면 유효한 carryover(carry_ids ⊇ 잔여 id, 상한 미만)
           또는 유효한 oto_incomplete(early_term·cycle_cap·no_progress)가 없는 한 IDLE 전이를 막는다.
  F-OTO-9 (write_guard + 완주 가드): auto=ON 세션의 next_action.json 이 blocked_only 도 carryover 도 아니면
           쓰기와 IDLE 전이를 모두 막는다. 잔여 0 인데 carryover 가 있으면 이월할 잔여가 없으므로 막는다.
  Stop_oto_residual_guard (Stop hook): state=IDLE 이고 미소비 carryover 또는 잔여 phase batch 가 있으면
           턴 종료를 차단해 즉시 다음 사이클을 착수시킨다. 같은 서명 연속 2회 차단 후 3회차는 탈출시킨다(무한 차단 금지).
           한계: 턴 종료를 막을 뿐 메인이 실제로 /oto 를 호출하는지는 판정하지 못한다.
```

## 상한·EARLY_TERM 미완료 보고 (oto_incomplete.json)

```yaml
언제:
  open 항목에 FAIL·판정불가가 남았고 아래 reason 중 하나에 해당할 때만 쓴다.
  그 밖의 경우에는 루프를 계속 돌거나 carryover 로 이월한다.
  max_iterations 는 더 이상 종료 사유가 아니다(검증 루프 상한에 닿으면 carryover 로 이월).
  reason 표:
    early_term  역라우팅 상한 EARLY_TERM(reroute_count ≥ 20)으로 강제중단됐다.
    cycle_cap   같은 chain_root 의 consumed_carryover 수가 OTO_CYCLE_MAX(기본 5) 이상이다.
    no_progress 같은 체인 최근 소비 2건의 carry_ids 집합이 현재 잔여 id 집합과 같다(진전 없음).

경로: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/oto_incomplete.json
형식:
  {"fail_ids":["F1","U1"],
   "reason":"cycle_cap",
   "iteration":5,
   "max_iterations":5,
   "detail":"항목별 남은 원인 1줄씩 — 판정불가는 FAIL과 구분해 '판정불가'로 표기"}

가드_통과_조건 (F-OTO-2):
  - fail_ids가 현재 open FAIL·판정불가 id를 모두 포함한다(빠뜨리면 차단).
  - reason="early_term"이면 reroute_count ≥ 20이다.
  - reason="cycle_cap"이면 같은 chain_root 의 consumed_carryover 수 ≥ 상한이다.
  - reason="no_progress"이면 같은 체인 최근 소비 2건의 carry_ids 집합 == 현재 잔여 집합이다.
  - 상한에 닿지 않았는데 쓰면 차단된다. 루프를 계속 돌거나 carryover 로 이월해야 한다.

순서:
  oto_incomplete.json을 먼저 쓰고 IDLE 전이를 한다(cycle_cap 은 carryover 삭제 → oto_incomplete 작성 → IDLE).
  IDLE 전이 후에 oroof_active 삭제 → status_remove ROOF → auto 삭제 → oto_chain_root 삭제 순으로 정리한다(M4).
  oroof_active는 IDLE 전이 가드가 읽으므로 IDLE 전이 전에 지우지 않는다.

보고 (질문 아님):
  배너: "⚠️ [oto] 미완료 — {체인 상한 도달(cycle_cap) | 진전 없음(no_progress) | 강제중단(EARLY_TERM)}"
  필수: 남은 id 목록, 항목별 원인, 사유(reason), 이월 사이클 수.
  EARLY_TERM은 "미완료"가 아니라 "강제중단"으로 구분해 보고한다(정보 정직성 원칙).
  사실과 원인만 보고한다.

한계 (R5 — 정직 고지):
  oroof_active.current_iteration과 oto_incomplete.json.iteration은 메인이 스스로 써 넣는 값이다.
  가드는 이 숫자가 실제로 돈 반복 횟수와 같은지 검증하지 못한다.
  즉 숫자를 올려 적으면 상한 조건을 거짓으로 맞출 수 있다.
  ⇒ 반복마다 current_iteration을 올리는 시점은 DEV 재진입 직전 1회뿐이다. 그 외의 갱신은 금지한다.
  ⇒ 각 반복의 재진입 사유를 auto_decisions.jsonl에 남겨 사후 대조가 가능하게 한다.
```

## 안전장치 유지 (자율 발견 처리·잔업 이월과 함께 그대로 적용)

```yaml
- 가드 우회 금지: hook 차단을 이름 바꾸기·우회 경로로 피하지 않는다. 과차단이면 보고한다(L-597).
- 보호 파일·가드 갱신은 promote 경로로만 한다(guard_promote.sh promote).
- 운영 배포는 하지 않는다. 최종 보고의 보류 목록에 남긴다.
- root 권한(sudo 등)을 쓰지 않는다.
- 세션 격리: 자기 UUID 하위에만 쓴다. 타 세션 프로세스·파일을 건드리지 않는다.
- 비파괴 우선: 파괴적 가능성이 있으면 비파괴 대안·스냅샷을 먼저 한다.
- 범위 축소 금지: 덧붙이기는 범위를 넓힐 뿐이다. 기존 항목 삭제·완화·blocked 전환은 허용되지 않는다.
- 질문은 외부 사실(자격증명·미공개 URL·사용자만 아는 값)만 한다.
- 가드 작업의 분류기·과차단 위험 수정은 에이전트가 구현하지 않는다(2026-10-27 사용자 지시, Mars pdg_core 사례).
  oplan "분류기·과차단 위험 판정" 절을 따라 그 항목을 사람용 수정 매뉴얼 산출 항목으로 바꾼다.
  이것은 blocked 사유(enum)가 아니고 B3(미룸)도 아니다. 매뉴얼 산출 자체가 open 항목이므로 완주 대상이다.
  위험하지 않은 다른 항목은 그대로 진행한다.
```

## 계약 문언 우선 원칙

```yaml
원칙_선언:
  goal.json acceptance의 desc 원문이 최상위 지시다.
  메인·팀에이전트가 내리는 모든 지시는 원문의 하위이며, 충돌 시 원문이 이긴다.

금지_행위:
  메인이 팀에이전트에 지시할 때 acceptance 원문과 충돌하는 제약을 임의로 추가하지 못한다.
  - 원문이 요구하는 행위를 금지하는 지시 (예: 원문이 "push"를 명시했는데 "git 조작 금지" 지시)
  - 원문에 없는 축소를 부과하는 지시
  작업 순서·구현 방식은 재량이나, 원문이 요구하는 행위를 금지하는 지시는 재량 밖이다.

실사고_근거 (사이클51):
  goal.json C6(구 B6)이 "커밋하고 push까지 완료한다"를 명시했음에도,
  메인이 odone에게 "git push 금지"를 지시하여 계약 위반이 발생했다.
  사용자가 "마무리되었나?"라고 묻지 않았다면 미발견 종료됐을 것이다.

팀에이전트의_의무:
  지시문과 acceptance 원문이 충돌하면 임의 판단으로 어느 한쪽을 따르지 말고,
  SendMessage(to="team-lead")로 충돌 사실을 보고하고 대기한다.
  (기존 L-390 "담당 파일 불일치 보고 의무"와 동일 패턴)

정당한_범위_축소의_유일한_경로:
  계약을 좁히려면 locked=false로 내리고 goal.json 자체를 수정하는 것뿐이다.
  지시문으로 우회하는 것은 계약 위반이다.

물리_근거_연결:
  goal.json은 locked=true이며 write_guard.sh F-GOAL-1이 수정을 물리 차단한다.
  즉 원문은 이미 물리적으로 불변이다. 따라서 "원문과 충돌하는 지시는 정의상 무효"가 성립한다.

한계_명시 (숨기지 않는다):
  본 원칙은 문서 규칙이며 hook 물리 차단이 아니다.
  hook 물리 차단 3안을 검토해 전부 기각했다.
    안1 (지시문↔acceptance 자동 대조): 모순 판정이 자연어 의미 추론이라 셸 hook 범위 밖.
        금지어 목록을 두면 정당한 맥락까지 오차단하고 표현 변형에는 무력하다.
    안2 (키워드+부정어 동시출현 감지): 안1의 축소판. 게다가 본 계획서 자체가
        "git 조작 금지"와 "push"를 함께 담고 있어 자기 자신을 차단한다 — 자기모순 실증.
    안3 (goal.json 자동 첨부 강제): 정보 접근성만 개선할 뿐, 첨부 후 메인이 충돌 제약을
        덧붙이는 것을 막지 못해 C5의 원인을 해결하지 못한다.
  결론: 차단 대상이 자연어 의미론적 모순이므로 hook은 판정 범위 밖이다.
  CLAUDE.md 재발방지 정책상 문서 조치는 최후 수단임을 인지한 상태의 판정이다.
```

## 자율 결정 원칙 (핵심)

```yaml
자율_결정 (질문 금지 — 스스로 최선을 선택하고 진행):
  - 구현 접근법 선택, 아키텍처·설계 트레이드오프
  - tier 판단, 우선순위, 작업 순서
  - 라이브러리·패턴·네이밍 선택
  - 계획 해석이 모호할 때의 합리적 해석 채택
  - 테스트 FAIL 원인 판단 및 수정 방향
  - 역라우팅 에스컬레이션 (5회+·8~20회) 및 커밋 실패 대응
  원칙: 근거를 남기고 최선안을 택한다. 확신이 없으면 advisor()를 호출하되 사용자에게 묻지 않는다.

자율_결정_예외 (재량 밖 — 반드시 지킬 것):
  - "완주 범위에서 항목을 빼는 결정"은 자율 결정 대상이 아니다.
    작업 순서는 재량이지만 작업 목록의 축소는 재량이 아니다.
    범위 축소는 goal.json 최초 생성 시 status:"blocked" 등록으로만 가능하다.
  - 반대로 범위 확장(새로 찾은 결함·필요 기능 추가)은 자율 결정 대상이다.
    "자율 발견 처리" 절의 덧붙이기(goal_append)로 이번 사이클에 처리한다.
  - 근거: 2026-08-24 실측 이탈. 활성화 항목이 타 세션 재시작을 요구해 불가였는데,
    그것과 독립적인 선행 항목(골든 실측·필터 규칙 작성)까지 묶어서 미뤘다.
    "우선순위, 작업 순서"가 재량으로 열려 있어 범위 축소가 허용되는 것처럼 읽혔다.
    금지 조항 부재가 아니라 허용 조항의 과대 해석이 원인이었다.

질문_허용 (에이전트가 원출 불가능한 외부 사실만):
  - 자격증명·토큰·비밀번호
  - 미공개 URL·엔드포인트·사내 전용 주소
  - 사용자만 아는 값 (계정명, 대상 서버, 업무 규칙 등)
  - 실행 결과를 에이전트가 판정할 수 없는 경우 (예: 물리 장비 상태)
  판정_기준: "탐색·검색·실행으로 알아낼 수 있는가?" → 알아낼 수 있으면 질문 금지, 스스로 확인하라.

절대_금지:
  - 선택지를 나열하고 사용자에게 고르라고 요구하는 행위
  - "진행할까요?" 류의 승인 요청
  - 안전 에스컬레이션 지점에서 멈추고 대기하는 행위 (자율 판단으로 진행)
```

## 안전망 (자율모드에서도 유지)

```yaml
유지_항목 (자율모드가 해제하지 않는다):
  - EARLY_TERM: 역라우팅 20회 초과 시 강제 중단 (ok_pipeline 정책)
  - status=ABORT|PAUSE: 감지 시 즉시 중단 (사용자 긴급 제동 수단)
  - goal.json locked: write_guard.sh 물리 보호 그대로 적용
  - 모든 hook 차단 (write_guard/team_create_guard 등): 우회 금지
근거: 자율성은 "묻지 않는 것"이지 "안전장치를 끄는 것"이 아니다.

max_iterations_도달_시_처리 (자율 원칙과 일치):
  oroof_active.max_iterations(5) 도달로 검증 루프가 끝나도 oto는 사용자에게 묻지 않는다.
  open 항목에 fail이 남아 있으면 종료하지 않고 carryover 로 이월해 곧바로 다음 사이클을 착수한다
  ("잔업 이월과 자동 이어받기" 절 A1~A5).
  ⚠️ 체인 상한(cycle_cap)·진전 없음(no_progress)·EARLY_TERM 에 닿았을 때만 oto_incomplete.json 으로
     미완료를 보고하고 마무리한다("상한·EARLY_TERM 미완료 보고" 절). 유효한 carryover 도 oto_incomplete 도
     없으면 F-OTO-2가 IDLE 전이를 차단한다. max_iterations 도달은 "조용히 끝내도 된다"는 뜻이 아니라
     "이 사이클의 루프를 그만 돌고 이월한다"는 뜻이다.

사용자_제동_수단:
  - Ctrl+C: 즉시 중단
  - /oinit: 강제 정리 + IDLE 전이
  - status ABORT/PAUSE 설정
```

## 대리 답변 기록 (필수)

```yaml
목적: 자율 결정의 사후 검증 가능성 확보
시점: 팀에이전트 질의를 대리 답변하거나, 자율 결정으로 질문을 생략할 때마다
경로: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/auto_decisions.jsonl
      (evidence/ 하위가 아닌 세션 디렉토리 직속 — 아래 기록_명령 제약 참조)
형식 (1줄 1건, JSONL):
  {"ts":"{ISO8601}","from":"{에이전트명|main}","question":"{원 질문 요약}","answer":"{대리 답변}","reason":"{판단 근거}"}
기록_명령 (권장 — session_state의 append 사용, 경로·인용 문제 없음): |
  mcp__oio__session_state(
    uuid="${UUID}",
    key="auto_decisions.jsonl",
    value='{"ts":"...","from":"...","question":"...","answer":"...","reason":"..."}',
    append=true)
  # uuid만 넘기면 서버가 session-env 하위 경로를 스스로 해석한다 (CLAUDE_CONFIG_DIR 차이 무관).

⚠️_도구_제약 (실측 확인 — 위반 시 조용히 실패):
  - key는 반드시 평면 파일명. 하위 경로 금지.
    "evidence/auto_decisions.jsonl" → SESSION_STATE_ERROR (서버가 세션 디렉토리만 생성, 하위 디렉토리 미생성)
  - file_write에는 append 파라미터가 없다. 누적 기록에 사용 금지 (덮어써짐).
  - append=true는 정상 동작 확인 (2회 연속 append → 2줄 JSONL 파싱 성공).

⚠️_셸_변수_금지: |
  bash_exec로 기록할 경우 셸 변수(SD=... 등)에 의존하지 말 것.
  bash_exec는 명령을 /bin/sh로 실행하며 변수가 후속 구문까지 유지되지 않는 경우가 있다
  (실측: `SD="..."; mkdir -p "$SD/evidence"` → $SD가 빈 문자열로 전개되어 /evidence/ 생성 시도 실패).
  bash_exec를 쓴다면 경로를 변수 없이 전부 리터럴로 적어라.
최종_보고: |
  ofinish 직전에 누적 건수와 목록을 사용자에게 1회 요약 출력:
  "🤖 [자율 결정 N건] " + 각 건의 question → answer 1줄 요약
  이어서 "🔎 자율 발견 처리 N건" + 각 건 1줄 요약("자율 발견 처리" 절의 최종 보고 규칙)
  N = grep -c '"phase":"처리"' auto_decisions.jsonl
  파일 부재 시 "자율 결정 0건"·"자율 발견 처리 0건"으로 보고 (오류 아님)
  ※ 발견·판정·처리 3줄은 위 대리 답변 형식과 같은 파일에 쓴다. 집계는 "phase" 키로 구분한다.
```

## 팀에이전트 질의 대리 답변 절차

```yaml
트리거: 팀에이전트가 SendMessage(to:"team-lead")로 질의·승인요청을 보냄
절차:
  1. 질의 내용이 "자율_결정" 범주인지 "질문_허용" 범주인지 판정
  2. 자율_결정 범주 → 메인이 즉시 최선안을 판단하여 SendMessage로 회신
     - 회신 전 auto_decisions.jsonl에 기록
     - 판단이 어려우면 advisor() 호출 (사용자 질문 아님)
  3. 질문_허용 범주 (외부 사실) → 이때만 AskUserQuestion으로 사용자에게 질의
     - 사용자 답변을 받아 팀에이전트에 SendMessage로 전달
  4. 어떤 경우에도 팀에이전트를 무응답으로 방치하지 않는다 (교착 방지)
금지: 팀에이전트 질의를 사용자에게 그대로 전달(pass-through)하는 행위 — 대리 판단이 원칙
```

## ofinish 연동

```yaml
autoloop: |
  auto=ON 세션의 next_action.json(blocked_only 또는 carryover)은 ofinish 가 소비하지 않는다.
  carryover 는 다음 /oto 진입부(0_잔업_이어받기 B1)가 소비한다.
  open 잔여 FAIL·판정불가는 oto 검증 루프에서 처리하고, 남으면 carryover 로 이월하며,
  상한에 닿았을 때만 oto_incomplete.json 으로 보고한다("잔업 이월과 자동 이어받기" 절).
  next_action 을 쓸 때 slash_command는 반드시 "/oto"를 쓴다 (whitelist 등재 완료).
  ⚠️ /ok 등으로 대체 금지: auto 플래그가 정리되어 다음 사이클이 일반 모드로 강등된다.
  ⚠️ blocked_only 인계만 남은 경우(open 잔여 fail 0건) autoloop을 발동시키지 않는다
     ("완주 불가 항목 처리" 절의 무한 autoloop 방지 분기).
     환경이 그대로면 자동 재시도해도 결과가 같으므로 사용자 조치가 선행되어야 한다.
  ⚠️ phase_batches.json 기반 다단계 자동 진행(Step 3)은 같은 사이클 안의 실행이므로 그대로 쓴다.
플래그_정리: |
  ofinish Step 8 "일반_종료 4."가 담당한다. 단 oto 는 ROOF 활성이라 Step 8 이 조기 return 하므로
  auto 보존·삭제의 실효 주체는 oto Phase 2 다(검증 루프 2번의 M4 순서 ④).
  - autoloop·carryover 이월 시: auto 플래그 보존 → 다음 사이클도 자율모드 유지(미소비 carryover 가 있으면 삭제 금지)
  - 최종 종료(잔업 0) 시:     auto 플래그 삭제 → 다음 파이프라인 자율모드 누출 방지
  양방향 누출(조기 삭제 / 미삭제)을 모두 막는 것이 목적이다.
```

## goal.json auto_script 작성 규칙 (사이클51-B/51-C 실사고 재발방지)

```yaml
핵심_원칙: |
  게이트는 "통과시켜야 할 것을 통과시키는가"뿐 아니라
  "통과시키면 안 될 것을 막는가"를 양방향으로 검증해야 한다.
  한쪽만 검증하면 게이트가 무의미해진다.

금지_패턴 (실사고 2건 — 둘 다 실제로 발생):
  - 사이클51 C6: `test -z "$(git log origin/master..HEAD --oneline)"`
    커밋 여부를 못 봐서 미커밋 상태에서도 rc=0. otest가 잡지 않았으면
    push 없이 완주 판정될 뻔했다.
  - 사이클51-C D7: L-483 교훈을 반영해 만든 계약인데 똑같이 계약 생성 시점 rc=0
    (oplan 실측). 문서 교훈이 다음 사이클을 못 지킨다는 실증이다.

필수_자가검사: |
  계약을 lock 하기 전에 각 auto_script를 지금 실행해보라.
  depends_on이 있는 항목이 지금 rc=0이면 그 게이트는 무의미하다 — 반드시 고쳐라.

올바른_예시: |
  커밋+push 판정은 `git status --porcelain -- <파일들>`이 빈 문자열 AND
  `git log origin/master..HEAD`가 빈 문자열, 양쪽 동시 확인.
  ⚠️ 단 이 조합도 "대상 파일이 애초에 clean이면" 통과하므로,
  변경 예정 파일을 명시해야 한다.

물리_강제_연결: |
  PreToolUse_goal_autoscript_guard.sh(F-GOAL-2)가 depends_on 보유 항목의
  계약 시점 rc=0을 물리 차단한다. 본 규칙은 그 hook과 짝을 이룬다.
```

### auto_script 중복 금지 (사이클51-D 실사고 재발방지)

```yaml
원칙: |
  서로 다른 acceptance 항목이 같은 auto_script 를 가지면,
  후행 항목의 검증력은 정의상 0 이다. 선행이 통과하면 후행도 자동 통과하기 때문이다.

실사고 (D1/D6): |
  D1  depends_on=[]      auto_script="cd ${HARNESS_HOME:-$HOME/.harness}/current && test -f LESSONS.md"
  D6  depends_on=["D1"]  auto_script="cd ${HARNESS_HOME:-$HOME/.harness}/current && test -f LESSONS.md"   ← 글자까지 동일
  D6 는 D1 과 검증 내용이 완전히 동일해서, D1 이 통과하면 자동 통과한다. 검증력이 0 이다.

depends_on_무관: |
  D6 가 잡힌 것은 depends_on=["D1"] 을 우연히 적었기 때문이다. 비웠다면 통과했다.
  즉 auto_script 중복 여부는 depends_on 유무와 무관하게 그 자체로 판정 가능한 구조적 결함이다.

물리_강제_연결: |
  PreToolUse_goal_autoscript_guard.sh 의 F-GOALAS-3 가 이 중복을 검출한다.

작성_지침: |
  각 항목의 auto_script 는 그 항목이 실제로 만들어낼 산출물을 검사해야 한다.
  예 — 문서 항목이면 `grep -q '이번에 추가할 문자열' <대상파일>`.
```

### (a) DONE 이후 단계를 DONE 진입 조건에 넣지 마라 (사이클123-E12 실사고)

```yaml
실사고: |
  사이클123 E12 의 auto_script 가 "커밋 완료" 를 요구했다.
  그런데 커밋은 state=DONE 이후의 odone 단계 산출물이다.
  ⇒ done_gate 는 E12 미충족을 이유로 DONE 진입을 막고,
    F-COMMIT-1 은 DONE 이 아니라는 이유로 커밋을 막았다.
  ⇒ 서로가 서로의 선행조건이 되는 순환 교착이 됐다.
  결국 hooks/DISABLE_DONE_GATE 우회로만 풀렸다 — 게이트가 제 역할을 못 하고 꺼진 것이다.

원칙: |
  acceptance 는 그 단계에서 산출 가능한 것만 검사하라.
  커밋·push·배포처럼 후행 단계의 산출물은 게이트 조건이 될 수 없다.

판별_질문: |
  "이 auto_script 가 검사하는 산출물은 어느 state 에서 만들어지는가?"
  그 state 가 게이트가 지키는 state 보다 뒤라면 그 조건은 잘못된 것이다.
```

### (b) auto_script 재귀 grep 에 --include/--exclude-dir 필수 (사이클123-E5 실사고)

```yaml
실사고: |
  `grep -rq '태그' MarsServer/` 가 timeout 5 를 넘겨 rc=124 간헐 오보를 냈다.
  MarsServer/ 는 실파일 40개인데 bin/obj 때문에 1,184개를 훑는다 (29배).
  단독 실행 3.3초, 부하 시 4.4초로 5초 벽에 붙어 있었다.

실측_증거 (done_gate.log): |
  10:26:14  fail=3  ids=E5,E10,E12   (전체 9초)
  10:31:33  fail=1  ids=E12          (6초, E5 소멸)
  ⇒ 파일은 하나도 변하지 않았는데 부하만으로 판정이 뒤집혔다.
    게이트가 파일이 아니라 그 순간의 서버 부하를 측정하고 있었던 셈이다.

필수: |
  --include=*.cs --exclude-dir=bin --exclude-dir=obj
  사이클124 실측 개선: 4,400ms → 713ms

원칙: |
  재귀 grep 은 대상 집합을 명시적으로 좁혀라.
  타임아웃에 걸리는 게이트는 "실패"가 아니라 "무작위"다 — 거짓 음성과 거짓 양성을 동시에 만든다.
```

### (c) lock 전 각 auto_script 를 실제 실행해 자가검사하라

```yaml
절차: |
  계약을 locked=true 로 고정하기 전에 모든 auto_script 를 공용 CLI 한 줄로 실행하고 rc 를 확인한다.
    bash "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/goal_autoscript_run.sh" --goal <goal.json>
  rc 가 0 이 아니면 전부 미통과다 (1=FAIL, 3=UNDET, 127=lib 부재 포함).
  전 항목이 blocked 라 open 0건이면 rc=0 (ALLBLOCKED) — blocked 근거 검증은 F-OTO-3/4/6 소관이다.

점검_항목:
  - depends_on 보유 항목이 지금 rc=0 이면 그 게이트는 검증력이 0 이다.
    선행 작업이 하나도 없는 상태에서 통과한다는 뜻이기 때문이다.
  - 재귀 grep 은 rc 뿐 아니라 실행 시간도 함께 측정한다 (규칙 b).
    5초 벽에 근접하면 --include/--exclude-dir 로 대상을 좁힌 뒤 재측정한다.

효과_실측: |
  사이클124 — 이 자가검사가 계약 작성 시점에 F2 의 rc=124 를 즉시 잡아냈다.
  사이클123 — 이 검사를 건너뛰어, 작업을 다 끝낸 뒤에야 유령 실패를 만났다.
  ⇒ 같은 결함이 어디서 발견되느냐의 차이가 곧 비용의 차이다.
```

### (d) 세션 경로는 $GOAL_SESSION_DIR 로 (사이클167 실사고 — C1~C18 거짓 FAIL)

```yaml
규칙: |
  auto_script 에 세션 절대경로(/tmp/cc-.../session-env/<UUID>/...)를 박지 않는다.
  `~`·`$HOME`·`${HOME}` 로 시작하는 형태도 금지다. 아래 폴백형으로 쓴다.
    ${GOAL_SESSION_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/<UUID>}/<파일>
  예: python3 "${GOAL_SESSION_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/<UUID>}/cNNN_gate.py" item <ID>
이유: |
  세션 재시작으로 CLAUDE_CONFIG_DIR 이 바뀌면 박아 둔 경로는 대상을 잃어 판정이 전부 거짓 FAIL 이 된다.
물리강제: |
  PreToolUse_goal_autoscript_guard.sh 의 F-GOALAS-4 가 위반 계약의 기록을 차단한다 (locked 무관).
  모든 실행부(ofinish Step 3.5-0·otest_verify·oto 직접 실행)는 공용 CLI 를 거쳐
  GOAL_SESSION_DIR·GOAL_UUID 를 넘긴다.
oto_직접_실행 (D9): |
  oto 가 auto_script 를 직접 돌릴 때도 공용 CLI 를 쓰고 rc≠0 은 전부 미통과로 본다.
  판정불가(UNDET)도 FAIL 과 똑같이 미통과이며 잔여로 센다(carry_ids 에 포함해야 이월 통과).
  같은 사이클에서 판정 스크립트·lib 를 복원해 루프를 다시 돌고, 그래도 남으면 carryover 로 이월한다.
  체인 상한·진전 없음·EARLY_TERM 에 닿으면 oto_incomplete.json 의 fail_ids 에 넣고, detail 에 FAIL 과 구분해
  "판정불가" 로 표기한다.
```

## 팀에이전트 생존 확인 (좀비 방지) — 프로세스 종료의 증거가 아니다

```yaml
원칙: |
  "Request timed out" / "API Error: No response from API" / "idleReason: failed"는
  응답 실패일 뿐 프로세스 종료의 증거가 아니다.

실사고 (사이클51-B): |
  진단 에이전트 3기가 API 타임아웃 후에도 3시간 이상 프로세스로 생존했고
  메인이 죽은 줄 알고 방치했다.
    oto-diag@session-7d78010c   03:54:46
    diag-gate@session-7d78010c  02:52:32
    diag-askq@session-7d78010c  02:49:53
  전부 --parent-session-id 0cc8bf60-... = 메인 소유였다.

확인_절차 (필수): |
  ps -eo pid,args | grep -- "--agent-id" | grep "<자기 UUID>"
  → 자기 --parent-session-id 소유분만 정리 대상. 타 세션 소유는 절대 건드리지 않는다(세션 격리 §a).

⚠️_pane_id_경고: |
  agents/ 파일의 pane_id(%2, %3 등)는 재사용된다.
  직전 사이클에 잔류 agents/의 pane_id가 타 세션의 살아있는 pane 번호와 겹쳤다 —
  그대로 kill 했으면 남의 세션을 죽였다. 반드시 PID 대조로 소유를 확정하라.

kill_전_캡처_의무: |
  tmux capture-pane -p -S -3000 -t "$PANE_ID"로 스크롤백을 파일 저장한 뒤 kill하라.
  kill은 증거를 영구 소멸시킨다.

현재진행형_근거: |
  oplan 실측 시점에도 타 세션 소유 에이전트 4기가 39~56분 생존 중이었다. 이 패턴은 상시 발생한다.
```

## 사용 예시

- /oto 로그인 기능 추가해줘
- /oto 이 모듈 리팩토링하고 테스트까지 끝내줘
- /oto 빌드 깨진 거 원인 찾아서 고쳐줘

## 주의

- ok의 모든 나머지 규칙(팀에이전트 spawn 4대 파라미터, PIPELINE_UUID 첫줄, evidence, ofinish 등) 동일 적용.
- oroof와의 차이: oroof는 "검증 기준 미달 시 반복 재실행"(루프), oto는 "질문 없이 완주"(자율).
  이번 수정으로 oto는 반복 검증 루프를 자체 흡수했다. oto는 Skill('oroof')를 호출하지 않고
  oroof Phase 0/Phase 2와 동일한 알고리즘을 메인이 직접 인라인으로 수행한다
  (팀에이전트 spawn 없음 — "메인이 전부 대리 판단"하는 oto 자율성 설계와 완전히 일치).
  ROOF status 토큰은 재사용하며 oroof/goal/ok/ok_pipeline/ofinish/state_machine.sh는 전부 무수정이다.
- goal.json: oto는 lock_request=true로 locked=true 계약을 직접 생성한다(1_5_목표계약_세팅).
  write_guard.sh F-GOAL-1(물리 보호) + ofinish Step 3.5-0(autoloop 게이트)
  + 검증 루프 Step 1.5(acceptance 전수 병합) + PreToolUse_oto_completion_guard.sh(F-OTO-1~9)가
  전부 실제 작동한다.
  ⚠️ acceptance 항목에 auto_script가 없으면 게이트가 "실행 항목 0개"로 조용히 통과되어
     no-op이 된다. blocked/blocked_by를 제외한 전 항목에 auto_script를 반드시 넣을 것.
  ⚠️ depends_on 허위 기입은 hook이 판정할 수 없다(그래프 정합성만 검사). §3.2 판정 질문을
     실제로 실행해 확인하라 — "X 없이 지금 auto_script를 실행하면 FAIL하는가".
- auto 플래그는 세션 격리 원칙에 따라 자기 UUID 하위에만 기록한다. 타 세션 무영향.
