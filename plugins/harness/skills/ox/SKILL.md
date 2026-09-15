---
name: ox
description: "o시리즈 완전 미참조 — '/ox' 호출 시 ointaug를 포함한 모든 o시리즈 스킬·파이프라인 라우팅을 일절 경유하지 않고 오리지널 Claude Code 기본 동작으로 즉시 작업에 착수한다. 계획·팀에이전트·테스트·마무리 단계 없이 메인 에이전트가 직접 처리하므로 가장 빠르다. 단순 수정·조회·질문 등 파이프라인 오버헤드가 불필요한 작업, 또는 이전 스킬 컨텍스트 오염을 끊고 싶을 때 사용한다. 파이프라인 바이패스는 ox가 단독으로 담당한다."
invocation:
  user_callable: true
  pipeline_callable: false
  called_by: [사용자]
  calls: []
---
# ox — o시리즈 완전 바이패스 (오리지널 Claude Code 모드)

`/ox {요청}` 호출 시 o시리즈를 **하나도 로딩하지 않고** Claude Code 기본 동작으로 즉시 처리한다.

## 절대 규칙

> **o시리즈 호출 0건**: ointaug를 포함하여 어떤 o시리즈 스킬도 호출하지 않는다.
> **즉시 착수**: 확장 질의·분류 배너·계획 수립 없이 사용자 요청을 바로 수행한다.

## 동작

```yaml
호출_시:
  1. Skill() 호출 없이 즉시 작업 착수 (ointaug 포함 전부 미호출)
  2. 팀에이전트 spawn 금지 — 메인이 직접 수행
  3. pipeline state 변경 금지 (IDLE 유지)
  4. checkpoint·evidence 마커 기록 금지
  5. 결과만 간결히 보고

처리_범위 (전부 메인 직접 수행):
  - 파일 읽기/수정: oio MCP (file_read / file_edit / file_write)
  - 코드 검색: Glob / Grep 직접 사용
  - 셸 명령: oio bash_exec
  - 질문 응답: 텍스트로 직접 답변
  - git 작업: oio bash_exec

금지:
  - Skill('ointaug') / Skill('ok') / Skill('oplan') / Skill('odev') /
    Skill('otest') / Skill('odone') / Skill('ofinish') 등 o시리즈 일체
  - Agent() 팀에이전트 spawn
  - pipeline state 전이 (PLAN/DEV/TEST/DONE/FINISH)
  - 분류 배너·확장 질의·계획서 출력
```

## 유지되는 것 (바이패스 대상 아님)

o시리즈 프로세스만 건너뛴다. 아래는 그대로 적용된다.

```yaml
유지:
  - oio MCP 독점 원칙 — Bash/Read/Edit/Write 내장 도구 사용 금지
  - write_guard.sh 등 hook 물리 차단 (우회 금지)
  - CLAUDE.md 언어 정책 (한국어) + 정보 정직성 원칙
  - 세션 격리 불변식 (자기 UUID 하위만 쓰기)
  - Surgical Changes 원칙 (요청 범위 외 변경 금지)
근거: ox는 "속도"를 위한 것이지 "안전장치 해제"가 아니다.
```

## 활성 파이프라인 중 호출 시 (안전장치)

```yaml
동작: phase_guard.sh가 2단계 확인을 강제한다 (물리 차단).
  1회차: 경고 출력 + ox_confirm 마커 생성. state 유지 (파이프라인 보존).
  2회차: 마커 확인 후 강제 해제 → state=IDLE 전이.
이유: 진행 중인 작업을 단일 오타로 날리는 사고 방지.
권장: 정상 종료가 목적이면 /ox 대신 /ofinish 를 사용하라.
```

## 사용 예시

- /ox 이 파일 3번째 줄 수정해줘
- /ox git status 보여줘
- /ox 이 함수 뭐 하는 건지 설명해줘
- /ox 로그에서 에러만 뽑아줘

## 다른 스킬과의 차이

```yaml
ox   : o시리즈 0건 + ointaug 미발동. 가장 빠름. 계획·검증 없음.
ok   : 전체 파이프라인 (oplan→odev→otest→odone→ofinish). 가장 안전.
oto  : ok + 자율주행 + 목표 달성까지 반복 검증.
선택_기준: 검증이 불필요할 만큼 작고 명확한 작업이면 ox, 그 외에는 ok 계열.
```
