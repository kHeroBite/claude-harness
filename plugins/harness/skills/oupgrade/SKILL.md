---
name: oupgrade
description: |
  외부 스킬팩(gstack, gsd 등) 설치 → 분석 → o스킬 이식 → 제거 통합 유틸리티.
  사용자가 '/oupgrade', '외부 스킬 이식', 'gstack 이식', 'gsd 이식' 요청 시 사용.
  수동 전용 — ok 파이프라인 밖에서 독립 실행.
invocation:
  user_callable: true
  pipeline_callable: false
  called_by: [사용자]
  calls: []
---

# oupgrade — 외부 스킬팩 분석/이식/제거

## 개요

외부 오픈소스 스킬팩을 임시 설치하고, o스킬 대비 분석한 뒤, 가치 있는 부분만 o스킬로 이식하고, 원본을 제거하는 통합 유틸리티.

## 지원 소스

| 소스 | 저장소 | 특징 |
|------|--------|------|
| **gstack** | `github.com/garrytan/gstack` | 브라우저QA, 보안감사, 디자인리뷰, 코드리뷰 |
| **gsd** | `github.com/gsd-build/gsd-2` | 컨텍스트 엔지니어링, 스펙 주도 개발, 서브에이전트 |
| **custom** | 사용자 지정 URL | 임의의 Claude Code 스킬 저장소 |

## 워크플로우 (5 Phase)

### Phase 1: 설치 (임시)

```yaml
설치_경로: ~/.claude/skills/{소스명}/   # 임시 — Phase 5에서 제거
방법: git clone (--depth 1 권장)
setup: 실행하지 않음 (빌드/바이너리 불필요 — SKILL.md 분석만 필요)
```

```bash
# gstack
git clone --depth 1 https://github.com/garrytan/gstack.git ~/.claude/skills/gstack

# gsd
git clone --depth 1 https://github.com/gsd-build/gsd-2.git ~/.claude/skills/gsd
```

이미 클론되어 있으면 스킵. `ls ~/.claude/skills/{소스명}` 확인.

### Phase 2: 스킬 인벤토리 수집

각 소스의 모든 SKILL.md를 읽고 인벤토리 생성:

```yaml
수집_항목:
  - 스킬명
  - description (frontmatter)
  - 핵심 워크플로우 (3줄 요약)
  - 핵심 기법/패턴 (차별화 요소)
  - allowed-tools
  - hooks (있으면)
```

**도구**: Read로 각 SKILL.md frontmatter + 핵심 섹션만 읽기 (전체 불필요).
**출력**: 인벤토리 테이블을 사용자에게 표시.

### Phase 3: o스킬 대비 갭 분석

인벤토리를 기존 o스킬 목록과 대조:

```yaml
분류_기준:
  이미_있음: o스킬이 동등/우위 기능 보유 → 스킵
  부분_보강: o스킬이 존재하나 외부가 추가 패턴 보유 → 기존 스킬 강화
  완전_신규: o스킬에 해당 영역 전무 → 신규 o스킬 생성 후보
  불필요: 우리 환경(WSL2/C#/WinForms)에 무관 → 스킵
```

**출력**: 갭 분석 테이블 + 이식 후보 목록을 사용자에게 제시.

```
| 외부 스킬 | 분류 | o스킬 대응 | 이식 가치 | 이식 형태 |
```

**사용자 확인**: 이식 후보 목록에서 실제 이식 대상을 사용자가 선택/확인.

### Phase 4: 이식 실행

사용자가 승인한 항목에 대해 이식 수행:

#### 4a. 신규 o스킬 생성

```yaml
절차:
  1. 외부 SKILL.md 원문 정독
  2. o스킬 규칙에 맞게 재작성:
     - 한국어 (기술 용어 제외)
     - frontmatter: name, description 필수
     - 우리 환경 특화 (WSL2/NTFS, C#/.NET, domain-fileops 준수)
     - ok 파이프라인 연동 가능성 명시 (auto-activates when 등)
  3. SKILL.md 작성 → NTFS rsync 방식으로 프로젝트 스킬 디렉토리에 배치
  4. 프로젝트의 skills 목록 문서에 등록
```

#### 4b. 기존 o스킬 강화

```yaml
절차:
  1. 외부 스킬의 차별화 패턴/규칙 추출
  2. 대상 o스킬 SKILL.md 읽기
  3. 추출한 패턴을 o스킬 규칙에 맞게 번역/통합
  4. NTFS rsync 방식으로 수정 반영
```

#### 4c. 이식 후 검증

```yaml
Phase 4 완료 후 필수:
  1. 수정된 SKILL.md를 Read로 전문 확인 (의도치 않은 삭제/손상 확인)
  2. 기존 스킬 기능 손상 없음 확인 (기존 워크플로우 흐름 보존)
  3. 새 섹션이 기존 흐름과 일관성 있는지 확인 (용어/구조/심각도 체계 통일)
```

#### 이식 시 절대 규칙

- 외부 SKILL.md를 그대로 복사하지 않음 — o스킬 문법/규칙으로 재작성
- 영어 → 한국어 변환 (기술 용어 제외)
- Bun/Node 의존 코드는 이식 대상에서 제외 (browse 데몬 등)
- gstack preamble(telemetry, session tracking, contributor mode) 제외
- NTFS 안전 절차 준수 (cp → Edit → rsync)

#### 이식 거부 체크리스트 (Phase 4 진입 전 필수)

하나라도 Yes → 거부 또는 변환 필수:
- [ ] Bun/Node/npm 의존 코드인가?
- [ ] 외부 SaaS 서비스(Greptile, Codex CLI 직접호출 등) 의존인가?
- [ ] 웹 프론트엔드 전용 패턴인가? (번들, Core Web Vitals, Rendering 등)
- [ ] o스킬 3원칙(증거기반/Hook차단/팀에이전트)과 충돌하는가?
- [ ] 기존 o스킬과 역할이 중복되는가?

### Phase 5: 정리 (제거)

```bash
rm -rf ~/.claude/skills/{소스명}
```

**사전 확인**: 이식 완료 여부를 사용자에게 확인 후 제거.

## 소스별 이식 가이드

### gstack 이식 우선순위

| 순위 | gstack 스킬 | 이식 형태 | 이유 |
|------|------------|----------|------|
| 1 | `/cso` (OWASP+STRIDE) | **ocso 신규** | 보안 감사 전무 |
| 2 | `/review` 적대적 리뷰 | **odev_review 강화** | adversarial 패턴 부재 |
| 3 | `/browse` @ref 시스템 | **참조만** | WSL2 제약, Bun 의존 |
| 4 | `/investigate` Iron Law | **참조만** | odebug에 이미 유사 |
| 5 | 나머지 | **스킵** | ok 파이프라인이 우위 |

### gsd 이식 우선순위

| 순위 | gsd 스킬 | 이식 형태 | 이유 |
|------|---------|----------|------|
| 1 | debug-like-expert 인지편향 경고 | **odebug 강화** | 인지편향 5대 경고 (확증/앵커링/가용성/자기코드맹점/매몰비용) |
| 2 | code-optimizer 앵커링 방지 원칙 | **odev_review 강화** | Pre-Quality Grep 스캔 (코드 읽기 전 패턴 검색) |
| 3 | code-optimizer C# 해당 도메인 패턴 | **odev_review 강화** | DB/메모리/동시성 3도메인 안티패턴 |
| 4 | 나머지 (프론트엔드/번들/디자인) | **스킵** | C#/.NET 환경 비해당 |

## 실행 모드

```yaml
기본: 대화형 (각 Phase에서 사용자 확인)
인수:
  /oupgrade              → 소스 선택부터 시작
  /oupgrade gstack       → gstack만 이식
  /oupgrade gsd          → gsd만 이식
  /oupgrade all          → gstack + gsd 순차 이식
  /oupgrade {url}        → 커스텀 저장소 이식
```
