---
name: pptClone
description: >
  소스 PPTX의 디자인(헤더/배경/테마)으로 타겟 PPTX를 완전 교체. 타겟의 텍스트 콘텐츠는 보존하고
  소스의 레이아웃/색상/헤더 구조를 이식한다. 슬라이드 유형(표지/목차/본문)은 자동 분류.
  호출: pptClone <소스> <타겟> [출력명]
  예: 'pptClone red KB_AI', 'pptClone red KB_AI KB_AI_red'
---

# pptClone — PPTX 디자인 완전 교체

## 스크립트 실행

```bash
cd <프로젝트_루트>
python3 .claude/skills/pptClone/scripts/pptClone.py <소스> <타겟> [출력명] [--template-dir template]
```

**예시**
```bash
# 기본 (출력: template/KB_AI_cloned.pptx)
python3 .claude/skills/pptClone/scripts/pptClone.py red KB_AI --template-dir template

# 출력 파일명 지정
python3 .claude/skills/pptClone/scripts/pptClone.py red KB_AI KB_AI_red --template-dir template
```

## 동작 방식

각 타겟 슬라이드를 **COVER / TOC / CONTENT** 로 자동 분류 후:

| 유형 | 소스에서 선택 | 처리 |
|------|-------------|------|
| COVER | 소스 1~10p (표지 샘플) 중 첫 번째 | 소스 헤더 + 타겟 본문 합성 |
| TOC | 소스 11~15p (목차 레이아웃) 중 첫 번째 | 소스 헤더 + 타겟 본문 합성 |
| CONTENT | 소스 17p~ 본문 레이아웃 중 구조 유사도 최고 | 소스 헤더 + 타겟 본문 fit |

**합성 규칙:**
- 소스 헤더 영역 (y < 130pt): 챕터명/제목/부제목 구조 그대로 이식
- 타겟 본문 영역 (y ≥ 130pt): `fit_body_to_region()`으로 TARGET 영역에 비례 배치
- 소스 테마(theme1.xml) 복사 → 색상 팔레트 이식

## 소스 템플릿 페이지 구조

```
1~10p   표지 샘플        — COVER 타입 슬라이드에 적용
11~15p  목차 레이아웃    — TOC 타입 슬라이드에 적용
16p     본문 헤더 샘플   — 헤더 구조 기준
17p~끝  본문 레이아웃    — CONTENT 타입 슬라이드에 적용 (구조 유사도 매칭)
```

## 슬라이드 유형 분류 기준

| 기준 | COVER | TOC | CONTENT |
|------|-------|-----|---------|
| 첫 슬라이드 | ✓ | - | - |
| 목차 키워드 (목차/contents/agenda) | - | ✓ | - |
| sp ≤ 3 & 텍스트 < 100자 | ✓ | - | - |
| 이미지 많고 텍스트 거의 없음 | ✓ | - | - |
| 그 외 | - | - | ✓ |

## fit_body_to_region 상수

```
TARGET 영역 (EMU):
  X = 190500  (~15pt)
  Y = 1778000 (~140pt)
  W = 11811000 (~930pt)
  H = 4889500  (~385pt)

scale ≤ 1.0 (축소만, 확대 없음)
폰트 비례 축소, 최소 800(8pt)
```

## 주의사항

- 소스/타겟 파일이 없으면 에러 종료
- 출력 파일이 이미 있으면 덮어씀
- 구조 유사도 매칭은 소스 본문 슬라이드 최대 20개만 비교 (성능)
- 타겟 본문 sp가 없는 슬라이드는 타겟 전체 sp를 본문으로 처리
- 소스 테마(theme1.xml) 전체 교체 → pptColor와 조합 불필요

## PPT 템플릿 작업 원칙 (필수 준수)

1. **표지 선택**: 표지를 만들 때는 소스 파일의 **1~10페이지(표지 샘플)** 중 내용/분위기에 가장 어울리는 **1개만** 선택. 임의로 새 표지 레이아웃 생성 금지.
2. **본문 헤더 기준**: 새 레이아웃 추가 또는 새 폼 페이지 생성 시 반드시 **16페이지(본문 헤더 샘플)를 기준**으로 헤더(챕터명/제목/부제목) 구조를 유지하며, 콘텐츠 영역(y≥130pt)만 변경.
3. **슬라이드 샘플 매칭**: 새 PPT 생성 시 **17페이지 이후의 본문 레이아웃 샘플**에서 슬라이드 목적·구조에 가장 어울리는 레이아웃을 찾아 적용. 임의로 새 레이아웃을 처음부터 디자인 금지.
