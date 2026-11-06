# 정본 문서 카탈로그 (CATALOG)

> 역할: `plan/` 에 둘 수 있는 표준 산출물 문서의 키·위치·최소 목차·갱신 주체를 한 표로 정한다.
> 키는 `plan/index.json` 의 `documents` 키와 같다. 폴더 번호는 기본값이며 프로젝트가 바꿀 수 있다.
> 문서별 템플릿은 `DOC_TEMPLATES_A.md`(분석·설계)와 `DOC_TEMPLATES_B.md`(계획·시험·이행·결정)에 있다.

## 1. 카탈로그

| 키 | 기본 위치 | 목적 | 최소 목차 | 형식 | 단계 | 갱신 주체·트리거 | 템플릿 |
|---|---|---|---|---|---|---|---|
| requirements_raw | `00_요구사항/01_사용자요구사항_원문.md` | 원문 보존 | 일자·원문·출처 | md | 분석 | oplan: 새 요구 수신 때 추가 | init 템플릿 |
| requirements | `00_요구사항/02_요구사항정의서.md` | 요구 확정·추적 | REQ-ID·요구·출처·우선순위·수용기준·상태·관련 FN/TC | md(+csv 선택) | 분석 | oplan: 추가·변경 / odone_docs: 상태 | A §1 |
| analysis | `01_분석/NN_*.md` | 현황·기존 시스템·외부 조사 | 질문·방법(측정 명령)·결과·출처·결론 | md | 분석 | oplan: 조사 사이클 | A §2 |
| scope | `02_범위_일정/01_개발범위.md` | In/Out·릴리스 | 범위·제외·단계 | md | 계획 | oplan | B §1 |
| wbs | `02_범위_일정/02_WBS.md` | 작업 분해·진척 | WBS-ID·작업·REQ/FN·산출물·상태·진척률·완료일 | md(+csv) | 계획→전 단계 | oplan: 작업 추가 / odone_docs: 이번 사이클 WBS-ID 상태·진척 | B §2 |
| schedule | `02_범위_일정/03_일정표.md` | 마일스톤 | 마일스톤·목표일·실제일·상태, mermaid gantt | md | 계획 | oplan: 계획 변경 / odone_docs: 마일스톤 완료 | B §3 |
| architecture | `03_아키텍처/01_아키텍처_설계.md` | 구조 정본(to-be) | 구성도·계층·의존 규칙·품질 속성·제약 | md+mermaid/svg | 설계 | oplan: 구조 결정 | A §3 |
| tech_stack | `03_아키텍처/02_기술스택.md` | 기술 선택 | 항목·선택·버전·근거(ADR) | md | 설계 | oplan | A §4 |
| features | `04_기능/01_기능요건.md` | 기능 목록 | FN-ID·모듈·기능·REQ-ID·우선순위·단계·상태 | md(+csv, 많으면 `_build`) | 분석·설계 | oplan / odone_docs: 상태 | A §5 |
| erd | `05_데이터/01_ERD.md` | 데이터 설계(to-be) | mermaid erDiagram·엔터티 정의·변경 이력 링크 | md | 설계 | oplan: 스키마 설계 | A §6 |
| screens | `06_화면/01_화면목록_메뉴.md`·`02_화면기획서.md` | 메뉴·화면 사양 | SCR-ID·메뉴 경로·레이아웃·동작·FN-ID·폼팩터 | md(+csv) | 설계 | oplan: UI 사이클 | A §7 |
| api | `07_인터페이스/01_API설계.md` | 인터페이스 | 공통 규약·엔드포인트·요청/응답·오류·권한 | md | 설계 | oplan | A §8 |
| test_plan | `08_시험/01_시험계획.md` | 시험 범위·방법 | 대상·환경 축·도구(test/ 경로)·합격 기준·일정 | md | 시험 | otest(o3+ 새 기능) | B §4 |
| test_cases | `08_시험/02_시험케이스.md` | 케이스 추적 | TC-ID·REQ/FN·절차·기대값·자동화 스크립트 경로 | md(+csv) | 시험 | otest | B §5 |
| test_report | `08_시험/03_시험결과서.md` | 회차 요약 | 회차·판·결과 요약·남은 FAIL·증거 위치(archive) | md | 검증 | otest_evidence | B §6 |
| deploy | `09_구축_배포/01_구축_배포.md` | 환경·배포 구조 | 환경 구성·배포 흐름·롤백(값은 INFRA 참조) | md | 이행 | oplan | B §7 |
| decisions | `90_결정관리/02_결정기록_ADR.md`(+`_부록/b*`) | 확정 결정 | ADR-NNN·일자·결정·근거·대안·영향·상태 | md | 전 단계 | odone_docs | init 템플릿, B §8 |
| pending | `90_결정관리/01_결정대기_질문목록.md` | 미결 | D-ID·주제·잠정안·상태·영향 문서 | md | 전 단계 | oplan·odone_docs | init 템플릿, B §9 |
| todo | `90_결정관리/03_향후과제_TODO.md` | 잊지 말 과제 | TODO-ID·내용·출처·재검토 시점·상태 | md | 전 단계 | odone_docs | init 템플릿, B §10 |
| changelog | 루트 `HISTORY.md` | 변경이력 | 기존 형식 | md | 마무리 | odone_docs | 기존 정본 재사용(plan 에 중복 두지 않음) |
| report | `99_보고/` | 요약·발표 | — | md/pptx(`_build`) | 요청 시 | — | 없음 |

## 2. 공통 규칙

- 파일명은 `NN_제목.md` 다. 같은 폴더 안에서 번호로 순서를 정한다.
- 문서가 300줄을 넘으면 `NN_제목_부록/a1_*.md` 로 나누고 본문에는 부록 색인표를 둔다.
- 모든 문서 머리에 `상태`(초안·검토·확정·대체됨)와 `최종 갱신일`을 둔다.
- 추정·미검증 내용은 `(추정)`·`(미검증)` 으로 표기한다. 외부 정보에는 출처 URL 을 적는다.
- 자격증명·서버 주소·포트·계정 값은 쓰지 않는다. 필요하면 "INFRA.md `<절 이름>` 참조" 로 적는다.
- 같은 주제는 새 파일을 만들지 않고 기존 문서를 갱신한다. 판 사본(`_v1`·`_v2`·`_old`·`_bak`·`_copy`)은 만들지 않는다.
- 문서 간 추적은 ID 로 한다. REQ-ID → FN-ID → SCR-ID·API → TC-ID → WBS-ID 순으로 서로를 가리킨다.
- 다이어그램은 텍스트 원본(mermaid·svg)을 정본으로 둔다. png 등 이미지는 `plan/_build/` 스크립트로 다시 만든다.
- as-built(현재 구현) 정보는 기존 정본을 쓴다. 구조는 PROJECT.md, 스키마는 DATABASE.md, 변경이력은 HISTORY.md 다.

## 3. 생성 시점 (주문형)

- `plan_init.py` 가 만드는 것은 프로파일의 init 파일뿐이다(§4). 나머지 문서는 그 문서가 처음 필요한 사이클에 만든다.
- 필요 판단 기준은 이렇다. 그 문서에 담을 결정·요구·설계가 이번 사이클에 실제로 생겼을 때만 만든다.
- 빈 골격만 미리 만들어 두지 않는다(R3 — 쓸모없는 파일 금지).
- 문서를 만들면 같은 사이클에 `plan/index.json` `documents` 에 키와 경로를 등록하고, `active_docs` 에 키를 추가한다.

## 4. 프로파일

`plan/index.json` 의 `profile`·`active_docs` 로 선언한다. 선언되지 않은 문서는 감사(`plan_audit.py`)가 요구하지 않는다.

| 프로파일 | 대상 | 활성 문서(키) | init 생성 파일 |
|---|---|---|---|
| product | 제품 개발(DB·화면·서버가 있는 저장소) | 전체 카탈로그에서 필요 시 생성 | README·index.json·requirements_raw·requirements·pending·decisions·todo (7) |
| tool | 하네스·도구·스크립트 저장소 | requirements_raw·requirements·architecture·decisions·pending·todo·test_plan | README·index.json·requirements_raw·decisions (4) |
| small | 소규모·개인 자동화 | decisions | README·index.json (2, ADR 은 첫 결정 때) |

판정 기본값(`plan_init.py` 가 제안하고 `--profile` 로 덮어쓴다)은 다음과 같다.
- DATABASE.md 가 있거나 화면·서버 하위 프로젝트가 있으면 product 다.
- 하네스 자산(`.claude/hooks` 등)이나 스크립트 위주 저장소면 tool 이다.
- 그 외는 small 이다.

## 5. 생명주기 요약

1. 시작: oplan 이 `plan/README.md` 원칙 → `plan/index.json` → 관련 문서를 읽고 계획서 `## 정본 참조` 절에 남긴다.
2. 진행: 설계와 다른 구현이 필요하면 odev 는 멈추고 리드에 보고한다. 리드가 문서 수정 항목을 먼저 배정한다(문서 먼저, 코드 나중).
3. 시험: otest 가 시험계획·시험케이스를 만들거나 고치고, 재사용 도구는 `test/` 에 둔다. 결과서는 요약만 쓴다.
4. 마무리: odone_docs 가 반영 예정 문서를 대조하고 ADR·결정대기·TODO·index.json·WBS 진척·일정표 마일스톤을 갱신한 뒤 `plan_audit.py` rc=0 을 확인한다.

## 6. 템플릿 위치 (Tier 분리)

| 구분 | 위치 | 내용 |
|---|---|---|
| 범용 init 템플릿 | `.claude/skills/ocanon/templates/{plan,test,tools}/` | `plan_init.py` 가 복사하는 실파일 |
| 범용 주문형 템플릿 | `references/DOC_TEMPLATES_A.md`·`DOC_TEMPLATES_B.md` | 문서별 머리 정보와 최소 목차 |
| 프로젝트 고유 | 각 프로젝트 `plan/`, `.claude/docs_gate.json` 의 `canon` 설정 | 실제 문서 내용·경로 설정 |

- 범용 템플릿에는 프로젝트명·프로젝트 경로를 쓰지 않는다. 치환자는 `{{PROJECT}}`·`{{DATE}}` 만 쓴다.
- 다른 저장소의 실물 폴더와 카탈로그 키의 대응표는 범용 스킬이 아니라 그 프로젝트 문서(Tier 2)에 둔다.
