---
name: odone_trans
description: "트랜스크립트 우회 패턴 감지. odone_review 전 실행. odone_hooks 전에 위치."
invocation:
  user_callable: false
  pipeline_callable: true
  called_by: [odone(Full o4/o5)]
  calls: []
---

# odone_trans — 트랜스크립트 우회 패턴 감지

odone_review에서 출력한 error md와 트랜스크립트를 기반으로 우회 패턴을 자동 감지.
review에서 발견하지 못한 논리적 위반(hook 우회, 강제 조작 등)을 트랜스크립트에서 찾아냄.

## 역할

```yaml
입력:
  - error md: $HOME/.claude/session-env/${UUID}/logs/errors.md
  - review_actions: $HOME/.claude/session-env/${UUID}/logs/review_actions.json (odone_review 출력)
출력:
  - error md에 "## 우회 패턴 감지" 섹션 추가
  - review_actions.json에 BYPASS_DETECTED 항목 추가
```

## 절차

### Step 1: error md 헤더에서 트랜스크립트 정보 추출

```yaml
절차:
  1. error md 읽기: $HOME/.claude/session-env/${UUID}/logs/errors.md
  2. 헤더에서 추출:
     - 트랜스크립트 경로: "- 트랜스크립트:" 라인에서 "#" 앞부분
     - 시작 라인: "#" 뒷부분 (숫자)
  3. 트랜스크립트 파일 존재 확인
```

### Step 2: 우회 패턴 grep

```yaml
대상: 트랜스크립트의 시작라인 이후만 검색 (이전 작업 노이즈 제외)

패턴_목록:
  1. pipeline_forge: "echo.*(IDLE|OK|PLAN|DEV|TEST|DONE|FINISH).*claude_pipeline_state_" — pipeline_state 수동 조작
  2. evidence_forge: "touch $HOME/.claude/session-env/${UUID}/evidence/.*_ok" — 테스트 증거 위조
  3. brute_force: 동일 명령어 5회+ 반복 (에러 무시하고 재시도)
  4. hook_disable: "--no-verify|SKIP_HOOK|NO_HOOK" — hook 비활성화 시도

검색_방법:
  - Grep 도구 사용: pattern="{패턴}", path="{트랜스크립트}", output_mode="content", offset={시작라인}
  - 또는 mcp__oio__bash_exec: tail -n +{시작라인} "{트랜스크립트}" | grep -nE "{패턴}"

오탐_필터:
  - hook 스크립트 자체의 코드 (echo "...pipeline_state" 등) → 도구 호출 컨텍스트 확인
  - 정상적인 prebuild_shutdown.sh에 의한 rm -f → 제외
```

### Step 3: 결과 기록

```yaml
매칭_있음:
  1. error md에 섹션 추가:
     ## 우회 패턴 감지
     | # | 패턴 | 라인 | 내용 |
     |---|------|------|------|
     | 1 | pipeline_forge | L1234 | echo IDLE > ... |

  2. review_actions.json에 항목 추가:
     {
       "id": "BYPASS-1",
       "what": "pipeline_forge 패턴 감지",
       "why": "트랜스크립트 L1234에서 pipeline_state 수동 조작",
       "severity": "높음",
       "level": 3,
       "target": "hook",
       "proposed_rule": "해당 패턴 물리 차단 필요"
     }

매칭_없음:
  출력: "✅ odone_trans: 우회 패턴 없음"
  → error md, review_actions.json 변경 없음
```

## 출력 형식

```
📋 odone_trans 결과:
- 우회 패턴: N건 감지 (또는 "없음")
- [패턴명] L라인: 간단 설명
- error md 업데이트: $HOME/.claude/session-env/${UUID}/logs/errors.md
```

## 금지
- error md 헤더 수정 (Step 3에서 끝부분에 섹션만 추가)
- 직접 코드 수정 (분석/기록만 담당)
- 프로젝트 고유 경로 사용 (범용 스킬)
