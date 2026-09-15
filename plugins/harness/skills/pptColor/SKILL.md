---
name: pptColor
description: "PPTX 템플릿의 테마 색상을 변경하여 새 템플릿 파일을 생성한다. 색상 이름(red, blue 등) 또는 #RRGGBB hex 코드 직접 입력을 지원한다. hex 입력 시 주색을 기반으로 전체 팔레트를 자동 파생한다. 출력 파일명을 별도 지정할 수도 있다. 예: 'pptColor red blue', 'pptColor red #3EB489 mint'"
---

# pptColor — PPTX 테마 색상 교체

## 스크립트 실행

```bash
cd <프로젝트_루트>
python3 .claude/skills/pptColor/scripts/pptColor.py <소스> <대상> [출력명] [--template-dir template]
```

**예시**
```bash
# 팔레트 이름 사용
python3 .claude/skills/pptColor/scripts/pptColor.py red blue
# → red.pptx → blue.pptx

# hex 코드 사용 (출력 파일명 자동: 3eb489.pptx)
python3 .claude/skills/pptColor/scripts/pptColor.py red "#3EB489"

# hex 코드 + 출력 파일명 지정
python3 .claude/skills/pptColor/scripts/pptColor.py red "#3EB489" mint
# → red.pptx → mint.pptx
```

## 입력 형식

| 형식 | 예시 | 동작 |
|------|------|------|
| 팔레트 이름 | `red`, `blue` | 내장 팔레트 사용 |
| hex 코드 | `#3EB489`, `#0000FF` | 주색 기반 팔레트 자동 파생 |
| hex + 출력명 | `"#3EB489" mint` | 파생 팔레트 사용, 파일명은 mint |

## hex 입력 시 팔레트 자동 파생

주색(accent1)을 기준으로 나머지 색상을 자동 계산:

| 슬롯 | 파생 방법 |
|------|----------|
| accent1 | 입력 hex 그대로 |
| accent2 | accent1 밝기 125% |
| accent3 | accent1 밝기 80% |
| accent4 | 흰색과 55% 혼합 (밝은 배경) |
| accent5 | accent1 밝기 50% (어두운 강조) |
| accent6 | 흰색과 90% 혼합 (연한 배경) |
| dk2 | 검정과 25% 혼합 (짙은 배경) |
| lt2 | 흰색과 88% 혼합 (밝은 배경) |
| hlink | accent1과 동일 |
| folHlink | accent1 밝기 75% |

## 내장 팔레트

| 이름 | accent1 | 특성 |
|------|---------|------|
| red | #C0392B | 진한 빨강 |
| blue | #1A5276 | 네이비 블루 |
| green | #1E8449 | 포레스트 그린 |
| orange | #D35400 | 번트 오렌지 |
| purple | #6C3483 | 딥 퍼플 |
| teal | #148F77 | 청록 |
| yellow | #B7950B | 골드 옐로우 |
| pink | #E91E8C | 핫 핑크 |
| gray | #4D5656 | 차콜 그레이 |
| navy | #1B2A49 | 다크 네이비 |

## PPT 템플릿 작업 원칙 (필수 준수)

1. **표지 선택**: 표지를 만들 때는 `template/*.pptx`의 **1~10페이지(표지 샘플)** 중 내용/분위기에 가장 어울리는 **1개만** 선택하여 사용. 임의로 새 표지 레이아웃 생성 금지.
2. **본문 헤더 기준**: 새 레이아웃 추가 또는 새 폼 페이지 생성 시 반드시 **16페이지(본문 헤더 샘플)를 기준**으로 헤더(챕터명/제목/부제목) 구조를 유지하며, 콘텐츠 영역(y≥130pt)만 변경. 헤더 구조 임의 변경 금지.
3. **슬라이드 샘플 매칭**: 새 PPT 생성 시 **17페이지 이후의 본문 레이아웃 샘플**(1~10=표지, 11~15=목차, 16=본문헤더샘플, 17~끝=본문레이아웃)에서 슬라이드 목적·구조에 가장 어울리는 레이아웃을 찾아 적용. 임의로 새 레이아웃을 처음부터 디자인하지 말고 기존 샘플에서 가장 근접한 것을 선택하라.

## 주의사항

- 소스 파일(`{색상}.pptx`)이 없으면 에러 종료
- 대상 파일이 이미 있으면 덮어씀
- 레이아웃·폰트·슬라이드 구조 변경 없음
- 외부 라이브러리 불필요 (Python 표준 라이브러리만 사용)

## 변환 방식 (중요)

**hue 회전 전용** — `replace_color_scheme()` 미사용

소스 파일의 `ppt/theme/theme1.xml`에서 **accent1의 실제 srgbClr**을 읽어 src_hue를 자동 감지.
팔레트 정의의 `hue` 필드는 src_hue로 사용하지 않음 (소스 파일의 실제 색상과 다를 수 있음).

| 동작 | 결과 |
|------|------|
| src_hue ±40° 이내 색상 | 대상 hue로 회전 |
| src_hue ±40° 초과 색상 | **보존** (다색 테마의 보조 색상 유지) |
| 채도 < 0.12 (무채색) | **보존** (흰색/검정/회색 계열) |

**재발방지**: `replace_color_scheme()`은 다색 테마(Office 기본 등)의 모든 accent 슬롯을
단색 팔레트로 덮어써 시각적 요소 유실을 초래한다. 절대 사용 금지.

## 자연어 색상 지시어 (대상 파라미터)

두 번째 파라미터에 hex/이름 대신 자연어 조작 지시어를 사용할 수 있다.
소스 파일의 accent1 색상을 기준으로 자동 조작하여 팔레트를 파생한다.

```bash
python3 .claude/skills/pptColor/scripts/pptColor.py red "좀더어둡게" darkred
python3 .claude/skills/pptColor/scripts/pptColor.py red "많이밝게" lightred
python3 .claude/skills/pptColor/scripts/pptColor.py red "선명하게" vivid
```

| 지시어 | 효과 | 강도 |
|--------|------|------|
| 좀어둡게 / 어둡게 / 좀더어둡게 / 더어둡게 / 많이어둡게 | V(밝기) 감소 | 약→강 |
| 좀밝게 / 밝게 / 좀더밝게 / 더밝게 / 많이밝게 | V(밝기) 증가 | 약→강 |
| 선명하게 / 채도높게 / 더선명하게 | S(채도) 증가 | 약→강 |
| 탁하게 / 채도낮게 / 더탁하게 | S(채도) 감소 | 약→강 |
| 따뜻하게 / 더따뜻하게 | hue −20°/−35° | - |
| 차갑게 / 더차갑게 | hue +20°/+35° | - |
| dark / darker / darkest | 영문 동의어 | 약→강 |
| light / lighter / lightest | 영문 동의어 | 약→강 |
