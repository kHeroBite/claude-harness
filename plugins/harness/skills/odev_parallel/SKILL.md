---
name: odev_parallel
description: "병렬 구현 디스패치. 서브/팀에이전트 생성, 파일 할당, 에이전트 관리. Auto-activates when: parallel development, multiple files."
invocation:
  user_callable: false
  pipeline_callable: true
  called_by: ["odev(파일 1개+)"]
  calls: []
---
# odev_parallel — 병렬 구현

## 사용 조건

```yaml
사용:
  - 수정 파일 1개 이상 (항상 에이전트 spawn)
  - 각 파일이 다른 것의 컨텍스트 없이 수정 가능
  - 조사 간 공유 상태 없음

사용_금지:
  - 실패가 연관됨 (하나 고치면 다른 것도 고쳐질 수 있음)
  - 전체 시스템 상태 이해 필요
  - 탐색적 디버깅 (무엇이 고장났는지 아직 모름)

서브에이전트_vs_팀에이전트_판정:
  서브에이전트(Task_병렬):
    조건: 에이전트 간 수정 파일 중복 = 0 (사전 확정, 간접 수정 포함)
    특징: 에이전트끼리 통신 불가 → 파일 충돌 시 감지/조율 불가능
  팀에이전트(TeamCreate):
    조건: 에이전트 간 수정 파일이 겹칠 가능성 있음
    특징: SendMessage로 순서 조율 가능 → 충돌 방지
  판정_규칙:
    - alias 삭제 등 "대상 파일 삭제 + 호출부 교체" 작업은
      호출부가 여러 에이전트 영역에 걸칠 수 있으므로 팀에이전트 우선 검토
    - 간접 수정 가능성(부수 수정, 크로스파일 참조) 있으면 서브에이전트 금지
    - "명시적 수정 파일" 뿐 아니라 "에이전트가 발견할 수 있는 부수 수정 파일"도
      매트릭스에 포함해야 함 (oplan에서 find_referencing_symbols 사전 실행)
```

## 병렬화 분리 기준 (3-Tier 계층적)

> **상세**: [references/PARALLEL_TIERS.md](references/PARALLEL_TIERS.md) — 규모별 분리 정책, Phase 0→1→2 순서, 레이어 세분화, 폼별 분리, Fail-Fast 순서

## 실행 메커니즘 선택 (3가지)

```yaml
서브에이전트_단독 (파일 1개):
  조건: 파일 1개 (병렬화 불필요)
  방법: 서브에이전트 1개 spawn하여 구현 위임 (리더는 결과 수집만)
  적합: 단일 파일 수정, 간단 버그 수정
  이유: 리더 컨텍스트 보호 + 파이프라인 일관성 (항상 에이전트 경유)

서브에이전트_병렬 (기본):
  조건: 파일 2개+, 에이전트 간 중간 결과 교환 불필요
  방법: Task 도구로 병렬 디스패치 → 리더가 결과 수집
  적합: 독립 폼 수정, 독립 쿼리 추가, 레이어별 독립 작업
  특징: 에이전트는 리더에게만 결과 반환, 에이전트끼리 통신 불가

팀에이전트 (예외):
  조건: 에이전트 간 중간 결과 교환/조율이 필요한 경우
  방법: TeamCreate → Taskcreate → Task(팀원) → SendMessage 조율 → TeamDelete
  적합: 복잡한 크로스 레이어 작업, 에이전트 A 결과가 에이전트 B 입력이 되는 경우
  오버헤드: Tasklist 관리, SendMessage 왕복, idle 처리 등 추가 비용
  특징: 팀원끼리 SendMessage로 직접 통신 가능
```

---

## 에이전트 네이밍

> agent_profiles 스킬 참조 (에이전트 네이밍 카탈로그 + 프리셋 조합 — 유일 출처)

---

## 에이전트별 컨텍스트 프리로딩

> **상세**: [references/PARALLEL_TIERS.md](references/PARALLEL_TIERS.md) — 레이어별 자동 로딩 문서 매핑 (impl-*/data-*/be-*/fe-*)

## 실행 절차

### 1. 독립 도메인 식별
레이어 → 모듈/폼별로 독립 작업 그룹화

### 2. 파일 할당 매트릭스 적용

```yaml
사전_조건: oplan 파일 할당 단계에서 생성한 파일 할당 매트릭스 참조

매트릭스_규칙:
  - 각 에이전트의 수정 대상 파일이 명확히 지정됨
  - 수정 파일 중복 = 0 (절대 불변)
  - 읽기전용 파일은 공유 허용 (명시적으로 "읽기전용" 표시)

에이전트_프롬프트에_포함:
  - "수정 허용 파일: [file1.cs, file2.cs]"
  - "읽기전용 참조 가능: [common.cs]"
  - "다른 파일 수정 절대 금지"
```

### 3. 집중된 에이전트 작업 생성

각 에이전트는:
- **Focused**: 한 도메인만
- **Self-contained**: 문제 이해에 필요한 모든 컨텍스트 포함
- **Specific**: 예상 출력 형식 명시
- **File-scoped**: 수정 허용 파일 목록 명시 (매트릭스 기반)
- **Layer-aware**: 해당 레이어 문서/규칙 자동 포함

### 4. 병렬 디스패치

```yaml
spawn_배치_순차화 (config.json 쓰기 경합 방지 — L-137):
  원인: 동시 spawn 시 Claude Code 내부 config.json 동시 쓰기 → 일부 멤버 등록 누락
  규칙:
    - 배치 내 에이전트는 반드시 1개 메시지에 다중 Agent() 호출로 동시 spawn (필수 — 순차 개별 호출 금지, 이는 병렬화 원칙 위반)
    - 동시 spawn 최대 4개 (한 메시지의 Task 호출 수)
    - 5개+ 에이전트 필요 시 배치 분할:
      배치1: Task #1~#4 (run_in_background=true, 동시)
      배치2: Task #5~#8 (배치1 spawn 확인 후)
      배치3: Task #9+ (배치2 spawn 확인 후)
    - 배치 간 gap은 LLM 턴 전환으로 자연 발생 (~2~5초)
    - 각 배치의 spawn 성공 확인 후 다음 배치 진행
  검증:
    - 최종 config.json members 수 == spawn 요청 수 확인
    - 불일치 시 아래 재시도 절차 수행

spawn_재시도_절차 (L-230):
  카운터: $HOME/.claude/session-env/${UUID}/odev_spawn_retry
  절차:
    1. config.json members와 spawn 요청 목록 대조 → 누락 에이전트 식별
    2. 누락 에이전트만 재spawn (동일 프롬프트/설정)
    3. 재시도 카운터 +1 기록
    4. 재spawn 후 다시 members 수 검증
  최대_재시도: 2회
  fallback (2회 초과):
    - 병렬 포기 → 리더가 누락 에이전트의 작업을 순차 직접 수행
    - 이미 성공한 에이전트는 정상 진행 (중단하지 않음)
    - 로그: "⚠️ spawn 재시도 2회 실패 — 순차 실행 fallback: [에이전트명]"

BEFORE_스냅샷_실패_처리 (L-230):
  상황: tmux list-panes 명령 실패 (tmux 미실행, 권한 문제 등)
  절차:
    - 경고 출력: "⚠️ BEFORE 스냅샷 생성 실패 — config.json 기반 검증으로 대체"
    - 스냅샷 없이 계속 진행 (차단하지 않음)
    - pane 정리는 config.json members 기반으로 수행
```

```
# o2/o3 규모 (기존 방식)
Phase 0 (선행 — 공통모듈 변경 시):
  Task("Shared 수정", profile=impl-backend, 수정파일=[shared_files])
  → 완료 대기
Phase 1 (병렬):
  Task("폼 수정", profile=impl-form, 수정파일=[form.cs, form.Designer.cs])
  Task("Backend", profile=impl-backend, 수정파일=[service.cs])

# o3/o4/o5 규모 (3-Tier 방식)
Phase 0 (선행 — Shared 변경 시):
  Task("인터페이스/공통", profile=be-interface, 수정파일=[shared_files])
  → 완료 대기
  # [L-306/L-357/L-376] Phase 0 완료 직후 의무 검증 (인터페이스 시그니처 변경 시):
  # 다음 Phase 착수 전 반드시 stub 파일을 file_read/grep으로 재확인
  # 합의된 시그니처(메서드명, 파라미터 개수·타입·순서·반환형)를 실제 파일에서 검증
  # 예: grep "GetDashboardChartsAsync" IDashboardService.cs → 파라미터 수/순서 확인
  # 예: grep "BuildCacheKey" IDashboardService.cs → 반환형(string vs ChartGroupKey) 확인
  # 가정 금지 — 합의 내용과 실제 파일이 다를 수 있음
  # [L-376 추가] 반환형 변경 전파 점검:
  # Wave 진행 중 인터페이스 메서드 반환형 변경 시 전파 체크리스트 실행:
  #   1. 인터페이스 파일 (I*.cs) 반환형 확인
  #   2. 구현 파일 반환형 확인
  #   3. 호출부 변수 타입 확인 (var vs 명시 타입)
  # grep "반환형_패턴" <프로젝트> 로 일관성 전수 확인 필수
  # [L-975 추가 — 2026-09-07 사이클88 D-11] 서버 보호 경로(인증 미들웨어 패턴) 신설 시 전파 점검:
  #   보호를 넣은 Wave 가 완료조건을 갖는다 — 그 패턴에 매칭되는 클라이언트 HTTP 호출부를 전수 grep 하라.
  #   grep "HttpClient\|DefaultRequestHeaders" <클라이언트 프로젝트> → 새 보호 경로를 부르는 생성부마다 헤더(Bearer 등) 부착 확인
  #   시그니처는 컴파일러가 잡지만 헤더는 런타임 401 로만 드러난다. 다른 Wave 에 맡기면 그 경계에서 401 이 태어난다.
Phase 1 (Data Layer):
  Task("SQL 정의", profile=data-query, 수정파일=[Queries/XxxQueries.cs])
  Task("DTO 매핑", profile=data-model, 수정파일=[Models/Xxx.cs])
  → 완료 대기
Phase 2 (Backend + Frontend 병렬):
  Task("비즈니스 로직", profile=be-csharp, 수정파일=[XxxService.cs])
  Task("Gateway API", profile=be-gateway, 수정파일=[XxxController.cs])
  Task("폼 A", profile=fe-designer, 수정파일=[FormA.cs, FormA.Designer.cs])
  Task("폼 B", profile=fe-designer, 수정파일=[FormB.cs, FormB.Designer.cs])
  // 독립 도메인 수만큼 동시 실행 (배치당 최대 4개 — L-137)
```

## 에이전트 수 정책 + Load Balancing

> **상세**: [references/PARALLEL_TIERS.md](references/PARALLEL_TIERS.md) — 도메인 수 기반 에이전트 수 결정, 종료 시간 균등화 (±30% 이내)

### 5. 완료 에이전트 즉시 회수

```yaml
규칙: Task/팀 에이전트 완료(결과 반환 또는 idle) 시 즉시 후속 처리
처리:
  - 단일 작업 에이전트: 결과 확인 후 추가 작업 없으면 완료 (Task 자동 종료)
  - 팀 에이전트(TeamCreate): idle_notification 수신 즉시 shutdown_request 또는 새 작업 할당
금지: 완료된 에이전트를 방치한 채 다른 작업에 집중 (리소스 낭비 + pane 점유)
```

### 5.5 에이전트 pane 소멸 감지 + 재spawn (L-307)

```yaml
소멸_감지_조건:
  - DM(SendMessage) 응답 타임아웃: 5분 이상 무응답
  - tmux list-panes에서 해당 에이전트 pane 미존재
  - 두 조건 중 하나라도 해당 시 소멸 의심

소멸_확인_절차:
  1. tmux list-panes -a | grep {에이전트명} 으로 pane 존재 확인
  2. pane 없음 → 소멸 확정
  3. pane 있음 → rate limit/응답 지연 가능성 → 추가 대기(2분) 후 재확인

재spawn_절차 (소멸 확정 시):
  1. 해당 에이전트의 원래 작업 목록 재확인
  2. 완료된 작업 목록 확인 (git diff + evidence 파일)
  3. 미완료 작업만 신규 에이전트로 재spawn (새 번호 부여: odev-N+1)
  4. 재spawn 로그 기록:
     "⚠️ odev-{N} pane 소멸 — odev-{N+1} 재spawn: 미완료 작업 {M}건"

대규모_병렬_작업_주의 (50건+):
  - 에이전트당 작업량을 20건 이하로 보수적 산정
  - 처리량 초과 시 추가 에이전트 선제 배정 (역라우팅 최소화)
  - pane 소멸 위험 증가 구간: 에이전트 spawn 30분 초과 시

금지:
  - pane 소멸 확인 없이 영구 대기
  - 소멸 에이전트의 작업을 미처리 방치
```

### 6. 검증 에이전트 디스패치 (구현 완료 후)

```yaml
조건: 구현 에이전트 2개+ 완료 시
병렬_실행:
  - 코드 리뷰: odev_review 참조 (구현 결과물 리뷰 위임)
  - 영향도 분석: odev_impact 참조 (시그니처 변경 포함 시)
  둘 다 읽기 전용 → 동시 실행 가능

에이전트_1개:
  리더가 직접 검증 (검증 에이전트 불필요, 구현은 서브에이전트가 수행)
```

### 7. 통합
- 검증 결과 확인
- 전체 빌드 실행
- 모든 변경사항 통합

## 파일 소유권 시스템

```yaml
소유권_원칙:
  - 각 에이전트는 자신에게 할당된 파일만 수정 가능
  - oplan 파일 할당 단계의 파일 할당 매트릭스에서 소유권 결정
  - 수정 파일 중복 = 0 (절대 불변)

프롬프트_템플릿: |
  [작업 설명]

  📁 수정 허용 파일 (소유권):
    - file1.cs
    - file2.cs

  📖 읽기전용 참조 가능:
    - common.cs
    - config.json

  🚫 다른 파일 수정 절대 금지

소유권_위반_감지:
  방법: 에이전트 완료 후 git diff로 실제 수정 파일 확인
  위반_시: 해당 변경 revert → 올바른 소유권으로 재할당

간접_수정_예측:
  정의: 에이전트가 "alias 삭제" 등 작업 시, 호출부 탐색(find_referencing_symbols)으로
        사전에 예측하지 못한 파일까지 수정하게 되는 경우
  방지:
    - oplan에서 find_referencing_symbols 사전 실행하여 모든 호출부 파일 확인
    - 호출부가 다른 에이전트 영역 파일과 겹치면 → 팀에이전트 전환 또는 한 에이전트에 전담
    - 프롬프트에 "발견한 부수 수정이 소유권 밖이면 수정하지 말고 보고만 하라" 명시
```

## TeamCreate 팀원 관리 (예외적 사용 시)

```yaml
TeamCreate_전_필수_확인 (재발방지 — L-332):
  문제: 이전 파이프라인 잔여 팀이 메모리에 남아 "Already leading team" 오류 발생
        → Agent 호출 시 hook이 팀 디렉터리 없음으로 Block
  절차:
    1. TeamCreate 전 반드시 /ofinish로 현재 팀 정리 확인 (잔류 팀 존재 시)
    2. 기존 팀 존재 시 → TeamDelete 후 TeamCreate (재생성)
    3. "Already leading team" 오류 수신 시 → Agent 재시도 가능 (팀 이미 존재)
  금지: TeamCreate 오류를 무시하고 즉시 Agent 재호출 (hook 차단 가능성)

참조_방식: 항상 name으로 참조 (UUID 아님)
순차_의존성: 있으면 Team 대신 직접 실행

idle_팀원_즉시_처리 (필수):
  규칙: 팀원이 작업 완료 후 idle_notification 수신 시 즉시 후속 처리
  처리_순서:
    1. 해당 팀원에게 할당된 작업이 남아있는가? → 새 작업 SendMessage
    2. 남은 작업 없음 → 즉시 SendMessage(shutdown_request) 전송
  금지: idle 팀원을 방치한 채 다른 작업에 집중 (리소스 낭비)

커밋_충돌_방지:
  원칙: 팀원은 커밋하지 않음 (리더만 커밋)
  이유: 팀원들이 동시 커밋하면 merge 충돌 발생

Fresh_Subagent:
  원칙: 작업당 새 서브에이전트 생성
  이유: 컨텍스트 오염 방지
  금지: 하나의 에이전트에 여러 작업 할당
```

## Common Mistakes

> **상세**: [references/PARALLEL_TIERS.md](references/PARALLEL_TIERS.md) — 6가지 안티패턴 + 올바른 패턴

## 리더 TODO 추출 규칙

```yaml
규칙: 리더가 TODO 파일 1회 읽고 전체 작업 추출
제공: 각 에이전트에 해당 Task 전문(full text) 직접 제공
금지: 에이전트가 TODO 파일 직접 읽기 (context 낭비)
이유: 파일 읽기 오버헤드 제거 + context 효율
```

## 에이전트 질문 처리

```yaml
에이전트_질문_허용: 작업 전/중 불명확한 점 발견 시 질문 가능
리더_응답: 즉시 명확하게 답변 (모호한 답변 금지)
프롬프트_포함: "불명확한 점 있으면 작업 중단 후 질문하세요"
```

---

## ext4 작업 파일 보호 (L-037 — 절대 규칙) — odev에서 이관

```yaml
문제: cp NTFS→ext4 시 다른 에이전트의 미커밋 편집이 덮어써짐
Hook_방어: ext4_freshness_guard.sh가 ext4 파일이 NTFS보다 최신이면 cp 차단

규칙:
  cp_전_확인: ext4 작업 파일이 이미 존재하면 cp 하지 않고 기존 ext4 파일 사용
  병렬_에이전트: 자신에게 할당된 파일만 수정 가능
  다른_에이전트_파일: 수정 절대 금지 — 해당 에이전트의 편집이 소실됨
  안전성: oio MCP의 Low-level Lock이 동일 파일 동시 수정 자동 차단
금지:
  - 다른 에이전트 할당 파일 수정 (Lock으로 차단됨)
  - 다른 에이전트 할당 파일 경로로 cp 실행
```
