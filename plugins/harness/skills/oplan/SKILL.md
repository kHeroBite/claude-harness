---
name: oplan
description: "계획 프레임워크 — Phase A~J 정의 + 공통 출력 규격의 공용 라이브러리. 실제 실행은 파생 스킬(oplan_simple/oplan_normal/oplan_deep/oplan_debate)이 담당. /oplan 직접 호출 시 계획 단독 파이프라인 실행."
invocation:
  user_callable: true
  pipeline_callable: true
  called_by: ["ok_pipeline(파생스킬 경유)", "사용자(/oplan)"]
  calls: []
---
# oplan — 계획 프레임워크

## ogrill 5축 결손 판정 (oplan 내부 절차 — 절대 규칙)

> oplan 팀에이전트는 Phase A(의도 분석) 진입 직전 5축(목표/범위/제약/완료기준/열린질문) 결손 카운트를 수행한다.
> 메인 에이전트는 이 판정을 수행하지 않는다 (CLAUDE.md "ogrill 호출 정책" 참조).

```yaml
판정_절차:
  시점: Phase A 진입 직전 (oplan 팀에이전트 내부)
  카운트: 사용자 원본 요청 + 메인이 전달한 컨텍스트에서 5축 빈 칸 카운트
    1. 목표 (무엇을 만들/고치는가)
    2. 범위 (어디까지 손대는가)
    3. 제약 (피해야 하는 것)
    4. 완료기준 (어떻게 검증)
    5. 열린질문 (현재 불명확한 결정)

판정_분기:
  빈_칸_≥_4: Skill('ogrill') 직접 호출 (필수 — 5축 명확화 없이 진행 시 잘못된 계획 위험)
  빈_칸_==_3: Skill('ogrill') 호출 권장 — 단, 메인이 forced_tier 또는 명시 결정 제공 시 스킵
  빈_칸_≤_2: 스킵 후 Phase A 진행

예외_스킵:
  - forced_tier 명시 (메인이 tier 강제 — 사용자 명시적 결정)
  - 사용자 "바로 진행" / "ogrill 건너뛰기" 명시
  - 이미 ogrill 결과가 spawn 프롬프트에 포함됨 (5축 확정 메시지)
  - tier ≤ o2 (소규모 작업)

ogrill_호출_방법:
  - Skill('ogrill')을 oplan 팀에이전트가 직접 로딩 (Claude Code 팀에이전트는 Skill 도구 사용 가능)
  - 호출 후 ogrill 인터뷰 결과를 spawn 프롬프트에 추가하여 메인에 보고 (선택)
  - 또는 AskUserQuestion으로 oplan이 직접 5축 명확화 진행

위반_감지: 메인이 ogrill을 자율 호출 시도 → PreToolUse_Skill_ogrill_main_guard.sh hook이 block 반환
```

## 절대규칙

```yaml
shutdown_즉답_절대규칙 (L-U5):
  - shutdown_request 수신 즉시 현재 작업 중단 후 shutdown_response 발송
  - 파일 저장/정리 등 후처리 후 응답하는 행위 절대 금지
  - 메인이 3회×5s=15초 내에 응답 없으면 pane 강제 종료 대상
```

> oplan은 **Phase A~J 정의 + 공통 출력 규격**을 제공하는 공용 라이브러리 역할을 한다.
> 실제 실행은 tier별 파생 스킬이 담당:
>   - **o2**: Skill('oplan_simple') — Phase A,B,G만 실행
>   - **o3**: Skill('oplan_normal') — Phase A~J 전체, Quick/Deep 자율
>   - **o4/o5**: Skill('oplan_deep') / Skill('oplan_debate') — 심층 설계 + 토론
> **독립 분석 모드**: /oplan 직접 호출 시 계획 단독 파이프라인 실행 (파일 수정 금지).

## 실행 모드

```yaml
모드_1_파이프라인_내_spawn (v4.3 — ok 의도분석 + oplan 탐색 확정):
  트리거: ok가 /ok 호출 시 oplan을 팀에이전트로 직접 spawn
  2단계_구조:
    Stage_1 (tier 확정): ok의 hint_tier를 참조하되, Phase A+B 탐색 결과로 최종 확정
      - hint_tier와 탐색 결과 일치 → 즉시 확정
      - hint_tier와 탐색 결과 불일치 → 탐색 결과 우선 (보정)
      - hint_tier 없음 → 탐색 결과로 직접 결정
    Stage_2 (depth 전환): 확정된 tier에 맞는 파생 스킬 depth로 전환
      o2 → Skill('oplan_simple'): Phase A,B,G만 실행. 산출물 30~50줄
      o3 → Skill('oplan_normal'): Phase A~J 전체. Quick/Deep 자율
      o4 → 자율선택: oplan_consult(기술 트레이드오프) / oplan_debate(아키변경 500줄+) / oplan_deep(기본값, Scout×1~3 + 대안 + YAGNI)
      o5 → 자율선택: oplan_debate(기본값, 4단계 토론) / oplan_consult(알고리즘/기술 선택 중심)
  forced_tier: ok가 forced_tier=o{N} 전달 시 Stage_1 스킵 → 즉시 해당 depth로 Stage_2 실행
  hint_tier: ok가 hint_tier=o{N} 전달 시 Stage_1에서 참조하되 탐색 결과로 보정 가능
  역할: 코드 탐색 + tier 확정 + 설계 + 파일 할당 매트릭스 출력 → ok에 반환
  반환: tier + 계획서 + 파일할당매트릭스 → ok가 배너 출력 후 ok_pipeline(odev부터) 호출

모드_2_계획_단독 (/oplan 직접 호출):
  트리거: 사용자가 /oplan 직접 호출 (ok 미경유)
  판단_기준: system-reminder에 `💬 [IDLE 직접처리]` 또는 `⚡ [슬래시 명령] oi 바이패스 — /oplan` 컨텍스트
  동작: 팀에이전트 spawn (메인 컨텍스트 보호)
  절차:
    1. entry_tier=OK 기록 (IDLE 유지 — state 전이 절대 금지)
       mcp__oio__session_state(uuid="${UUID}", key="entry_tier", value="OK")
    2. TeamCreate
    3. Agent 팀에이전트 spawn:
       Agent(subagent_type="general-purpose", team_name="{팀명}", name="oplan-standalone",
             mode="bypassPermissions",
             prompt="Skill('oplan') 호출. 내부_호출=true (모드2 직접 실행). forced_tier 없음.
                     사용자 요구사항: {원문}. PIPELINE_UUID={UUID}")
    4. 완료 수신 → ofinish(경량 — TeamDelete + IDLE 복원)
  state_원칙: IDLE 유지 (state=PLAN 설정 절대 금지)
  역할: 분석/설계 결과만 사용자에게 전달 (파일 수정 없음)
  출력: 설계서/분석서 형식으로 사용자에게 직접 반환
  완료_흐름: 독립 분석 완료 후: 메인이 oplan 완료 수신 → ofinish 직접 실행 (팀 정리 + IDLE 전환). 별도 otest/odone 없음.

모드_3_계획_요청 (질문 분류에서 계획 필요 시):
  트리거: 메인이 분류에서 "계획" 판정
  역할: 모드_2와 동일 (분석/설계만, 파일 수정 없음)
  차이: 사용자가 /oplan을 명시하지 않았지만 계획 분류로 판정된 경우
  완료_흐름: 독립 분석 완료 후: 메인이 oplan 완료 수신 → ofinish 직접 실행 (팀 정리 + IDLE 전환). 별도 otest/odone 없음.
```

## oplan 진입 시 필수: UUID 결정

```yaml
UUID_결정:
  UUID=$PIPELINE_UUID
시점: oplan 팀에이전트 진입 직후, Phase A 수행 전
```

## 역할

```yaml
실행_방식:
  모드1_수정파이프라인: ok가 팀에이전트로 직접 spawn (v4.1 — ok_pipeline 미경유)
  모드2_독립분석: 메인이 팀에이전트로 직접 spawn (분석/계획 단독 요청, 파일 수정 금지)
입력: 사용자 요구사항 원문 + hint_tier(선택) + forced_tier(선택) + hint_plan(선택) (메인이 분석 없이 그대로 전달)
처리:
  Stage_1_tier_확정:
    forced_tier 있으면: 즉시 확정 (탐색 스킵)
    hint_tier 있으면: Phase A+B 탐색 후 hint_tier 검증 → 일치 시 확정, 불일치 시 탐색 결과 우선
    둘 다 없으면: Phase A+B 탐색 후 직접 결정
  Stage_2_depth_전환:
    hint_plan 있으면: tier 무관하게 hint_plan 지정 계획 스킬 강제 사용
      hint_plan=oplan_debate → Skill('oplan_debate') (tier o2~o5 모두) — fallback 절대 금지
      hint_plan=oplan_consult → Skill('oplan_consult') (tier o4~o5, o2~o3은 무시)
      hint_plan 실행 불가 시: 계획 수립 중단 → 메인에 "{hint_plan} 실행 불가: {사유}" 보고 (정상 depth로 대체 금지)
    hint_plan 없으면: 확정된 tier에 맞는 파생 스킬 로딩
    o2 → Skill('oplan_simple'): Phase A,B,G만
    o3 → Skill('oplan_normal'): Phase A~J, Quick/Deep 자율
    o4 → 자율선택: oplan_consult(기술 트레이드오프) / oplan_debate(아키변경 500줄+) / oplan_deep(기본값)
    o5 → 자율선택: oplan_debate(기본값) / oplan_consult(알고리즘/기술 선택 중심)
출력:
  - tier (O2|O3|O4|O5), 에이전트 수, 파일 할당 매트릭스 JSON
  - 수정 대상 파일 목록 (정확한 경로), 단위작업 목록
  - TODO 파일 (oplan이 직접 생성)
반환: ok에 tier + 출력물 반환 (scratchpad 파일 + 요약 메시지)
```

## Phase A~D: 의도파악

```yaml
Phase_A_페르소나_설정:
  매핑:
    UI/폼/레이아웃/컨트롤/Designer: impl-form
    API/서비스/쿼리/DB/쿼리문자열: impl-backend
    코드탐색/파일분석/구조파악/설계: scout
    버그분석/원인추적/검증/디버깅: analyst
    코드리뷰/품질검증/일관성/정리: reviewer
    복합작업: 담당 파일별 페르소나 개별 지정
  적용: TODO 헤더에 "페르소나: {역할}" 명시 + odev 프롬프트 첫 줄에 주입

Phase_B_의도_분석:
  추출: 표면_요청(what), 실제_목적(why), 성공_기준(done), 제약_조건
  출력: "목적: {1줄} / 완료기준: {측정가능} / 제약: {변경금지}"

Phase_C_스킬_매칭:
  매핑표:
    차트|그래프|시각화: → oskill_livecharts2
    폼|화면|UI|레이아웃: → domain-winforms
    DB|테이블|스키마: → domain-database
    리팩토링|코드품질|성능: → domain-csharp
    라이브러리|NuGet|패키지: → domain-context7
    버그|오류|예외|디버깅: → odebug
    영향도|인터페이스변경: → odev_impact
  적용: TODO 헤더 "활용 가능 스킬" 목록에 명시

Phase_D_스마트_질문:
  트리거: 추론 불가 항목 1개+ AND 영향도 높음 (o2/o3 전용)
  도구: Askuserquestion (1회, 최대 4개, 선택지 방식)
  스킵: 모든 항목 추론 가능하면 질문 없이 진행
  금지: 2회 이상 질문
  o4_o5_대체: o4/o5에서는 이 Phase_D 스마트 질문 대신 아래 Phase_D_o4_o5_분류_확장(가정 확인)을 수행한다. 둘을 동시에 수행하지 않음.

Phase_D_o4_o5_분류_확장:
  트리거: 분류 == o4/o5 (Phase_B 의도 분석 후 잠정 판정 시)
  동작:
    1. Phase_B 의도 분석 결과에서 가정 목록 자동 생성 (최대 5개)
       가정_유형:
         - 기존 코드와의 하위 호환성 방향
         - 수정 범위 (특정 모듈만 vs 전체)
         - 데이터 마이그레이션 필요 여부
         - 성능/보안 요구 수준
         - 기술적 접근법 선택 (A vs B)
       형식: "[가정 N]: {구체적 서술} (근거: {Phase_B 추론 근거})"
    2. Askuserquestion으로 가정 확인 (1회)
       질문_형식: "다음 가정으로 진행합니다. 수정이 필요하면 알려주세요:\n{가정 목록}"
    3. 사용자 응답 반영 → Phase_E 진입
       수정_있음: 가정 목록 업데이트 → Phase_E에 반영
       수정_없음: 가정대로 Phase_E 진입
  스킵_조건:
    - 분류 != o4/o5 (o2/o3은 기존 스마트 질문 방식 유지)
    - 모든 가정이 요구사항에서 명시된 경우 (질문 없이 진행)
  제한: Askuserquestion 총 1회 — o4/o5에서는 가정 확인이 이 1회를 사용하며, 일반 스마트 질문(Phase_D)은 수행하지 않음
  금지: 5초 타임아웃 자동 진행 (Askuserquestion 기본 대기 사용)
```

## 외부 검색 적극 활용 (oplan 필수 원칙)

> **신뢰성 우선**: 불확실한 정보를 추정으로 채우는 것보다 검색으로 확인하는 것이 항상 낫다.

```yaml
외부검색_의무_트리거 (하나라도 해당 시 WebSearch/WebFetch 실행 필수):
  - 라이브러리/프레임워크 버전 또는 API 사용법이 불확실할 때
  - Breaking Change 가능성이 있는 업데이트/마이그레이션 작업
  - 알려진 버그/이슈가 있을 수 있는 기술 스택
  - 최신 베스트 프랙티스가 필요한 설계 결정
  - 공식 문서 확인 없이 단정할 수 없는 동작 방식

외부검색_일반_권장 (불확실하면 먼저 검색):
  - context7 MCP 먼저 시도 → 없거나 부족하면 WebSearch 보완
  - 검색 결과는 출처(URL)와 함께 계획서에 명시
  - "아마도", "보통은" 등의 추정으로 계획을 채우는 행위 금지

외부검색_결과_기록_규칙:
  - TODO 파일 "참조 자료" 섹션에 검색 출처 URL 반드시 포함
  - 검색 결과가 없거나 불확실하면 "미확인" 명시 후 대안 제시
  - 검색으로 확인된 정보와 추정 정보를 명확히 구분 표기

도구_우선순위:
  1. mcp__context7__* (라이브러리 공식 문서)
  2. WebSearch (최신 정보, 이슈, 버전)
  3. WebFetch (상세 페이지, 공식 릴리즈 노트)
```

## 프로젝트 문서 사전 참조

> 프로젝트 문서 사전 참조: Grep→히트 섹션만 Read, 전체 Read 금지

## Phase E~J: 세분화 + 규모판정 + 파일할당

> **참조**: 규모 판정 기준은 ok SKILL.md "분류_판정_알고리즘" (7-way, o1~o5), 에이전트 수/파일 할당은 oplan_parallel가 단일 출처.

```yaml
Phase_E_세분화:
  6하원칙: 누가(에이전트), 무엇을(파일/클래스/메서드), 어디서(경로+줄번호),
           언제(의존관계), 왜(목적 연결), 어떻게(참조 패턴)
  암묵적_가정_명시화: "~처럼"→정확한 경로, "적당히"→구체적 수치

Phase_F_엣지케이스:
  나열: null/빈값, 예외 발생 시 처리, 경계값, 하위 호환성

Phase_G_TODO_생성:
  파일명: TODO_YYYYMMDDhhmmss.md
  필수_섹션: 페르소나, 목적, 완료기준, 제약, 활용스킬, 체크리스트, 엣지케이스
  체크리스트: 2-5분 단위 Bite-sized Task
  프롬프트_확장: 간소화 금지, 디테일 최대화

Phase_G_TODO_생성_XML_블록:
  적용: o3~o5만 (o1/o2는 기존 Markdown 체크리스트 유지)
  방식: 기존 Markdown TODO 유지 + XML 구조 블록 병행 (기존 하위 호환 보장)
  위치: TODO_*.md 파일 말미에 XML 코드블록으로 추가

  XML_블록_스키마:
    ```xml
    <tasks>
      <task name="{작업명}" agent="{odev-N}">
        <files>
          <file path="{정확한 파일 경로}" action="{modify|create|delete}" scope="{클래스.메서드 또는 섹션명}"/>
        </files>
        <verify>
          <build>{true|false}</build>
          <test>{테스트 방법 서술}</test>
          <visual>{UI 검증 방법 서술 (선택)}</visual>
        </verify>
        <done_criteria>{완료 기준}</done_criteria>
        <dependencies>
          <dep>{선행 작업명}</dep>
        </dependencies>
      </task>
    </tasks>
    ```

  작성_규칙:
    - path: 절대 경로 (예: /mnt/c/work/MyApp/.claude/skills/ok_pipeline/SKILL.md)
    - action: modify(수정)/create(신규)/delete(삭제)
    - scope: 수정 범위 최소화 기재 (예: "Wave_동적_spawn 섹션")
    - dependencies: 선행 작업명 없으면 빈 태그 (<dependencies/>)
    - build: 코드 파일(.cs 등) 변경 시 true, 비코드 파일만 변경 시 false

  파싱_실패_시: 기존 Markdown 체크리스트로 폴백 (XML 블록 무시)
  점진_전환: XML 블록이 안정화되면 향후 Markdown 체크리스트 제거 검토 가능

Phase_H_규모_판정 (v4.1 — oplan이 단일 출처):
  시점: Phase A+B 완료 직후 (Stage_1 tier 결정)
  기준 (순차 평가 — 상위 우선):
    o5_조건 (OR): 1500줄+ | 새 모듈 3개+ | 아키 전면 변경
    o4_조건 (OR): 500줄+ | 아키 변경
    o3_조건 (OR): 코드 4개+ | 50~500줄 | DB변경 | 인터페이스변경 | 비즈니스로직
    o2_기본: 위 모두 미해당 (코드 1~3개, 20~50줄, DB/IF 없음)
  forced_tier: ok가 forced_tier 전달 시 이 판정 스킵
  출력: O2 | O3 | O4 | O5  # (L-394: 대문자 통일 — classification 파일 저장 표준과 일치)
  기록: mcp__oio__session_state(uuid="${UUID}", key="classification", value="O{N}")
  전환: 판정 결과에 따라 해당 파생 스킬 Skill() 호출 (Stage_2)

Phase_I_에이전트_수_결정:
  기준: Skill('oplan_parallel') — 에이전트 수 공식/파일 할당/Phase 구조의 단일 출처
  공식: 파일 1~4개=1:1, 파일 5개+=max(4,ceil(파일수/3))
  출력: phases 배열 (에이전트별 파일/작업/페르소나/순서)

Phase_J_파일_할당_매트릭스:
  기준: oplan_parallel 출력 phases 배열 사용
  영속화: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/file_assignment.json (매트릭스 확정 직후)

file_assignment_버전_관리:
  초기_생성: file_assignment.json (v1)
  역라우팅_시: cp file_assignment.json file_assignment_v${reroute_count}.json
  목적: 이전 할당과의 차이 추적, 역라우팅 원인 분석
  odev_재spawn_시: 최신 file_assignment.json 참조 (이전 버전은 감사용)
```

## tier 결정 책임 (v4.1 — M-02 대체)

```yaml
oplan이 tier 확정의 단일 출처 (v4.3):
  forced_tier 있음: ok가 /o2~/o5 단축키로 tier 강제 → oplan은 tier 결정 스킵, 해당 depth로 즉시 실행
  hint_tier 있음: ok 의도분석 초벌 판정 → oplan이 Phase A+B 탐색 후 검증/보정하여 최종 확정
  둘 다 없음: oplan이 Phase A+B 탐색 후 Phase_H에서 tier 직접 결정
  o1: oplan 미경유 (ok가 /o1 명시 호출 → odev 직접 spawn)

tier별_depth_전환:
  hint_plan 있으면: tier 무관하게 hint_plan 지정 계획 스킬 강제 사용
    hint_plan=oplan_debate → Skill('oplan_debate') (o2~o5 모두) — fallback 절대 금지
    hint_plan=oplan_consult → Skill('oplan_consult') (o4~o5만, o2~o3은 무시 후 정상 depth)
    hint_plan 실행 불가 시: 계획 수립 중단 → 메인에 "{hint_plan} 실행 불가: {사유}" 보고 (정상 depth로 대체 금지)
  hint_plan 없으면: tier에 맞는 정상 depth
  o2 → Skill('oplan_simple'): Phase A,B,G만 (산출물 30~50줄)
  o3 → Skill('oplan_normal'): Quick/Deep 자율 판정
  o4 → 자율선택: oplan_consult(기술 트레이드오프) / oplan_debate(아키변경 500줄+) / oplan_deep(기본값)
  o5 → 자율선택: oplan_debate(기본값) / oplan_consult(알고리즘/기술 선택 중심)
```

## 파생 스킬 참조 (Phase 라이브러리 역할)

> oplan은 Phase A~J 정의와 출력물 규격의 공용 라이브러리.
> 실제 실행은 아래 파생 스킬이 담당하며, 각 스킬이 필요한 Phase를 선택적으로 참조한다.

```yaml
파생_스킬_매핑:
  oplan_simple (o2):
    Phase: A(의도) + B(탐색) + G(TODO)
    산출물: 30~50줄 간소화 계획
    서브에이전트: 없음

  oplan_normal (o3):
    Phase: A~J 전체
    Quick/Deep: oplan_normal 내부에서 자율 판정
    Quick: 직접 탐색 + 간소화 TODO
    Deep: Skill('oplan_deep') + oplan_deep/references/SIM_PROCEDURE.md + Skill('oplan_review')

  oplan_deep (o4~o5):
    Phase: A~J 전체 + Scout×1~3 + 대안탐색 + YAGNI
    서브에이전트: Scout(haiku), oplan_deep/SIM_PROCEDURE.md(sonnet), oplan_review(opus)

  oplan_debate (o4선택/o5필수):
    Phase: 독립분석×2 → debate → vote → final merge
    서브에이전트: oplan-1(opus), oplan-2(opus), oplan-final(opus)

  oplan_consult (o5 대안):
    Phase: Claude vs Codex 이종 AI 라운드 토론
```

## 출력물 규격 (메인 입력)

```yaml
출력_형식:
  규모_판정: o1 | o2 | o3 | o4 | o5
  에이전트_수: N
  파일_할당_매트릭스:
    agent_1: {files: ["file1.cs"], tasks: ["Task 1"]}
    agent_2: {files: ["file2.cs"], tasks: ["Task 2"]}
  수정_파일_목록:
    - {path: "exact/path/file.cs", 변경_요약: "XX 로직 추가", 변경_규모: small|medium|large}
  단위작업_목록:
    - {id: 1, 설명: "XX 수정", 파일: ["file1.cs"], 의존: []}
  메타데이터:
    {총_파일수: N, 총_작업수: N, 독립_작업수: N, 예상_복잡도: low|medium|high}
  독립_그룹: [["file1.cs"], ["file2.cs"]]
  페르소나_매핑: {agent_1: "impl-form", agent_2: "impl-backend"}
  TODO_파일_경로: "TODO_YYYYMMDDhhmmss.md"
```

## PRD 출력 모드 (선택적)

> 출처: to-PRD (mattpocock/skills, MIT) — 영감. 대화 맥락을 사용자 가독 PRD로 변환.

### 트리거 조건

```yaml
자동_트리거:
  - forced_tier=o4 또는 o5 (oplan_deep/oplan_consult/oplan_debate depth)
  - 사용자 명시: "PRD 작성", "기획서 작성", "요구사항 문서"
  - oplan 내부 판정: 새 모듈 신설 + 사용자 협의 필요

수동_트리거:
  - hint_plan 또는 prd_mode=true 플래그가 메인에서 전달된 경우

스킵_조건:
  - tier ≤ o3 AND 사용자 명시 PRD 요청 없음
  - 단순 버그 수정/리팩토링 (요구사항 문서 불필요)
```

### PRD 산출물 구조

```yaml
위치: docs/prd/{slug}.md (프로젝트 루트 기준 — 절대경로 우선)
slug_규칙: {기능명}-{날짜YYYY-MM-DD} (예: skills-import-2026-05-08)
형식: 마크다운, 한국어 (CLAUDE.md 언어 정책 준수)
독자: 사용자 — 기술 용어 최소화, user story 형식
```

### PRD 필수 섹션 (4개)

#### 1. 배경 / 동기 (Background)

- 왜 이 작업이 필요한가? (As-Is 문제점)
- 현재 상태 (As-Is)와 변경 후 상태 (To-Be)
- 사용자가 겪는 마찰 또는 비즈니스 동기

#### 2. User Story (As X, I want Y so that Z)

- 형식: "사용자(역할)로서, {원하는 것}을 {달성 목적}을 위해 원한다"
- 1~3개의 핵심 스토리만 (과도하게 X)
- 한국어 작성 (기술 용어는 영어 허용)

#### 3. 수락 기준 (Acceptance Criteria — Given-When-Then)

- 형식:
  ```
  Given {초기 상태}
  When {액션}
  Then {기대 결과}
  ```
- 검증 가능한 형태 (코드/UI/로그 확인 가능)
- 5~15개 항목 (너무 적거나 많지 않게)

#### 4. Out of Scope (제외 범위)

- 명시적으로 이번 작업에 포함 안 되는 것
- 향후 후속 작업 후보로 기록
- 모호함 제거 효과 (스코프 크립 사전 차단)

### PRD 형식 예시 (skills-import-2026-05-08.md 참조)

```markdown
# 외부 스킬 5건 한국어 도입 PRD

작성일: 2026-05-08
작성자: oplan 팀에이전트
관련 대화: conv_177824918766

## 1. 배경 / 동기

### As-Is
o시리즈 88개 스킬은 풍부하나, 사용자 인터뷰(grill-me/deep-interview)와 ...

### To-Be
- 신규: ogrill (인터뷰), oimprove (코드베이스 정리)
- 강화: odebug (6단계 진단), otest_evidence (TDD), oplan (PRD 출력)
- 자동: UserPromptSubmit.sh 키워드 → 권장 메시지

### 동기
사용자가 ... 외부 검증된 패턴을 한국어 환경에 ...

## 2. User Story

- **개발자(주 사용자)로서**, 모호한 작업 요청에 대해 ointaug 분석 후 ogrill로 5축 명확화 인터뷰를 받기를 원한다 — 잘못된 방향으로 가는 비용을 줄이기 위해
- **개발자로서**, 디버깅 작업 시 6단계 절차(재현→최소화→가설→측정→수정→회귀)를 강제받기를 원한다 — "수정만 하고 회귀 테스트 누락" 패턴을 방지하기 위해
- **개발자로서**, 코드베이스 부채를 주기적으로 청소하는 oimprove 스킬을 원한다 — AI 협업 품질을 유지하기 위해

## 3. 수락 기준 (Given-When-Then)

### 기능 1: ogrill 신규 스킬
- Given: ointaug 완료 + 5축 미충족
- When: 사용자가 /ogrill 호출
- Then: AskUserQuestion으로 4행 템플릿(현재이해/막힌결정/추천답안/질문)을 1회당 1개씩 출력하고, 사용자 응답 누적 후 5축 충족 시 종료 요약 출력

### 기능 2: oimprove 신규 스킬
- Given: 사용자가 코드베이스 부채 정리 요청
- When: /oimprove 호출
- Then: 8개 항목(얕은 모듈/중복/순환의존성 등) 스캔 + 후보 우선순위 출력, 직접 수정은 X (ok 파이프라인 위임)

(이하 must 18개 항목 모두 Given-When-Then 형식으로)

## 4. Out of Scope

- GitHub Issue 자동 등록 (단독 개발자 환경 — 가치 낮음)
- 자동 호출 강제화 (CLAUDE.md 재발방지 정책 위반 — LLM 의지 의존 X)
- 16~50개 질문 폭격형 grill-me 직접 이식 (한국어 환경에 과함)
- ralph-loop 직접 이식 (이미 oralph 보유)
```

### PRD 작성 vs 기존 oplan 산출물 비교

| 산출물 | 독자 | 형식 | 용도 |
|---|---|---|---|
| oplan_final.md (기존) | LLM/메인 | 기술 상세 | 파이프라인 입력 |
| **PRD (신규)** | **사용자** | **user story/G-W-T** | **사용자 승인/리뷰** |

### PRD 모드 활성화 절차

```yaml
활성화_절차:
  1. forced_tier=o4|o5 또는 prd_mode=true 감지
  2. oplan Phase A~G 정상 수행 (기존 절차 보존)
  3. Phase G 완료 후 PRD 변환:
     - 배경: oplan §1 (요구사항 분석) → 사용자 친화적 재작성
     - User Story: oplan §2 (목표) → As-Is/To-Be → As X, I want Y
     - 수락 기준: oplan acceptance_criteria.json → Given-When-Then 변환
     - Out of Scope: oplan §3 (범위 외) 명시
  4. docs/prd/{slug}.md 작성 (mcp__oio__file_write)
  5. 사용자에게 보고: "PRD 작성: docs/prd/{slug}.md, 검토 후 진행 여부 결정"

생성_도구:
  - mcp__oio__file_write (overwrite=false 원칙 — 기존 PRD 보호)
  - 동일 slug 기존 파일 존재 시: 사용자 확인 후 overwrite=true
```

### GitHub Issue 자동 등록 (선택)

```yaml
단독_개발자_환경 (현재 우리 프로젝트): 비활성 (가치 낮음)
팀_환경: gh issue create로 자동 등록 가능 (config 옵션)
적용_조건: prd_github_issue=true 플래그 + gh CLI 인증 완료 시
출처_원본: mattpocock/to-prd는 issue tracker 자동 등록 — 팀 워크플로우 전제
```

### 주의사항

```yaml
필수:
  - PRD는 사용자가 읽기 위한 것 — 기술 용어 최소화
  - 한국어 작성 필수 (CLAUDE.md 정책)
  - oplan_final.md와 PRD는 별도 산출물 (둘 다 작성)
  - PRD 4개 필수 섹션 모두 포함 (배경/User Story/수락기준 GWT/Out of scope)

권장:
  - 사용자 승인 없이 PRD만 작성하고 odev 진입 가능 (PRD는 참고용)
  - 사용자 명시 검토 요청 시 odev 진입 대기

금지:
  - 영어 단독 PRD 작성 (한국어 정책 위반)
  - PRD 4개 필수 섹션 중 누락 (사양서 불완전)
  - PRD를 oplan_final.md 대체용으로 사용 (둘은 독자/형식이 다름)
```

### 출처

```yaml
주요_영감: to-PRD (mattpocock/skills, MIT 라이선스)
형식_근거: Agile Methodology의 user story + acceptance criteria (Given-When-Then)
한국어_적용: CLAUDE.md 언어 정책 + 단독 개발자 환경 맥락
```

## Phase Batch 출력 규격 (Multi-Phase Auto-Loop용)

> ok_pipeline 4.5단계 Auto-Loop가 사용하는 batch 분할 스키마.
> phase_batches.json이 존재하면 ok_pipeline이 batch 단위로 odev→otest→odone 사이클을 자동 반복한다.

```yaml
Phase_Batch_출력_규격:
  생성_조건: oplan이 작업을 2개 이상의 독립 실행 사이클로 분할할 때
  적용_tier: o4/o5 tier에서만 생성 가능. o2/o3는 단일 사이클 강제.
  ⚠️ o3_경고: o3에서 phase_batches.json 생성 시도하면 ok_pipeline 6.5.0 tier 사전 체크에서 무시됨 (단일 사이클 진행)
  미생성_조건: 단일 사이클로 완료 가능한 작업 (기존 동작 유지)
  저장: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/plans/phase_batches.json

  스키마:
    주의: current_batch는 외부 파일(${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/current_phase_batch)에서
    단독 관리. json 내부에는 포함하지 않음 (이중 상태 저장소 방지).
    {
      "total_batches": 3,
      "batches": [
        {
          "batch_id": 1,
          "description": "Phase 1: 핵심 인프라 변경",
          "priority": "critical",
          "file_assignment": {
            "odev-1": {"files": ["path/a.cs"], "tasks": ["인터페이스 추가"]},
            "odev-2": {"files": ["path/b.cs"], "tasks": ["구현체 수정"]}
          },
          "todo_section": "## Phase 1 Tasks",
          "acceptance_criteria_ids": ["AC-001", "AC-002"],
          "depends_on_batch": null
        },
        {
          "batch_id": 2,
          "description": "Phase 2: 기능 구현",
          "priority": "high",
          "file_assignment": {
            "odev-1": {"files": ["path/c.cs"], "tasks": ["비즈니스 로직"]}
          },
          "todo_section": "## Phase 2 Tasks",
          "acceptance_criteria_ids": ["AC-003", "AC-004"],
          "depends_on_batch": 1
        }
      ]
    }

  batch_분할_기준:
    필수_분할 (OR):
      - 총 수정 파일 10개+ (단일 사이클 과부하)
      - 선행 batch 결과가 후행 batch 입력 (순차 의존성)
      - 아키텍처 계층 간 선후 관계 (DB 스키마 → 백엔드 → 프론트엔드)
    권장_분할 (OR):
      - 총 수정 줄 수 500줄+
      - 독립적 기능 그룹이 3개+
    분할_금지:
      - 총 파일 4개 이하 AND 총 줄 수 200줄 미만 (단일 사이클 충분)
      - 파일 간 순환 의존성 (분할 불가 → 단일 사이클)

  DAG_검증 (생성 직후 필수):
    depends_on_batch 필드는 DAG(유향 비순환 그래프) 구성 필수
    순환 참조 금지: batch A → B → C → A 같은 순환 참조 시 oplan 재작성
    전방 참조만 허용: batch N은 N-1 이하 batch에만 의존 가능
    검증 방법: 위상 정렬(topological sort) 가능해야 함
    위반_시: ok_pipeline 6.5단계에서 DAG 검증 실패 → oplan 재spawn

  batch별_file_assignment_규칙:
    - 각 batch의 file_assignment는 독립적 (batch 간 파일 중복 허용)
    - batch N+1은 batch N에서 수정된 파일을 재수정 가능 (incremental)
    - 각 batch는 자체 odev→otest→odone 사이클로 독립 검증 가능해야 함
    - 각 batch 완료 후 빌드 가능 상태(compilable) 보장 필수

  하위_호환:
    - phase_batches.json 미존재 → 기존 단일 사이클 동작 (변경 없음)
    - total_batches == 1 → 단일 사이클 (phase_batches.json 미생성과 동일)

  immutable_보호:
    phase_batches.json은 oplan 생성 후 immutable 상태여야 함
    수정_허용: oplan 에이전트만 (재계획 시)
    수정_금지: odev / otest / odone / 메인 (읽기 전용)
    강제화: phase_batches_immutable_guard.sh hook이 비-oplan 에이전트의 쓰기 시도 차단

    total_batches / batches[] / depends_on_batch 등 필드는 생성 후 수정 금지
    외부 상태 전환만 허용: current_phase_batch 파일 (ok_pipeline 관리)
```

## TODO 파일 형식 (Phase G)

```markdown
# [기능명] 구현 계획
> **목표**: [한 문장]  **아키텍처**: [접근법]  **실행 스킬**: ok → odev

## 참조 문서
- PROJECT.md: [관련 파일/구조]  - LESSONS.md: [L-NNN]

## 수정 파일 목록
- `exact/path/file.cs` — XX 변경

## Task N: [컴포넌트명]
**Files:** Modify: `path/file.cs:123-145`
**Step 1:** [구체적 작업 + 코드]
**Step 2:** Run: `명령어` / Expected: 기대결과
```

각 단계는 1개 액션 (2-5분). 파일 경로+줄번호 명시, DRY/YAGNI 준수.

## Remember

```yaml
필수_포함:
  - 정확한 파일 경로 (상대/절대 모두)
  - 구체적 코드 (모호한 "검증 추가" 금지 → 실제 코드 명시)
  - 실행 명령어 + 예상 출력
  - 각 Task는 2-5분 단위 (더 크면 분할)
금지:
  - "적절히 처리" 같은 모호한 지시
  - 파일 경로 없이 "해당 파일 수정"
  - 라우팅/오케스트레이션 로직 (메인의 역할)
```

## 결과 파일 저장 및 완료 통보 (절대 생략 금지)

```yaml
파일명: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/plans/oplan_{대화ID}.md
대화ID: cat ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/conv_id
포함_내용:
  1. 분류+할당: 규모판정, 에이전트수, 파일할당매트릭스, 페르소나매핑
  2. 계획서: 수정파일목록, 단위작업목록, 메타데이터, 독립그룹
  3. 맥락노트: 참조문서/섹션, 핵심발견, 설계결정근거
  4. TODO: 파일경로 + 핵심항목 인라인

완료_통보:
  반환_필수_필드: tier(O2|O3|O4|O5) — ok가 배너 출력에 사용 (대문자 필수 — classification 파일 저장 표준)
  형식: "oplan 완료 — tier:{O2|O3|O4|O5}/판정:{Quick|Deep}/에이전트:{N}개\n파일:{경로}\n{요약3줄}\n📊 spawn_stats: team=N sub=N task=N"
금지: tier 누락 | 결과파일 없이 완료통보 | 완료통보 없이 idle | spawn_stats 누락
```

## 독립 팀에이전트 모드

> 핵심: 파일 수정 절대 금지, Phase E~J 스킵, 메인에 직접 보고.

## 토론 프로토콜

> o4/o5 자율선택 실행: 작업 특성 분석 후 oplan_deep/oplan_consult/oplan_debate 중 선택
> (oplan_debate: 아키변경/500줄+/이해관계자충돌 | oplan_consult: 기술선택/알고리즘 중심 | oplan_deep: 기본값)

## 데몬 스레드 설계 기피 원칙 (L-402)

```yaml
데몬_설계_기피 (MCP 서버/백그라운드 프로세스 설계 시):
  원칙: 새 데몬 스레드/백그라운드 worker 추가 전 이벤트 기반 대안 우선 검토
  이유: 데몬 스레드는 경계 조건(기동 직후, 재연결, TTL 경계)에서 오발 사례 다수 (L-402)
    - stdin-eof-monitor: 기동 직후 EOF 오판 → SIGINT 자폭 (L-378)
    - ppid-watchdog: ppid=1 조건 오발
    - heartbeat-worker: cross-session lock 도난 경쟁 조건 (L-401)
    - threadpool-monitor: 불필요한 주기 폴링

  이벤트_기반_대안 (우선순위 순):
    1. Hook (SessionStart/PostToolUse): Claude 이벤트에 반응, 1회 실행
    2. startup 1회 실행: 서버 기동 시 단 1회 상태 점검/정리
    3. 공식 SDK 내장 처리: BrokenPipeError/ConnectionResetError catch 위임
    4. 데몬 불가피 시: OIO_LEGACY_DAEMONS=1 rollback 스위치 제공

  oplan_체크리스트:
    - "데몬/worker/background thread 추가" 제안 있으면 → 이벤트 기반 대안 먼저 서술
    - 대안 불가 이유 명시 후에만 데몬 설계 진행
```

## shutdown_request 수신 시 행동

> shutdown_request 수신 즉시 approve 응답 + 작업 중단. 상세: ok SKILL.md 참조.
