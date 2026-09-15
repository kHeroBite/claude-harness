# EVIDENCE_FILES.md — 파이프라인 증거 파일 목록

> 출처: ok/SKILL.md

## 증거 파일 경로

| 파일 | 생성 시점 | 검증 주체 | 용도 |
|------|---------|---------|------|
| `$HOME/.claude/session-env/${UUID}/evidence/build_ok` | obuild 성공 후 | orun | 빌드 성공 Gate |
| `$HOME/.claude/session-env/${UUID}/evidence/deploy_ok` | orun 성공 후 | otest_make | 배포 성공 Gate |
| `$HOME/.claude/session-env/${UUID}/evidence/run_ok` | orun 헬스체크 통과 후 | otest_infra | 구동 성공 Gate |
| `$HOME/.claude/session-env/${UUID}/evidence/app_restarted` | orun UI자동화 프로젝트 재시작 후 | otest_ui | UI 자동화 사전 조건 |
| `$HOME/.claude/session-env/${UUID}/evidence/make_ok` | otest_make 성공 후 | otest_verify | Backend 검증 통과 |
| `$HOME/.claude/session-env/${UUID}/evidence/make_ok_skipped` | otest_make 스킵 시 | otest_verify | Backend 검증 해당 없음 |
| `$HOME/.claude/session-env/${UUID}/evidence/ui_test_done` | otest_ui 성공 후 | otest_verify | Frontend 검증 통과 |
| `$HOME/.claude/session-env/${UUID}/evidence/ui_test_done_skipped` | otest_ui 스킵 시 | otest_verify | Frontend 검증 해당 없음 |
| `$HOME/.claude/session-env/${UUID}/evidence/log_analysis_ok` | otest_log 분석 완료 후 | otest_infra/otest_verify | 로그 분석 완료 Gate |
| `$HOME/.claude/session-env/${UUID}/evidence/log_analysis.json` | otest_log 분석 완료 후 | odone_review | 로그 분석 상세 결과 |
| `$HOME/.claude/session-env/${UUID}/evidence/otest_done` | otest 완료 후 | otest_done_guard.sh | odone 진입 허가 |
| `$HOME/.claude/session-env/${UUID}/rollback_hash` | odev 진입 시 | odone (필요 시) | 체크포인트 해시 |
| `$HOME/.claude/session-env/${UUID}/state` | 각 단계 진입 시 | pipeline_order_guard.sh | 파이프라인 상태 |
| `$HOME/.claude/session-env/${UUID}/logs/errors.md` | 오류 발생 시 | odone_review | 오류 추적 |
| `$HOME/.claude/session-env/${UUID}/logs/reroute_context.md` | 역라우팅 시 | 재spawn 에이전트 | 실패 맥락 전달 |
| `$HOME/.claude/session-env/${UUID}/logs/reroute_history.json` | 역라우팅 발생 시마다 | odone_review | 역라우팅 이력 누적 |

## 생명주기
- UUID 디렉토리: ofinish Step 6에서 `mcp__oio__dir_delete(recursive=true)` 일괄 삭제
- 개별 파일: 파이프라인 완료 시 자동 정리
