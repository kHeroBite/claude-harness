---
name: otestuiwinforms
description: "[alias] otest_winforms 래퍼 — 실제 로직은 otest_winforms가 보유. /otestuiwinforms 단독 호출 시 otest_winforms 위임."
invocation:
  user_callable: true
  pipeline_callable: true
  called_by: [otest, 사용자]
  calls: []
---

> **alias**: /otestuiwinforms 호출 시 Skill('otest_winforms') 위임. 실제 WinForms 테스트 로직은 otest_winforms가 보유.
> 파이프라인 내에서는 otest_ui가 직접 Skill('otest_winforms') 호출.
