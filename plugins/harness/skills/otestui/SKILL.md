---
name: otestui
description: "[alias] otest_ux 래퍼 — 실제 로직은 otest_ux가 보유."
invocation:
  user_callable: true
  pipeline_callable: true
  called_by: [otest, 사용자]
  calls: [otest_ux]
---
> **alias**: otestui는 단독 호출 편의용. 실제 UX 테스트 로직은 otest_ux가 보유.
> 파이프라인 내에서는 otest_ui가 직접 Skill('otest_ux') 호출.
> /otestui 단독 호출 시: Skill('otest_ux') 위임.

# otestui — otest_ux 래퍼

## 실행

```
Skill('otest_ux')
```

모든 UX 테스트 로직(삼각검증, 스크린샷 분석, REST API, 로그 분석)은 otest_ux 본체가 보유.
프로젝트별 설정은 `oinfra_{project}`의 `test_env` 섹션에서 로드.
