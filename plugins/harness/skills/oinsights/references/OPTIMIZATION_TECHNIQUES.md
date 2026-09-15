# oinsights — 최적화 기법 상세

## 목차
- [Phase 0: 백업 실행 스크립트](#phase-0-백업-실행-스크립트)
- [Phase 1: 현황 분석 실행 스크립트](#phase-1-현황-분석-실행-스크립트)
- [축 C: SKILL.md 최적화 기법 (200줄+ 대상)](#축-c-skillmd-최적화-기법-200줄-대상)
- [축 D: LESSONS→CLAUDE/스킬/hook 이관 기법](#축-d-lessonsclaude스킬hook-이관-기법)

> **출처**: oinsights SKILL.md에서 분리. Phase 0 백업 스크립트 + Phase 1 분석 스크립트 + Phase 2 축C/축D 상세 기법.

---

## Phase 0: 백업 실행 스크립트

```bash
TS=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR=~/.claude/backups
mkdir -p "$BACKUP_DIR"

# CLAUDE.md (NTFS → ext4 백업)
cp "$(git rev-parse --show-toplevel)/CLAUDE.md" "$BACKUP_DIR/CLAUDE.md.${TS}"

# MEMORY 디렉토리 전체
MEMORY_DIR=$(find ~/.claude/projects/ -maxdepth 2 -name "MEMORY.md" -exec dirname {} \; | head -1)
for f in "$MEMORY_DIR"/*.md; do
  NAME=$(basename "$f")
  cp "$f" "$BACKUP_DIR/${NAME}.${TS}"
done

# LESSONS.md (NTFS → ext4 백업)
cp "$(git rev-parse --show-toplevel)/LESSONS.md" "$BACKUP_DIR/LESSONS.md.${TS}" 2>/dev/null

# SKILL.md (선택된 스킬만)
SKILLS_DIR="$(git rev-parse --show-toplevel)/.claude/skills"
for SKILL_NAME in {선택된_스킬_목록}; do
  cp "$SKILLS_DIR/$SKILL_NAME/SKILL.md" "$BACKUP_DIR/${SKILL_NAME}_SKILL.md.${TS}"
done

# 보관 정책 (각 PREFIX별 최신 3개)
for f in "$BACKUP_DIR"/*".${TS}"; do
  PREFIX=$(basename "$f" | sed "s/\.${TS}$//")
  ls -t "$BACKUP_DIR/${PREFIX}."* 2>/dev/null | tail -n +4 | xargs rm -f 2>/dev/null
done

echo "✅ 백업 완료: $BACKUP_DIR/"
ls -lh "$BACKUP_DIR/"*".${TS}" 2>/dev/null
```

---

## Phase 1: 현황 분석 실행 스크립트

```bash
# CLAUDE.md
wc -w "$(git rev-parse --show-toplevel)/CLAUDE.md"

# MEMORY
MEMORY_DIR=$(find ~/.claude/projects/ -maxdepth 2 -name "MEMORY.md" -exec dirname {} \; | head -1)
wc -w "$MEMORY_DIR"/*.md

# SKILL.md 전체
SKILLS_DIR="$(git rev-parse --show-toplevel)/.claude/skills"
find "$SKILLS_DIR" -name "SKILL.md" -exec wc -l {} + | sort -rn

# LESSONS.md
wc -w "$(git rev-parse --show-toplevel)/LESSONS.md"
```

---

## 축 C: SKILL.md 최적화 기법 (200줄+ 대상)

```yaml
C1_코드블록_압축:
  설명: 긴 bash/yaml 예시 코드 압축
  방법: 핵심만 남기고 부연 제거, 중복 예시 통합

C2_산문_구조화:
  설명: 장황한 설명 → YAML/테이블 압축
  방법: 산문체 문단 → 구조화된 key-value

C3_deprecated_정리:
  설명: 폐기된 규칙/히스토리/레거시 제거
  방법: "[폐기]", "더 이상 사용 안 함" 등 정리
  주의: 교훈이면 LESSONS.md로 이관

C4_조건부_로딩_분리:
  설명: 대형 스킬 → 메인 + 서브파일 분리
  방법: 핵심 로직(SKILL.md) + 상세 참조(같은 디렉토리 .md)
  형식: "> 상세: [파일명](./파일명)"

C5_반복_패턴_통합:
  설명: 여러 스킬에 동일하게 반복되는 패턴 통합
  방법: 공통 패턴 → CLAUDE.md 또는 상위 스킬로 승격
```

---

## 축 D: LESSONS→CLAUDE/스킬/hook 이관 기법

```yaml
D1_규칙화_완료_삭제:
  설명: CLAUDE.md 또는 SKILL.md에 이미 규칙으로 반영된 교훈 삭제
  방법: 각 교훈(L-NNN)과 CLAUDE.md/SKILL.md 규칙을 대조 → 일치하면 삭제
  기준: 해당 규칙이 "절대 규칙", "금지" 등으로 강제화되어 있으면 규칙화 완료

D2_hook_차단_완료_삭제:
  설명: hook 스크립트로 물리 차단된 교훈 삭제
  방법: hook 파일에서 해당 패턴 차단 로직 존재 확인 → 존재하면 삭제
  기준: settings.json에 등록된 hook이 해당 위반을 실시간 차단 중

D3_미규칙화_교훈_이관:
  설명: 아직 규칙/hook으로 반영 안 된 중요 교훈을 CLAUDE.md 또는 SKILL.md로 이관
  방법: 교훈 내용 분석 → 해당 스킬 SKILL.md 또는 CLAUDE.md 적절한 섹션에 규칙 추가
  기준: 2회+ 반복 또는 중요도 높은 교훈만 이관 (1회성은 삭제)

D4_1회성_삭제:
  설명: 특수 상황, 규칙화 불가능한 1회성 교훈 삭제
  방법: 재발 가능성 낮고, 특정 상황에만 해당하는 교훈 제거

D5_LESSONS_비우기:
  설명: 이관/삭제 완료 후 LESSONS.md 비우기
  정리_기준:
    삭제_대상:
      - 반영 추적 테이블에서 ✅ 완료이고, CLAUDE.md/SKILL.md/hook에 규칙으로 존재하는 교훈 → 본문 삭제
      - [폐기] 태그된 교훈 → 본문 삭제
      - 1회성 수정 (재발 가능성 없음) → 본문 삭제
    잔류_대상:
      - 컨텍스트 의존적 교훈 (특정 비즈니스 로직, 암호화 컬럼 등 규칙화 불가) → 유지
      - 아직 규칙화/hook화 안 된 교훈 → 유지 (이관 먼저)
    L번호_참조_처리:
      - CLAUDE.md/SKILL.md에서 (L-NNN) 참조 중인 교훈 삭제 시 → 참조 대상 파일의 규칙 자체는 이미 완전하므로 (L-NNN) 괄호 참조만 제거
      - 또는 LESSONS.md에 1줄 요약만 잔류: "### L-NNN: 제목 [이관됨→{대상파일}]"
  잔류_형식:
    - 헤더(교훈 기록 가이드라인) 유지
    - 반영 추적 테이블 유지 (이력 추적용)
    - 이관 불가 활성 교훈만 본문 유지
    - 이관된 교훈은 1줄 요약으로 축소 (L번호 + 제목 + [이관됨→대상])
```
