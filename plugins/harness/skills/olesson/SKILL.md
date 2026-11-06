---
name: olesson
description: "[alias] oinsights 래퍼 — 실제 로직은 oinsights가 보유. 교훈(LESSONS) 분석·정리 + 세션 분석 + 토큰 최적화 + 잔여 정리."
invocation:
  user_callable: true
  pipeline_callable: false
  called_by: [사용자]
  calls: [oinsights]
---
> **alias**: olesson은 단독 호출 편의용. 실제 로직은 oinsights가 보유.
> /olesson 단독 호출 시: Skill('oinsights') 위임.

# olesson — oinsights 래퍼

## 실행

```
Skill('oinsights')
```

모든 로직(과거 세션 마찰 분석, 컨텍스트 토큰 절감, LESSONS 정리, 잔여 정리)은 oinsights 본체가 보유.
교훈(lesson) 분석·정리를 쉽게 떠올려 호출하기 위한 별칭이다.
