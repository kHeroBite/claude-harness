---
name: domain-context7
description: "Real-time library documentation via Context7 MCP. Auto-activates when: new library, version upgrade, Breaking Changes. 실시간 라이브러리 문서, 버전 업그레이드."
invocation:
  user_callable: false
  pipeline_callable: true
  called_by: [odev(라이브러리)]
  calls: []
---

# Context7 Library Documentation Skill

Context7 MCP 서버를 사용하여 최신 라이브러리 문서를 실시간으로 조회하고, 정확한 코드 예시를 제공합니다.

## 사용 시점

- **새로운 라이브러리 사용**: Entity Framework Core, Dapper, LiveCharts2 등
- **NuGet 패키지 추가**: 설치 후 사용법 확인
- **버전 업그레이드**: Breaking Changes 확인
- **복잡한 기능 구현**: 공식 예시 참조

## 도구

### 1. resolve-library-id
라이브러리 이름 -> Context7 호환 ID 변환 (get-library-docs 전 필수)

### 2. get-library-docs (query-docs)
특정 라이브러리의 최신 문서 및 코드 예시 조회

## 사용 방법

### 명시적 요청
```
use context7: Entity Framework Core에서 트랜잭션 처리 방법
```

### 자동 조회 (권장)
라이브러리 언급 시 자동으로 최신 문서 참조

## 지원 라이브러리

### C# / .NET
Entity Framework Core, ASP.NET Core, Dapper, MySql.Data, Newtonsoft.Json, AutoMapper, LiveCharts2

### Python
pandas, numpy, flask, django, requests

### JavaScript/TypeScript
react, vue, express, axios

## 베스트 프랙티스

- 라이브러리 버전 명시 (예: "EF Core 8.0")
- 구체적 질문 (예: "SaveChanges 실패 시 롤백")
- 코드 예시 포함 요청
- 프로젝트 내부 코드에는 사용 불가 (외부 라이브러리만)

## 주의사항

- 인터넷 연결 필수
- 첫 호출 2-3초 / 캐싱 후 즉시
- 마이너/비공개 라이브러리 미지원
- 최신 버전 기본, 구버전 시 명시

## 체크리스트

- [ ] resolve-library-id 확인
- [ ] get-library-docs 조회 성공
- [ ] 코드 예시 포함
- [ ] 최신 버전 확인
