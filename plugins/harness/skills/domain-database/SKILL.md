---
name: domain-database
description: "Database schema migration using MCP MySQL tools. Auto-activates when: creating/modifying tables, altering columns, managing indexes, migrating data, UTF-8 encoding issues. 데이터베이스 스키마 변경, 테이블 생성/수정, 컬럼 추가/삭제, 인덱스 관리, 마이그레이션 작업 시 자동 활성화. (project)"
invocation:
  user_callable: false
  pipeline_callable: true
  called_by: [odev(DB)]
  calls: []
---

# 데이터베이스 마이그레이션 자동화 Skill

이 Skill은 MCP MySQL 도구를 사용하여 프로젝트의 데이터베이스 스키마를 안전하게 변경하는 작업을 자동화합니다.

## 참고 문서

- **스키마 문서**: DATABASE.md (프로젝트별)
- **연결 정보**: oinfra_{project} 프로젝트스킬의 MCP 설정 참조

## 사용 시점

- 새 테이블 생성/삭제
- 컬럼 추가/삭제/변경
- 인덱스 생성/삭제
- Foreign Key 추가/삭제
- 대용량 데이터 INSERT/UPDATE

## 미완성 기능 감지 패턴 (L-408)

```yaml
문제: 테이블만 생성되고 참조 코드(INSERT/UPDATE)가 전혀 작성되지 않은 채 장기간 방치되는 경우가 존재
감지_3조건 (모두 충족 시 미완성 방치로 판정):
  1. mcp__mysql__list_tables 또는 get_schema로 테이블 존재 확인
  2. SELECT COUNT(*) FROM {테이블} → 0건
  3. 프로젝트 전체에서 해당 테이블명 grep → 참조 코드(INSERT/UPDATE/SELECT) 0건
조치: 3조건 모두 충족 시 별도 이슈로 등록하고 team-lead/사용자에게 보고 (임의 구현 금지, 설계 의도 확인 우선)
```

## 절대 원칙: MCP 도구 필수 사용

```bash
# 절대 금지
# Bash로 mysql 명령어 실행 금지
# mysqldump로 직접 백업/복원 금지
# SQL 파일을 mysql < file.sql로 실행 금지
```

### 필수 사용 도구

```yaml
mcp__mysql__query: SELECT 쿼리 실행 (읽기 전용)
mcp__mysql__execute: INSERT/UPDATE/DELETE/CREATE/ALTER/DROP 실행
mcp__mysql__get_schema: 테이블 스키마 확인
mcp__mysql__list_tables: 테이블 목록 조회
mcp__mysql__explain_query: 쿼리 실행 계획 분석
```

## 데이터베이스 구조

프로젝트별 DB 스키마(테이블 목록, 권한, 연결 정보)는 `oinfra_{project}` 또는 해당 프로젝트의 `DATABASE.md`를 참조하라.
범용 스킬에 특정 프로젝트 DB 구조를 기재하지 않는다 (3-tier 원칙).

## 6단계 마이그레이션 절차

1. **SQL 파일 작성**: SET NAMES utf8 + CREATE TABLE/ALTER
2. **MCP로 실행**: mcp__mysql__execute
3. **소스 코드 수정**: 쿼리/모델 업데이트
4. **DATABASE.md 업데이트**: 스키마 반영
5. **빌드 테스트**: dotnet build
6. **Git 커밋**: SQL 파일 포함

## UTF-8 인코딩 필수 정책

### 문제: Double Encoding
- MCP 기본 character_set_client: latin1
- 한글 데이터 손상 시 TRUNCATE 후 재삽입 필수

### 절대 금지
**MCP MySQL로 한글 INSERT/UPDATE 절대 금지** (latin1 연결). SELECT/영문만 허용.
한글 데이터 수정 방법: `{project}/PROJECT.md "코딩 규칙" 섹션` 참조.

### 해결: SET NAMES utf8 (필수)
```bash
# 1단계: UTF-8 인코딩 설정
mcp__mysql__execute("SET NAMES utf8")
# 2단계: INSERT/UPDATE 실행
mcp__mysql__execute("INSERT INTO {project}.{테이블} (...) VALUES (...)")
```

### HEX 검증
```bash
mcp__mysql__query("SELECT 컬럼, HEX(컬럼) FROM {project}.{테이블} WHERE ...")
```

## 주의사항

- 읽기 전용 계정은 SELECT만 가능, 쓰기 계정은 전체 권한 — DB별 권한 등급을 구분하라
- 한글 INSERT/UPDATE 전 반드시 SET NAMES utf8
- 예약어 컬럼 (read, write) → 백틱 필수
- NULL 처리: reader.IsDBNull 체크
- MCP는 자동 커밋/롤백 (수동 트랜잭션은 C# 코드에서)

## 체크리스트

- [ ] MCP 도구 사용 (Bash mysql 금지)
- [ ] SET NAMES utf8 실행
- [ ] SQL 파일 작성
- [ ] 소스 코드 수정
- [ ] DATABASE.md 업데이트
- [ ] 빌드 테스트
- [ ] HEX 바이트 검증
- [ ] Git 커밋
- [ ] 읽기 전용 DB vs 쓰기 가능 DB 권한 확인
- [ ] 백틱 사용 (예약어)

## 성능 최적화 패턴

### EXPLAIN 분석

```yaml
주요_지표:
  - Seq Scan: 전체 테이블 스캔 (대형 테이블에서 느림)
  - Index Scan: 인덱스 사용 (좋음)
  - Index Only Scan: 인덱스만 접근 (최고)
  - Cost: 예상 비용 (낮을수록 좋음)
  - Rows: 예상 행 수
사용: mcp__mysql__explain_query 도구 활용
```

### N+1 문제 해결

```yaml
Solution_1: JOIN으로 1번 쿼리
Solution_2: Batch query (WHERE id IN (...)) + Dictionary 매핑
감지: 반복문 안에서 SELECT 실행 패턴
```

### Cursor 페이지네이션 (OFFSET 대체)

```sql
-- OFFSET 100000 → 10만 행 스캔 후 버림 (느림)
-- Cursor → 마지막 위치부터 시작 (빠름)
SELECT * FROM table
WHERE (created_at, id) < (last_created_at, last_id)
ORDER BY created_at DESC, id DESC
LIMIT 20;
```

### 인덱스 전략

```yaml
B-Tree: 기본값, 등호/범위 쿼리
Partial_Index: WHERE status='active' 등 일부 행만
Expression_Index: LOWER(email) 등 함수 결과
Covering_Index: INCLUDE (컬럼들) 추가
안티패턴:
  - Over-indexing (INSERT/UPDATE/DELETE 느림)
  - LIKE '%abc%' (선행 와일드카드 인덱스 못 씀)
  - WHERE 절 함수 (인덱스 못 씀)
```
