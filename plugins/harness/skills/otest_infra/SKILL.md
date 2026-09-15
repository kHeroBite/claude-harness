---
name: otest_infra
description: "Phase 1 인프라 검증 라우터 — 빌드+배포+로그. otest에서 1차로 호출. 빌드되고 실행되는지 확인."
invocation:
  user_callable: false
  pipeline_callable: true
  called_by: ["otest"]
  calls: ["otest_build", "otest_run", "otest_log"]
---

# otest_infra — Phase 1 인프라 검증

## 역할

"빌드되고 실행되나?" — 인프라 레벨 검증

## 실행 순서

1. **Skill('otest_build')** — 빌드 (프로젝트별 oinfra_{project} 빌드 섹션)
   - 증거: evidence/build_ok (exit_code=0, build_log_hash)
   - 실패 → odev 역라우팅 권고 반환

2. **Skill('otest_run')** — 배포+헬스체크 (프로젝트별 oinfra_{project} 배포 섹션)
   - 증거: evidence/deploy_ok, evidence/run_ok
   - 실패 → odev 역라우팅 권고 반환

3. **Skill('otest_log')** — 빌드/구동 로그 분석 (ERROR/WARN)
   - 증거: evidence/log_analysis_ok
   - 실패 → 경고 + 계속 진행

## 결과

- 전부 PASS → "otest_infra PASS" 반환
- FAIL → 실패 상세 + 역라우팅 권고 반환

## tier별 적용

```yaml
o2: obr(otest_build+otest_run 동시)으로 대체
o3+: 전체 실행
```
