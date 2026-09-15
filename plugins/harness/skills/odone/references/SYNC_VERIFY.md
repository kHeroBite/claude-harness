# 공용 리소스 동기화 검증 (odone_cleanup 내 실행)

> 공용 로직(스킬/hook/MCP/CLAUDE.md) 변경 시 모든 프로젝트에 적용되었는지 검증.

```yaml
시점: odone_cleanup 서브스킬 내 (코드 정리 완료 후, Lock 해제 전)
조건: 이 세션에서 공용 리소스를 수정한 경우에만 실행

공용_리소스_정의:
  공용_스킬: ~/.claude/skills/ 내 범용 스킬 (ok, oplan, odev, otest, odone 등)
  공용_hook: ~/.claude/hooks/ 내 모든 .sh 파일
  공용_설정: ~/.claude/settings.json, ~/.claude/settings.local.json
  프로젝트_CLAUDE_md: /mnt/c/work/{ProjA,ProjB,ProjC}/CLAUDE.md (하드링크)
  프로젝트_스킬: /mnt/c/work/{ProjA,ProjB,ProjC}/.claude/skills/ 내 범용 스킬 (하드링크)

검증_항목:

  1_스킬_하드링크_검증:
    대상: 이 세션에서 수정된 범용 스킬
    방법: stat --format="%i" 로 3개 프로젝트의 inode 비교
    PASS: 모든 프로젝트의 inode 동일
    FAIL: inode 불일치 → 하드링크 재연결 필요
    자동_수정: ln 명령으로 재연결

  2_hook_존재_검증:
    대상: 이 세션에서 생성/수정된 hook 파일
    방법: ls -la ~/.claude/hooks/{hook명} 존재 + 실행 권한 확인
    PASS: 파일 존재 + chmod +x
    FAIL: 파일 누락 또는 실행 권한 없음

  3_settings_등록_검증:
    대상: 이 세션에서 수정된 hook의 settings.json 등록 여부
    방법: jq로 settings.json에서 해당 hook 명령어 검색
    PASS: matcher + command 등록 확인
    FAIL: settings.json에 미등록 → 등록 누락

  4_CLAUDE_md_하드링크_검증:
    대상: CLAUDE.md 변경 시
    방법: stat --format="%i" 로 3개 프로젝트의 CLAUDE.md inode 비교
    PASS: 모든 프로젝트의 inode 동일
    FAIL: inode 불일치 → 하드링크 재연결

리포트_형식: |
  🔗 **공용 리소스 동기화 검증**
  ┌────────────────────────────────────────┐
  │ 리소스               │ 상태 │ 프로젝트 │
  ├──────────────────────┼──────┼──────────┤
  │ {스킬/hook/설정 이름}│ ✅/❌│ ProjA,ProjB,ProjC│
  └──────────────────────┴──────┴──────────┘

FAIL_시_자동_수정:
  스킬_하드링크: ln 명령으로 누락 프로젝트에 연결
  hook_권한: chmod +x 자동 실행
  settings_등록: 사용자에게 등록 누락 경고 (자동 수정은 위험)

스킵_조건: 이 세션에서 공용 리소스 미수정 시 전체 스킵 (불필요한 검증 방지)
```
