---
name: ocontext
description: "컨텍스트 새로고침 — /resume 또는 /compact 후 변경된 CLAUDE.md, PROJECT.md 등을 다시 읽어 반영. 수동 전용: 사용자가 '/ocontext'를 명시 호출할 때만 실행. 자동 트리거 금지."
---
# ocontext — 컨텍스트 새로고침

> /resume 또는 /compact 후 CLAUDE.md 등 핵심 문서가 변경되었을 때 다시 읽어 반영.
> 새 세션에서는 자동 로드되므로 불필요. **이전 세션 복원 시에만 유용.**

## 실행 절차

```
/ocontext 호출
  ↓
1. CLAUDE.md 읽기 (프로젝트 루트)
  ↓
2. PROJECT.md 읽기 (존재 시)
  ↓
3. 최근 변경된 스킬 감지 + 요약
  ↓
4. 변경 사항 요약 출력
```

### Step 1: CLAUDE.md 재로드
```bash
# 프로젝트 루트의 CLAUDE.md 전체 읽기
Read {프로젝트_루트}/CLAUDE.md  # 프로젝트_루트 = git rev-parse --show-toplevel
```
읽은 내용을 현재 컨텍스트의 규칙으로 채택한다.

### Step 2: PROJECT.md 재로드 (존재 시)
```bash
# PROJECT.md가 있으면 읽기
Read {프로젝트_루트}/PROJECT.md
# 문서 지도가 있으면 다시 읽기 (md 목록·역할·읽을 시점)
Read {프로젝트_루트}/.claude/rules/docs-map.md
```

### Step 2.5: INFRA.md 헤더·목차 재확인 (존재 시)

{git 루트}/INFRA.md 가 있으면 헤더(INFRA-FIELDS)와 목차만 읽는다. 없으면 생략한다.

```bash
# git 루트 확인
git rev-parse --show-toplevel  # 또는 mcp__oio__get_cwd
```

- 본문 전체는 읽지 않는다. 필요한 절은 작업 시점에 목차를 Grep 한 뒤 그 절만 읽는다.

### Step 3: 최근 변경 스킬 감지
```bash
# 최근 1시간 내 변경된 SKILL.md 파일 목록
find {프로젝트_루트}/.claude/skills/ -name "SKILL.md" -mmin -60 -type f
```
변경된 스킬이 있으면 description만 요약 출력 (전체 로드 불필요).

### Step 4: 변경 사항 요약
변경 감지 결과를 사용자에게 보고:
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🔄 ocontext: 컨텍스트 새로고침 완료
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
CLAUDE.md: ✅ 재로드 ({줄수}줄)
PROJECT.md: ✅/❌ ({상태})
변경 스킬: {N}개 ({목록})
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

## 주의사항
- 스킬 SKILL.md는 description만 확인 (전체 로드는 해당 스킬 호출 시 자동)
- hooks(.sh) 변경은 다음 도구 호출 시 자동 반영되므로 재로드 불필요
- settings.json 변경은 Claude Code 재시작 필요 (이 스킬로 반영 불가)
