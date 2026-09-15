---
name: oplan_review
description: "계획 검증 — 요구사항 준수 + 기술적 타당성 2단계 검증"
invocation:
  user_callable: false
  pipeline_callable: true
  called_by: ["ok_pipeline(o3Deep/o4/o5)"]
  calls: []
---
# oplan_review — 계획 검증

## 목적

수립된 계획(TODO_*.md)의 **타당성과 완전성**을 검증.
구현 전 계획의 논리적 결함, 누락, 과잉을 사전에 발견.

## 실행 모드

```yaml
서브스킬_모드 (기존):
  설명: oplan 내부에서 Skill('oplan_review') 호출 (Deep 경로 자동 트리거)
  절차: oplan이 Deep 판정 → Two-step Review 수행 → 결과를 oplan에 반환

독립_에이전트_모드 (신규):
  설명: 메인(ok_pipeline)이 팀에이전트로 spawn
  진입: ok_pipeline이 조건부 spawn
    - o3_Quick: 스킵 (구조 검증만으로 충분)
    - o3_Deep: 필수 (oplan이 Deep 판정한 경우)
    - o4/o5: 필수 (oplan_debate 토론 후 추가 독립 검증)
  입력: oplan 산출물 (TODO_*.md, file_assignment.json, scratchpad)
  검증_범위:
    1. 요구사항_준수: 계획이 사용자 요구사항을 빠짐없이 커버하는지
    2. 기술적_타당성: 수정 방향이 코드 구조와 맞는지 (코드 읽기 허용)
    3. 내용_검증:
       - 수정 방향이 요구사항에 정확히 맞는지
       - 누락된 영향 파일이 있는지 (참조 추적)
       - 에이전트 간 작업 분할이 적절한지 (중복/누락 없음)
  출력:
    PASS: "계획 검증 통과" + 검증 요약 (3항목 각각)
    FAIL: "계획 검증 실패: {사유 목록}" + 수정 제안
  완료_통보: SendMessage(type="message", recipient="team-lead")로 PASS/FAIL 결과 반환
  에이전트_이름: "oplan_review-1"
```

## Step 0: 스코프 모드 자동 판정

파일 할당 매트릭스(file_assignment.json) 기반 자동 분류:

```yaml
MODE_A_단일파일:
  조건: 수정 파일 1개, 기능 변경 없음
  처리: Step 1 경량 실행 (Step 2 스킵 가능)

MODE_B_표준:
  조건: 수정 파일 2-5개, 단일 기능/모듈 범위
  처리: Two-step Review 표준 실행

MODE_C_크로스컷:
  조건: 수정 파일 6+개 OR 아키텍처 변경 OR 인터페이스 변경
  처리: Two-step Review + Codex 세컨드 오피니언 (o4/o5 조건 무관)

MODE_D_대규모:
  조건: 수정 파일 10+개 OR 새 도메인 레이어 추가 OR DB 스키마 변경
  처리: Two-step Review + Codex + 리더에게 SPAWN_REQUEST 권고

자동_판단_원칙:
  - AskUserQuestion 금지 — 자동 분류로 즉시 처리
  - 모드 판정 결과를 리뷰 보고서 상단에 표시
  출력: "스코프 모드: MODE_{A/B/C/D} — [판정 근거]"
```

## Two-step Review (순서 필수)

### Step 1: 요구사항 준수 검증 (먼저)

```yaml
체크리스트:
  - [ ] 사용자 요구사항 100% 반영 확인
  - [ ] 계획(TODO_*.md) 모든 항목이 요구사항에 매핑됨
  - [ ] 누락된 요구사항 없음
  - [ ] 불필요한 항목 추가 없음 (Over-engineering 방지)
  - [ ] 파일 경로/줄번호가 실제 코드베이스와 일치

불합격_시: Deep 재수립 (Step 2 스킵)
```

### Step 2: 기술적 타당성 검증 (Step 1 통과 후)

```yaml
체크리스트:
  - [ ] API/함수/메서드 실제 존재 확인
  - [ ] 데이터 타입 호환성 검증
  - [ ] 성능/리소스 이슈 없음
  - [ ] 기존 코드 구조/패턴과 일관성 유지
  - [ ] 사이드 이펙트/호환성 영향 검토 완료

금지: Step 1 불합격 상태에서 Step 2 진행
이유: 요구사항에 안 맞는 계획의 기술 타당성 검증은 무의미
```

## 수행 방법

1. TODO_*.md 파일 내용 확인
2. 사용자 요구사항(프롬프트)과 대조
3. **Step 1**: 요구사항 매핑 검증 → 불합격 시 Deep 재수립
4. **Step 2**: Step 1 통과 후 기술적 타당성 검증
5. 문제 발견 시 Deep 재수립

## YAGNI Check

```yaml
계획에_불필요_항목_존재_시:
  1. 해당 항목이 사용자 요구사항에 직접 매핑되는가?
  2. 미매핑: "요구사항에 없는 항목. 제거? (YAGNI)"
  3. 매핑됨: 유지
```

## 불명확한 요구사항

```yaml
일부_요구사항_불명확:
  금지: 불명확한 채로 계획 승인
  필수: 사용자에게 명확화 질문 후 계획 확정
  이유: 불명확한 계획은 구현 후 재작업 유발
```

## Step 3: Codex 세컨드 오피니언 (조건부)

> 공식 OpenAI Codex MCP(`codex`, `codex-reply`)를 활용한 외부 검증.
> Step 2 통과 후, 복잡한 계획에 한해 Codex에게 계획 비판을 요청한다.

```yaml
발동_조건 (AND — 모두 충족 시):
  - Step 1 + Step 2 모두 통과
  - o4/o5 작업 (o3 이하는 스킵)
  - 수정 파일 4개+ OR 아키텍처 변경 포함

스킵_조건 (하나라도 해당 시):
  - o2/o3 작업
  - 수정 파일 3개 이하 + 아키텍처 변경 없음
  - Codex MCP 미설치/연결 불가

절차:
  1. codex 도구 호출:
     프롬프트: "다음 구현 계획을 비판적으로 검토하라. 블라인드스팟, 누락, 과잉설계를 지적하라."
     입력: TODO_*.md 전문 + 사용자 요구사항 요약
  2. Codex 피드백 수신
  3. 유효한 지적 → 계획 수정 후 Step 1-2 재검증
  4. 지적 없음 또는 이미 반영됨 → 계획 확정
  5. 최대 반복: 2회 (무한 루프 방지)

출력:
  발동_시: "🔍 Codex 세컨드 오피니언 요청 중..."
  완료_시: "✅ Codex 검증 완료 — 지적 {N}건 (반영 {M}건)"
  스킵_시: "⏭️ Codex 검증 스킵 (조건 미충족)"

주의:
  - Codex 피드백은 참고용 — 최종 판단은 Claude가 수행
  - Codex 응답 지연/오류 시 10초 대기 후 스킵 (계획 진행 차단 금지)
  - Codex 비용: 매 호출 시 OpenAI API 토큰 소비됨을 인지
```
