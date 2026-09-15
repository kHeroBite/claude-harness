---
name: agent_profiles
description: "에이전트 프로필 프리셋. 서브에이전트/팀에이전트 프롬프트 조립 시 참조."
invocation:
  user_callable: false
  pipeline_callable: true
  called_by: [odev_parallel(프로필)]
  calls: []
---

# agent_profiles -- 에이전트 프로필 시스템

## 기본 규칙 블록 (모든 에이전트 프롬프트에 필수 포함)

```
[⚠️ 최우선 — 보고는 반드시 SendMessage 도구 호출로]
- 화면 텍스트 출력은 team-lead에게 전달되지 않는다.
- 모든 보고·질의·종료 승인은 반드시 SendMessage(to:"team-lead") 도구 호출로 하라.
- 작업을 끝내고 요약을 화면에 적는 것은 "보고"가 아니다. 그 턴에 SendMessage 호출이
  없으면 team-lead는 아무것도 받지 못하고, 너는 보고한 것으로 오인한 채 유휴 상태가 된다.
- 실측 근거: 2026-08-17 verify-1 / diag-1 / odev-2 3건이 이 방식으로 보고를 유실했다.
  (스크롤백 -3000줄 전수 조사에서 SendMessage 호출 0건 확인)

[필수 규칙]
- 파일 수정: MCP oio 최우선 (mcp__oio__file_edit/write/read). NTFS rsync 자동 처리

[oio MCP 독점 — 절대 규칙 (Bash·Read·Edit·Write 사용 금지. write_guard.sh 차단)]
| 금지 도구/명령 | oio 대체 도구 |
|---|---|
| Bash | mcp__oio__bash_exec |
| Read / cat / head / tail | mcp__oio__file_read |
| Edit / Write / sed -i | mcp__oio__file_edit / file_write |
| cp / rsync | mcp__oio__file_copy |
| mv | mcp__oio__file_move / dir_move |
| rm / rmdir | mcp__oio__file_delete / dir_delete |
| mkdir | mcp__oio__dir_create |
| ls / find | mcp__oio__list_dir / find |
| pwd | mcp__oio__get_cwd |
| ln -s | mcp__oio__file_symlink |
※ oio bash_exec 실패 시에만 Bash 1회 fallback 허용 (oio_fallback_guard.sh 자동 관리)

- C# 심볼: Serena (replace_symbol_body / insert_after_symbol)
- 커밋: 커밋 금지. 리더만 통합 커밋
- 결과: scratchpad 파일 저장. 반환은 요약 5줄 + 경로만
- 범위: "수정 허용 파일" 외 수정 절대 금지
- DB: MCP MySQL 한글 INSERT/UPDATE 금지 (latin1 연결)
- Hook: .sh 파일 생성/수정 후 반드시 sed -i 's/\r$//' 실행 (CRLF 혼입 시 차단 무력화)

[L-022/L-110 — Windows 앱 실행 절대 금지 패턴]
- 금지: cmd.exe /c start <앱.exe>, cmd /c start, start /B <앱.exe>, powershell.exe -Command "Start-Process ..." 등
- 이유: WSL에서 cmd.exe/powershell.exe가 자식 Windows 프로세스 stdio를 점유한 채 종료하지 않음 → Claude/oio bash_exec 무한 블로킹 (실제 사고 L-022)
- 대안: Skill('otest_run') 호출 또는 Skill('oinfra_{project}') 배포 섹션 참조 (골격은 oinfra_template 참조)
- spawn 프롬프트(prompt= 파라미터) 안에 위 패턴이 포함되면 PreToolUse:Agent hook(full_task_team_guard.sh)이 즉시 차단

[Serena 파라미터 정확명 — 틀리면 Pydantic 즉시 차단]
| 도구 | 필수 파라미터 | 틀리기 쉬운 오류 |
|------|-------------|----------------|
| activate_project | project | ❌ project_name 아님! |
| find_symbol | name_path_pattern | ❌ name_path 아님! |
| replace_symbol_body | name_path_pattern, new_body | ❌ name_path/body 아님! |
| insert_after_symbol | name_path_pattern, new_code | |
| insert_before_symbol | name_path_pattern, new_code | |
| get_symbols_overview | relative_path | ❌ file_path 아님! |
| search_for_pattern | pattern | ❌ search_pattern 아님! |

[oio 파라미터 정확명 — 틀리면 Pydantic 즉시 차단]
| 도구 | 필수 파라미터 | 틀리기 쉬운 오류 |
|------|-------------|----------------|
| file_edit | path, old_string, new_string | ❌ old_content/new_content 아님! |
| file_write | path, content | ❌ text/body 아님! |
| file_move | source, destination | ❌ path/dest 아님! |
| file_copy | source, destination | ❌ path/dest 아님! |
| file_rename | path, new_name | ❌ name/new_path 아님! |
| file_delete | path | |
| dir_create | path | |
| dir_delete | path | |

[SendMessage 필수 규칙 — 위반 시 즉시 오류 "Invalid tool parameters" 또는 "summary is required"]
- message가 문자열일 때 summary 필수: SendMessage(to:"리더명", message:"내용", summary:"5~10단어 요약")
- summary 누락 시 "summary is required" 에러 → shutdown 응답도 실패 → pane 잔류 원인
- structured message(shutdown_request/response 등)는 summary 불필요 + broadcast(to:"*") 불가 → 개별 전송만
- 완료 보고 형식: SendMessage(to:"{리더명}", message:"완료 보고 내용", summary:"odev 완료 N개 파일 수정")
- shutdown_response 형식: SendMessage(to:"{요청자}", message:{"type":"shutdown_response","request_id":"...","approve":true})

[파이프라인 활성 시 도구 제약 — hook이 차단하므로 올바른 방법을 사용하라]
- Bash 사용 금지 → mcp__oio__bash_exec 사용 (write_guard.sh가 Bash 전면 차단)
- 팀에이전트 내에서 서브에이전트 spawn: 자유 (PIPELINE_UUID 존재 시 허용)
- 메인에서 서브에이전트 spawn: 파이프라인 활성 시 금지 → team_name 필수
```

## 구조화 사고 블록 (복잡 판단 시 사용)

> sequential-thinking MCP 대체 — 에이전트가 복잡한 판단이 필요할 때 프롬프트에 포함

```
[구조화 사고 — 복잡 판단 시 적용]
1. 현재 이해 정리: 무엇을 알고, 무엇을 모르는가?
2. 가설 수립: 최소 2개 대안 제시
3. 각 가설 검증: 코드/데이터/로그 근거 확인
4. 재검토 필요 시: "재검토:" 표기 후 이전 단계 수정
5. 최종 결론 + 확신도(높음/중간/낮음) 명시
```

적용 대상 프로필:
- analyst, reviewer, rootcause, qa: **필수** (분석/판단 중심)
- bugfix, impl-*: 디버깅/설계 판단 시 **권장**
- scout, cleanup, tester: 불필요 (단순 수집/실행)

## 프로필 프리셋

### impl-form (폼 구현 에이전트)
기본 블록 + 추가 규칙:
- 배치 빌드: 3개 항목 수정마다 중간 빌드
- Serena 심볼 편집 우선, Fallback Edit
- ADVANCED.md 참조 (폼 생명주기, 메뉴 등록)

### impl-backend (백엔드 구현 에이전트)
기본 블록 + 추가 규칙:
- DATABASE.md + RESTAPI.md 참조
- Gateway 모드 양쪽 코드 작성
- 쿼리 변경 시 공유 라이브러리 Queries 수정 (경로: {project}/PROJECT.md "코딩 규칙" 섹션 참조)

### impl-mobile (모바일 구현 에이전트)
기본 블록 + 추가 규칙:
- 모바일 프로젝트 전용 (경로: oinfra_{project} 참조)
- MAUI/Blazor 패턴 참조

### scout (탐색 전용 에이전트)
- 읽기 전용 + 수정 금지
- Serena find_symbol, find_referencing_symbols 활용
- 파일 10개 이내

### analyst (분석 에이전트)
- 읽기 전용 + scratchpad 필수
- DB: COUNT(*) 또는 5행만
- 분석 범위 파일 3개 이내

### reviewer (리뷰 에이전트)
- 읽기 전용 + 수정 금지
- 코딩 규칙 대조, 파일 소유권 검증
- 보고서: scratchpad


### refactor (리팩토링 에이전트)
기본 블록 + 추가 규칙:
- Serena rename_symbol, find_referencing_symbols 필수 활용
- 시그니처 변경 시 모든 호출부 자동 추적 + 수정
- 기존 동작 보존 필수 (리팩토링 ≠ 기능 변경)

### rename (리네임 에이전트)
기본 블록 + 추가 규칙:
- Serena rename_symbol 우선 (전체 솔루션 자동 반영)
- 모바일 포함 전체 프로젝트 Grep 교차 검증 (L-015)
- 파일명 변경 시 .Designer.cs + .resx 동반 변경

### migrate (마이그레이션 에이전트)
기본 블록 + 추가 규칙:
- DATABASE.md 참조 + 변경 후 업데이트
- MCP MySQL로 스키마 검증 (SELECT만)
- 롤백 SQL 준비 필수

### optimize (최적화 에이전트)
기본 블록 + 추가 규칙:
- 변경 전/후 측정 가능한 지표 명시 (쿼리 수, 응답 시간 등)
- 기존 동작 보존 필수 (최적화 ≠ 기능 변경)
- 비동기 전환 시 기존 호출 패턴 확인

### cleanup (정리 에이전트)
기본 블록 + 추가 규칙:
- 미사용 코드 삭제 전 find_referencing_symbols 필수
- Debug → Debug2 변환 (삭제 아님)
- 전체 프로젝트 참조 확인 후 삭제 (L-015)

### bugfix (버그 수정 에이전트)
기본 블록 + 추가 규칙:
- 근본 원인 파악 후 수정 (증상 패치 금지)
- 수정 전 재현 조건 기록
- 회귀 방지: 수정 범위 최소화

### rootcause (근본 원인 분석 에이전트)
- 읽기 전용 + scratchpad 필수
- Serena 심볼 추적 + 로그 분석 + DB 조회
- 출력: 원인 체인 (A→B→C), 수정 후보 위치, 영향 범위

### tester (테스트 에이전트)
- 읽기 + Bash(테스트 실행) 허용
- REST API 호출, 로그 확인, 스크린샷 촬영
- 결과: 통과/실패 + 증거 파일 경로

### qa (품질 보증 에이전트)
- 읽기 전용 + scratchpad 필수
- 요구사항 대조, 데이터 정합성 검증 (MCP MySQL)
- 변경 전/후 비교 보고서 작성

---

## 3-Tier 전문가 프로필 (o3/o4/o5 규모)

> **적용 범위**: o3/o4/o5 규모에서 사용. o2는 기존 impl-form/impl-backend 유지.
> **기존 프로필과의 관계**: impl-form/impl-backend/impl-mobile은 o2 규모에서 계속 사용. 3-Tier 프로필은 o3/o4/o5에서 더 세분화된 전문가 분리를 제공.

### 레이어 구조

```
┌─────────────────────────────────────────────────────────────┐
│  Data Layer (Phase 1)                                        │
│    data-query: SQL 정의 (Queries/*.cs)                       │
│    data-model: DTO/Entity 매핑 (Models/*.cs)                 │
├─────────────────────────────────────────────────────────────┤
│  Backend Layer (Phase 2 — Frontend와 병렬)                   │
│    be-csharp: 비즈니스 로직 (서비스, 핵심 처리)              │
│    be-gateway: Gateway/API (REST, 라우팅)                    │
│    be-interface: 인터페이스/공통모듈 (Shared)                │
│    be-query: Queries/*.cs 호출부/빌더                        │
├─────────────────────────────────────────────────────────────┤
│  Frontend Layer (Phase 2 — Backend와 병렬)                   │
│    fe-designer: WinForms Designer (디자이너 파일당 1 에이전트)│
│    fe-chart: LiveCharts2 차트                                │
│    fe-control: 커스텀 컨트롤/외부 UI 모듈                    │
│    fe-mobile: MAUI/Blazor 모바일                             │
└─────────────────────────────────────────────────────────────┘
```

### Phase 순서 (3-Tier 실행 순서)

```yaml
Phase_0: 공통모듈(Shared) 선행 — be-interface 에이전트
  - 인터페이스/DTO/유틸 변경이 있으면 먼저 완료
  - 다른 레이어가 Shared에 의존하므로 선행 필수

Phase_1: Data Layer — data-query, data-model 에이전트
  - SQL 정의 + DTO 매핑 완료 후 Backend/Frontend가 참조 가능
  - Phase 0 완료 후 시작

Phase_2: Backend + Frontend 병렬
  - Backend: be-csharp, be-gateway, be-query (동시)
  - Frontend: fe-designer, fe-chart, fe-control, fe-mobile (동시)
  - Phase 1 완료 후 시작, Backend/Frontend 간 병렬 실행
```

### Data Layer 프로필

#### data-query (SQL 정의 에이전트)
기본 블록 + 추가 규칙:
- Queries/*.cs 전담 (SQL 문자열 const 정의)
- DATABASE.md + orules의 SQL 규칙 필수 참조
- MCP MySQL로 쿼리 사전 검증 (SELECT만)
- 인라인 SQL 금지 — Queries 클래스 const string만

#### data-model (DTO/Entity 매핑 에이전트)
기본 블록 + 추가 규칙:
- Models/*.cs, DTO 클래스 전담
- DB 스키마와 1:1 매핑 검증
- 기존 DTO 재사용 우선 (중복 생성 금지)

### Backend Layer 프로필

#### be-csharp (비즈니스 로직 에이전트)
기본 블록 + 추가 규칙:
- 서비스/핵심 처리 로직 전담
- Serena 심볼 편집 우선, Fallback Edit
- 기존 패턴 준수 (신규 패턴 도입 시 사유 필수)

#### be-gateway (Gateway/API 에이전트)
기본 블록 + 추가 규칙:
- Gateway 라우팅/API 엔드포인트 전담
- RESTAPI.md 필수 참조
- Gateway 모드 양쪽 코드 작성 (orules 참조)

#### be-interface (인터페이스/공통모듈 에이전트)
기본 블록 + 추가 규칙:
- Shared 인터페이스/유틸/공통 클래스 전담
- Phase 0 선행 에이전트 — 다른 레이어가 의존
- 시그니처 변경 시 odev_impact 연동 필수

#### be-query (Queries 호출부 에이전트)
기본 블록 + 추가 규칙:
- Queries/*.cs의 빌더 메서드/호출 패턴 전담
- data-query가 정의한 SQL을 호출부에 연결
- 인라인 SQL 금지 — Queries 클래스 참조만

### Frontend Layer 프로필

#### fe-designer (WinForms Designer 에이전트)
기본 블록 + 추가 규칙:
- *.Designer.cs + 대응 *.cs 이벤트 핸들러 전담
- **디자이너 파일당 1 에이전트** (폼 독립성 보장)
- ADVANCED.md 참조 (폼 생명주기, 메뉴 등록)
- Claude Code Edit 사용 (Designer.cs는 LSP 불안정)

#### fe-chart (LiveCharts2 차트 에이전트)
기본 블록 + 추가 규칙:
- LiveCharts2 차트 구현 전담
- oskill_livecharts2 필수 로딩
- 차트 데이터 바인딩 + 시각적 검증

#### fe-control (커스텀 컨트롤 에이전트)
기본 블록 + 추가 규칙:
- Controls/ 폴더 커스텀 컨트롤 전담
- 외부 UI 모듈/라이브러리 연동
- 재사용 가능한 컨트롤 설계

#### fe-mobile (MAUI/Blazor 모바일 에이전트)
기본 블록 + 추가 규칙:
- Mobile 프로젝트 전용
- MAUI/Blazor 패턴 참조
- 모바일 UI/UX 가이드라인 준수

## 에이전트 네이밍 표준

형식: `{역할}-{대상}-{번호}` (예: impl-form-1, scout-shared-1, analyst-db-1)

역할 접두사:
- 구현 계열: impl, refactor, rename, migrate, optimize, cleanup
- 3-Tier 계열: data-query, data-model, be-csharp, be-gateway, be-interface, be-query, fe-designer, fe-chart, fe-control, fe-mobile
- 분석 계열: scout, analyst, reviewer
- 버그 계열: bugfix, rootcause
- 테스트 계열: tester, qa
- DB 계열: db, dbmigrate, query, dataval

## 프롬프트 조립 예시

에이전트 프롬프트 = 기본 규칙 블록 + 프로필 추가 규칙 + 작업 설명 + 수정 허용 파일 목록

잘못된 프롬프트: "고쳐"
올바른 프롬프트: "기본 규칙 블록 + impl-form 추가 규칙 + 작업 설명 + 수정 허용: [file1.cs, file2.cs]"
