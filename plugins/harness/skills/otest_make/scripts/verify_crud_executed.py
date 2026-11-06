# CRUD 검수 항목이 실제로 저장 경로를 태웠는지 증거로 검증하여 PASS 마킹을 물리적으로 거부하는 게이트
#
# 배경 (사이클30 실패):
#   otest 가 T3 를 "전필드 DB일치 · PASS" 로 판정했으나 실제 저장 경로를 태우지 않았다.
#   삭제 가드(차단)만 확인하고 추가/수정은 "운영 데이터 보호"를 이유로 건너뛴 것이다.
#   그 결과 반쪽 저장(정본만 저장되고 부가 축 누락)이 실사용에서 즉시 드러났다.
#
# 핵심 원칙:
#   "차단 확인"은 저장 검증이 아니다.
#   차단은 아무것도 일어나지 않는 것을 보는 것이고, 저장은 일어나는 것을 봐야 한다.
#   "운영 데이터 보호"는 검증 면제 사유가 아니라 개발 DB 를 사용해야 할 사유다.
#
# 사용법:
#   python3 verify_crud_executed.py --uuid <PIPELINE_UUID>
#   python3 verify_crud_executed.py --criteria <path> --evidence <path>
#
# 종료코드:
#   0 = 통과 (CRUD 항목이 없거나, 모든 CRUD 항목이 실행 증거를 갖춤)
#   1 = MISSING_CRUD_EVIDENCE — PASS 마킹 거부
#   2 = 입력 오류 (파일 부재/파싱 실패) — 게이트 자체가 돌지 않은 것이므로 통과가 아니다

import argparse
import json
import os
import re
import sys

# 검수문에 아래 키워드가 있으면 CRUD 항목으로 간주한다 (category 미기재 대비 폴백).
CRUD_KEYWORDS = [
    "저장", "등록", "수정", "추가", "삭제", "입력", "생성", "변경", "갱신",
    # 저장 결과를 수치로 표현한 검수문도 CRUD 다 — 동사가 없어도 놓치면 안 된다.
    "COUNT", "count", "레코드", "행수", "INSERT", "UPDATE", "DELETE", "반영",
]

# 2026-10-10 conv_179160716700 (R2): "무변경" 의 "변경" 처럼 부정 복합어 속 부분문자열이 CRUD 로 잡히던 오탐.
#   is_crud_item 은 아래 고정 복합어만 지운 뒤 CRUD_KEYWORDS 를 매칭한다. 목록 확장 시 부정 의미가
#   확정된 복합어만 넣는다("삭제하지 않" 등은 의도적으로 제외 — 넣지 않으면 CRUD 쪽으로 남아 안전하다).
NEGATED_COMPOUNDS = [
    "무변경", "미변경", "변경되지 않", "변경 없", "변경없", "삭제되지 않", "수정되지 않", "수정 없",
]

# category 가 명시된 경우의 CRUD 판정값.
CRUD_CATEGORIES = {"crud", "db", "backend"}

# "차단만 확인" 을 저장 검증으로 오인하지 않기 위한 신호.
# 이 표현만 있고 실행 증거가 없으면 그것이 바로 사이클30 의 실패 형태다.
GUARD_ONLY_HINTS = ["차단", "가드", "막힘", "거부", "금지"]


# ─────────────────────────────────────────────────────────────────────────────
# ★검증형 AC 예외축★ (사이클32 G-1 — 위양성 수정)
# ─────────────────────────────────────────────────────────────────────────────
#
# 무엇이 문제였나 (2026-08-24 실측):
#   category="backend" 를 CRUD 로 간주(CRUD_CATEGORIES)하는데, 사이클32 의
#   AC-01/02/03/08 은 전부 backend 이면서 ★저장 경로가 아예 없는 검증형★ 이다.
#     AC-01  "UI 스레드 DB 조회 ★제거★ 확인"   → verify: grep 결과에 해당 라인 없음
#     AC-02  "실패 분기 + Log4.Error ★존재★"   → verify: 코드상 분기 존재 확인
#     AC-03  "다른 차트 ★무변경★ (Surgical)"    → verify: git diff hunk 범위
#     AC-08  "환경을 ★데이터로 판별★"          → verify: 로그에 판정 근거 수치
#   ⇒ 저장할 것이 없는 항목에 저장 증거를 요구하니 ★영원히 통과 불가★ 다.
#   ⇒ 게다가 같은 사이클의 ★AC-07 이 "운영 쓰기 0건"을 명시 요구★ 하므로,
#     저장을 태우는 것은 요구사항과 정면 충돌한다.
#
# 어떻게 고치지 ★않을★ 것인가 (중요):
#   ❌ AC 의 category 를 바꾼다      → 기준을 결과에 맞춰 바꾸는 것 = 게이트 무력화
#   ❌ 증거가 없으면 통과시킨다      → 게이트가 껍데기가 된다. 사이클30 재발
#   ✅ ★AC 자체가 저장을 요구하는가★ 를 본다 — 요구하지 않는 항목만 면제한다
#
# 판정 기준:
#   "저장을 요구하는 동사"가 검수문에 ★있으면 예외 아님★(=CRUD 유지).
#   그런 요구가 없고, ★검증 수단이 코드/로그/diff 확인★ 임이 드러나면 검증형으로 본다.
#   ⇒ 즉 ★기본이 CRUD★ 이고 예외는 좁게 연다. 애매하면 CRUD 로 남긴다(fail-safe).

# 저장을 실제로 요구하는 표현. 하나라도 있으면 ★예외 대상이 아니다★.
WRITE_DEMAND_HINTS = [
    "저장", "등록", "입력", "생성", "삽입", "반영", "커밋",
    "INSERT", "UPDATE", "DELETE", "insert", "update", "delete",
    "COUNT 변화", "count 변화", "행수 변화", "+1", "증가", "감소",
    "before", "after",  # count_before/after 류를 요구하는 검수문
]

# ─────────────────────────────────────────────────────────────────────────
# ★INSPECTION_HINTS 어휘 커버리지 한계 — 해소 불가 확정 판정★ (사이클49, L-4xx)
# ─────────────────────────────────────────────────────────────────────────
# 증상: "cat settings.json 으로 hook 항목 존재 확인" 같은 정상 검증형 AC 가
#   지침 어휘(grep/git diff/코드상 등)를 벗어나면 과잉 차단된다.
#
# 판정: 해소 불가 — 어휘 확장(예: "확인" 추가) 금지.
#   "확인"은 저장 검증형 AC 와 CRUD 요구 AC 의 verify 문구 양쪽에 공통으로
#   등장하는 범용 동사다. 추가하는 순간 진짜 CRUD AC(예: "저장 후 DB 조회로
#   확인한다")까지 검증형으로 오판되어 증거 요구가 면제된다 — 회피 통로가
#   열린다(F-CRUD-1 이 막으려던 것과 정확히 같은 형태).
#
# 근본 해법은 이미 존재한다: item_crud 구조화 필드(사이클45~48, L-465~469).
#   oplan 이 AC 작성 시점에 검증형 항목에 item_crud:false 를 명시하면
#   이 자연어 어휘 분석 자체를 우회하고, 그 선언은 is_non_crud_declared() 의
#   path/content 교차검증(L-467)으로 거짓 선언까지 방어된다.
#   ⇒ 남은 과제는 verify_crud_executed.py 의 결함이 아니라 oplan_normal 의
#     AC 작성 관행(검증형 항목에 item_crud:false 명시)이다.
#
# 재시도 금지 근거: L-466 — 정규식 절 경계 추정으로 자연어 판정을 3회
#   조정했으나 분리자를 좁히면 회피가 열리고 넓히면 오탐이 부활하는
#   트레이드오프가 매번 재현됐다. 새 어휘/새 조건부 매칭 규칙 추가도
#   동일 구조의 실패를 반복할 위험이 크므로 시도하지 않는다.
# 저장 없이 "확인"으로 끝나는 검증 수단. 이것이 verify 축이면 검증형이다.
INSPECTION_HINTS = [
    "grep", "git diff", "diff ", "코드상", "코드 상", "소스", "정적",
    "존재하지 않는다", "없음", "무변경", "변경되지 않", "빌드 로그",
    "로그에", "판정 근거", "스크린샷", "커버리지", "표기", "구분 표",
]

# ─────────────────────────────────────────────────────────────────────────────
# ★부정/검증 맥락 무력화★ (F-CRUD-1 과잉 차단 회귀 수정)
# ─────────────────────────────────────────────────────────────────────────────
#
# 무엇이 문제였나 (otest 실측):
#   "저장 로직을 건드리지 않았음을 코드상 확인한다" 같은 AC 는
#   WRITE_DEMAND_HINTS 의 "저장" 이 있다는 이유만으로 demand_blob 판정에서
#   즉시 False(=CRUD 유지) 로 확정되어, 뒤의 INSPECTION_HINTS 검사 자체가
#   실행되지 못하고 차단됐다. 인프라/hook 수정 작업의 AC 에서
#   "~을 건드리지 않았음을 확인" 표현은 흔한데 이게 막히면
#   F-CRUD-1 이 원래 해소하려던 교착이 다른 형태로 재발한다.
#
# 어떻게 고쳤나:
#   WRITE_DEMAND_HINTS 매칭을 "문장 단위" 로 좁힌다. 매칭된 히트가 속한
#   문장(마침표/개행 분리) 안에 한국어 부정 표현이 함께 있으면
#   그 히트는 "저장 요구"로 세지 않는다 — 부정문은 저장 요구가 아니라
#   저장을 하지 않았다는 진술이기 때문이다.
#   다른 문장에 부정 표현 없는 진짜 CRUD 요구가 있으면 그 문장의 히트가
#   여전히 살아있으므로 fail-safe(애매하면 CRUD 유지)는 그대로 유지된다.
#
# 왜 새 상수 최소화: INSPECTION_HINTS 의 "변경되지 않" 처럼 이미 검증형
# 맥락 어휘가 존재하나, "저장"/"등록" 등 일반 동사 뒤에 붙는 부정형은
# 활용형이 다양해(건드리지 않았음/저장하지 않는다/저장 없음 등) 전용
# 부정 표현 목록을 별도로 둔다. 최소 5개만 추가한다.
NEGATION_HINTS = ["않았", "않는다", "없음", "말아야", "건드리지"]


def _split_sentences(text):
    """절(clause) 경계로 문자열을 분리한다.

    ★F-CRUD-1 회피 통로 수정★ (2026-08-29, verify_crud_executed 재발방지):
      기존에는 마침표/느낌표/물음표/개행만 경계였다. 그런데 한국어 AC 는
      "사용자를 저장한다; 기존 코드는 건드리지 않는다" 처럼 ★독립된 두 절★ 을
      쉼표/세미콜론/콜론/하이픈/괄호로 이어 쓰는 문체가 더 자연스럽다.
      이 경우 두 절이 한 "문장" 으로 묶여 뒷절의 부정어(NEGATION_HINTS)가
      앞절의 진짜 CRUD 요구(WRITE_DEMAND_HINTS)까지 통째로 무력화했다.
      ⇒ 분리자에 쉼표(,) 세미콜론(;) 콜론(:) 하이픈/대시(- —) 괄호를 추가한다.

    왜 이 정도로 충분한가 (오탐 부활 방지 근거):
      "세션 상태 저장 함수는 수정하지 않았으며 기존 동작 그대로임을 코드상 확인" 같은
      정상 부정문은 주어(저장 함수는)와 부정 서술어(수정하지 않았으며) 사이에
      ★쉼표 등 구두점이 없다★ — 하나의 연속된 서술 구조이기 때문이다.
      반면 회피 통로 재현 5건은 전부 두 절 사이에 쉼표류 구두점이 있다
      ("; " ", " ": " " - " 괄호). 즉 ★구두점 유무가 절 경계의 자연스러운 신호★ 이며,
      한국어 연결어미("며/고/되" 등) 자체를 분리자로 추가하지 않는다 — 어미 분리는
      "수정하지 않았으며" 처럼 부정어 내부의 어미까지 끊어 과잉분리를 유발하고,
      정상 부정문(위 대조군)의 주어-서술어 결합을 파괴해 오탐을 되살릴 위험이 크다.
      실측 검증(균형 조건 A·B 12건 전수)으로 구두점 확장만으로 양쪽 다 충족함을 확인했다.
    """
    return [s for s in re.split(r"[.!?\n,;:\-—()]", text) if s.strip()]


def _declares_inspection(item):
    """AC 항목이 ★명시 필드★ verify_kind:"inspection" 으로 검증형임을 선언했는가.

    ★사이클172 C25 — F-CRUD-1 오탐 ⑰-②★:
      조회·정적 검증 항목이 INSPECTION_HINTS 어휘 밖의 문장("게이트 rc=0" 등)을 쓰면
      CRUD 로 오분류됐다. 위 판정 기록대로 어휘 확장은 금지다 — 대신 AC 작성자가
      ★검증 방법 자체★ 를 구조화 필드로 못박게 한다. 자연어보다 이 필드를 먼저 본다.
    ★모순 선언은 CRUD 쪽이 이긴다★: item_crud:true 와 함께 쓰면 검증형으로 보지 않는다.
    ★선언은 검증을 이길 수 없다(L-467) 유지★: 이 필드는 "검증 방법" 축만 대체한다.
      실제 변경 파일의 경로/DB 재대조는 main() 이 계속 수행한다.
    """
    if not isinstance(item, dict):
        return False
    if item.get("item_crud") is True:
        return False
    return str(item.get("verify_kind", "")).strip().lower() == "inspection"


def is_inspection_only(item, trust_item_crud=True, skip_demand_gate=False):
    """
    이 검수 항목이 ★저장 경로가 존재하지 않는 검증형 AC★ 인가.

    True 면 CRUD 실행 증거를 요구하지 않는다. 단 판정을 로그로 남겨
    ★조용히 통과하지 않게★ 한다 — 조용한 면제는 다음 사이클의 진짜 누락을 가린다.

    fail-safe: 부정문이 아닌 저장 요구 표현이 하나라도 있으면 False(=CRUD 유지).

    ★item_crud 구조화 필드 — 1순위 판정★ (사이클45, 자연어 판정 폐기 재발방지):
      구두점 정규식으로 한국어 절 경계를 추정하는 접근은 3회 시도해도 수렴하지
      않았다 (분리자 좁히면 회피 열리고, 넓히면 오탐 부활). 근본 원인은 한국어가
      구두점 없이 연결어미로 절을 잇고, 절 내부에도 구두점(병기 괄호)이 나오는
      언어 특성 자체다. item_crud 필드가 있으면 자연어 분석(_split_sentences /
      NEGATION_HINTS / INSPECTION_HINTS)을 일절 건너뛰고 그 값을 그대로 따른다.
      item_crud=True  → CRUD 유지 (검증형 아님) → False 반환
      item_crud=False → 검증형(CRUD 증거 불요) → True 반환
      필드 부재       → 레거시 폴백(기존 자연어 로직 그대로, 하위 호환)

    ★trust_item_crud=False — 회귀 수정★ (odev, 팀리드 지시):
      is_non_crud_declared() 의 content_suspects 계산에서는 item_crud 를
      신뢰하지 않는다. is_crud_item(trust_item_crud=False) 와 짝을 이뤄
      호출되며, 이 인자가 False 면 item_crud 값과 무관하게 원래의
      category/키워드 기반 검증형 판정(자연어 분석)을 그대로 수행한다.

    ★skip_demand_gate — is_non_crud_declared 전용 문맥 완화★ (odev, 팀리드
    지시, 2026-08-29 — 신규 발견 과잉차단 수정):
      is_non_crud_declared() 의 content_suspects 계산은 item_crud 도 안 보고
      (trust_item_crud=False) demand_blob 어미/시제 분석도 신뢰할 수 없다
      (3회 실패 이력, 사이클45). 하지만 이 함수에 ★도달했다는 사실 자체가
      신호★ 다 — 여기 도달하려면 이미 최상위 crud_대상=false + crud_미해당_사유
      기재로 "이 파일 전체가 비-CRUD 작업"이라고 명시 선언된 문맥이어야 한다
      (is_non_crud_declared 의 앞선 필드 체크를 통과해야만 content_suspects
      계산에 도달). 그 문맥에서 demand_blob 의 CRUD 동사 하나로 즉시 조기
      차단하는 것은 과하다 — "hook 등록 상태를 점검한다" 같은 검증형 문장이
      "등록" 히트만으로 verify_blob 검사도 못 받고 차단됐다.
      ⇒ skip_demand_gate=True 이면 WRITE_DEMAND_HINTS 조기 반환(아래)을 통째로
      건너뛰고 verify_blob/INSPECTION_HINTS 판정으로 직행한다. ★이 문맥 한정★
      이다 — 다른 호출부(main() 의 raw_crud/exempted 계산, item_crud:false
      개별 판정 등)는 이 인자를 넘기지 않으므로 기존 동작 그대로 유지된다.
      회피 방지는 이 함수의 책임이 아니다 — is_non_crud_declared 의 path
      교차검증(수정 1)이 실제 변경 파일로 거짓 선언을 여전히 잡아낸다.
    """
    if not isinstance(item, dict):
        return False

    if trust_item_crud:
        item_crud = item.get("item_crud")
        if isinstance(item_crud, bool):
            return not item_crud

    # ★사이클172 C25 — 명시 필드 verify_kind:"inspection" 이 자연어 판정보다 우선★
    #   trust_item_crud=False(선언 불신 재확인) 문맥에서도 검증 "방법" 선언은 유효하다.
    #   거짓 선언 방지는 이 함수가 아니라 main() 의 경로·DB 재대조가 담당한다(종전 역할 분담 그대로).
    if _declares_inspection(item):
        return True

    # ★F-CRUD-1 과잉 차단 수정★ (odev, 팀리드 지시 — 2026-08-29):
    #   trust_item_crud=False 문맥(is_non_crud_declared 의 content 재검증,
    #   또는 crud_대상 부재로 unverifiable 강제된 케이스)에서는 위의 item_crud
    #   조기 반환이 스킵된다. 그런데 작성자가 item_crud: false 를 ★명시★ 했다면
    #   그것은 "검증형이다"라는 선언이므로, demand_blob 의 WRITE_DEMAND_HINTS
    #   조기 차단(아래)이 그 선언을 다시 뒤집게 두면 안 된다 — "hook 이 정상
    #   등록되어 로드된다" 처럼 검증형 문장에 "등록" 같은 긍정 CRUD 동사가 하나만
    #   있어도 즉시 차단되는 오탐이 이 경로에서 발생했다.
    #   ⇒ item_crud: false 가 명시된 항목은 demand_blob 재판정을 건너뛰고
    #     verify_blob(방법론)이 실제로 검증형인지만 확인한다. item_crud 자체의
    #     신뢰 여부(거짓 선언 방지)는 이 함수의 책임이 아니다 — is_non_crud_declared
    #     의 path/content 교차검증(수정 1)이 별도로 담당한다. 두 수정은 역할
    #     분담으로 함께 작동해야 완결된다(수정 2 단독으로 회피까지 막지 않는다).
    #   item_crud 가 부재이거나 true 인 항목은 기존 자연어 폴백 그대로 유지한다.
    item_crud_declared_false = (
        isinstance(item.get("item_crud"), bool) and item.get("item_crud") is False
    )

    demand_blob = " ".join(
        _norm(item.get(key, ""))
        for key in ("criterion", "item", "name", "desc", "description",
                    "title", "given", "when", "then", "expected")
    )
    if not item_crud_declared_false and not skip_demand_gate:
        # 저장을 요구하면 예외 아님 — 단, 부정문 맥락(같은 문장 안 부정 표현)은
        # 저장 요구가 아니라 "저장하지 않았음" 진술이므로 히트에서 제외한다.
        for sentence in _split_sentences(demand_blob):
            has_demand = any(hint in sentence for hint in WRITE_DEMAND_HINTS)
            if not has_demand:
                continue
            has_negation = any(neg in sentence for neg in NEGATION_HINTS)
            if not has_negation:
                return False  # 부정 없는 진짜 저장 요구 — CRUD 유지

    # 저장 요구가 없거나(또는 전부 부정문), item_crud:false 선언, 또는
    # skip_demand_gate 문맥(is_non_crud_declared 도달 자체가 비-CRUD 선언
    # 문맥임을 이미 증명)으로 이 재판정 자체를 건너뛴 경우.
    # 검증 수단이 코드/로그/diff 확인인지 본다.
    verify_blob = " ".join(
        _norm(item.get(key, "")) for key in ("verify", "then", "expected", "method")
    )
    return any(hint in verify_blob for hint in INSPECTION_HINTS)


def _norm(value):
    """검수 항목의 자연어 필드를 하나의 문자열로 합친다."""
    if isinstance(value, str):
        return value
    return json.dumps(value, ensure_ascii=False)


# ─────────────────────────────────────────────────────────────────────────
# ★CRUD_SUSPECT_PATTERN 확장 — repo/dal/dto 추가★ (사이클49, A4)
# ─────────────────────────────────────────────────────────────────────────
# 배경(직전 otest 실측): 기존 화이트리스트가 저장 계층 네이밍 중 repo/dal/dto
#   세그먼트·접미사를 놓쳐 `src/repo/UserRepo.py`, `dal/x.cs`, `dto/y.ts` 8/8
#   전수 우회에 성공했다. 이 세 어휘는 저장 계층 전용 의미가 뚜렷해 추가한다.
#
# ★model 은 의도적으로 추가하지 않는다★ (팀리드 사전 경고):
#   프론트엔드 뷰모델(`src/model/viewmodel.ts`), ML 체크포인트 등 비-CRUD
#   맥락에서 매우 흔해 repo/dal/dto 보다 과잉차단 위험이 현저히 크다.
#   접미사 결합(`*.model.cs` 등)도 검토했으나 DTO/ViewModel 과 구분이
#   안 돼 보류했다. 대신 `services/model/x.cs` 처럼 상위 세그먼트
#   (services/repository/dao 등)가 이미 걸리는 경로는 부분 커버되므로
#   추가 규칙 없이도 실질적 공백은 좁다.
#
# ★근본 한계(해소 안 됨)★: 이 화이트리스트 방식은 새 네이밍(store/, entity/,
#   persist/ 등)이 나오면 또 뚫린다. 이번 추가는 알려진 우회를 막는 것이지
#   근본 해결이 아니다 — 후속 우회 발견 시 동일한 방식으로 국소 확장하되,
#   "화이트리스트가 이 시점의 흔한 어휘를 반영할 뿐"이라는 한계는 계속 유효하다.
CRUD_SUSPECT_PATTERN = re.compile(
    r"(?i)(?:(controller|service|repository|repo|dal|dto|dao)\.(cs|java|py|ts|js)$"
    r"|(?:^|[/\\])(api|controllers?|services?|repositories?|repo|dal|dto|routes?|handlers?|dao)[/\\].*\.(cs|java|py|ts|js)$"
    r"|\.sql$)"
)


# 2026-10-06 정정 (conv_179127861998): file_assignment.json 부재 시 변경 파일 독립 산출 폴백.
#   o2(oplan_simple) 는 file_assignment.json 을 만들지 않아, 부재만으로 item_crud:false 항목이
#   전부 재확인 대상이 되고 DB 무접촉 실측도 no_assignment 로 막혀 비-CRUD 작업이 과잉 차단됐다.
#   ★파일이 "존재하지 않을 때(FileNotFoundError)만★ git(작업트리+시작 이후 커밋)·mtime 으로 산출한다.
#   파싱 실패/git 아님/시작시각 부재/git 실패는 기존 fail-closed 그대로. 어휘·item_crud 신뢰 로직은 불변.
_DERIVED_LOGGED = False


def _run_git(args, cwd):
    """git 을 timeout 10초로 실행해 stdout(bytes)을 반환한다. 실패하면 None."""
    import subprocess
    try:
        proc = subprocess.run(["git"] + args, cwd=cwd, capture_output=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return None
    if proc.returncode != 0:
        return None
    return proc.stdout


def derive_changed_files(session_dir):
    """pipeline_start_time 이후 변경된 파일을 git+mtime 으로 산출한다.

    반환값: (files: list[str] | None, error: str | None) — None 이면 fail-closed 대상.
    """
    global _DERIVED_LOGGED
    try:
        with open(os.path.join(session_dir, "pipeline_start_time"), "r", encoding="utf-8") as fp:
            start = int(fp.read().strip())
    except (OSError, ValueError):
        return None, "no_start_time"

    base = os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    top = _run_git(["rev-parse", "--show-toplevel"], base)
    if top is None:
        return None, "not_git"
    root = top.decode("utf-8", "replace").strip()
    if not root:
        return None, "not_git"

    status = _run_git(["status", "--porcelain", "-z", "-uall"], root)
    log = _run_git(["log", f"--since=@{start}", "--name-only", "-z", "--pretty=format:"], root)
    if status is None or log is None:
        return None, "git_failed"

    names = []
    entries = status.decode("utf-8", "replace").split("\0")
    idx = 0
    while idx < len(entries):
        ent = entries[idx]
        idx += 1
        if len(ent) < 4:
            continue
        names.append(ent[3:])
        if ent[0] in "RC":  # rename/copy 는 원본 경로가 다음 항목으로 따라온다
            idx += 1
    for name in log.decode("utf-8", "replace").split("\0"):
        name = name.strip("\n")
        if name:
            names.append(name)

    files = []
    seen = set()
    for name in names:
        full = os.path.join(root, name)
        if full in seen:
            continue
        seen.add(full)
        try:
            if os.stat(full).st_mtime < start:
                continue  # 시작 이전부터 dirty 이던 파일은 이번 작업이 아니다
        except OSError:
            pass  # 삭제된 파일은 이름만으로 suspect 패턴 검사 대상 유지
        files.append(full)

    if not _DERIVED_LOGGED:
        _DERIVED_LOGGED = True
        print(
            f"CHANGED_FILES_DERIVED: file_assignment.json 부재 — git+pipeline_start_time 로 "
            f"{len(files)}개 산출"
        )
    return files, None


# ★file_assignment.json 다중 스키마 판독★ (사이클172 C25 — F-CRUD-1 오탐 ⑰-①)
#   배경: 종전에는 assignment["agents"][*]["files"] ★한 형태만★ 읽었다. 사이클171 은
#     {"odev-14": {"files": [...]}, ...} 처럼 에이전트 키가 ★최상위★ 에 오는 형식을 썼고,
#     phase_batches 계열은 batches[].file_assignment / phases[] 형식을 쓴다.
#     그 결과 실제로는 수십 개 파일이 있는데 "변경 파일 0개" 로 판독돼
#     scan_db_contact → no_files → DB_SCAN_UNVERIFIABLE fail-closed 가 났다(c171 재현 확인).
#   원칙: 아는 형태를 ★합집합★ 으로 모은다. 모르는 형태는 여전히 0개 → fail-closed 그대로다
#     (판독 범위를 넓힌 것이지 판정을 무르게 한 것이 아니다).
_ASSIGNMENT_NESTED_KEYS = ("agents", "file_assignment")
# 사이클174 이월1: c173 은 waves[] 형식을 썼는데 이 목록에 없어 0개로 판독 → 비CRUD 면제 불가 →
#   DONE 전이가 막혀 DISABLE_DONE_GATE 우회가 필요했다. waves 를 batches 와 같은 리스트 축으로 인정한다.
_ASSIGNMENT_LIST_KEYS = ("phases", "batches", "waves")


def _file_groups_from_assignment(assignment, _depth=0):
    """file_assignment 구조에서 {files, deleted_files} 그룹(dict) 목록을 모은다.

    인식 형식(합집합):
      ① {"agents": {"odev-1": {"files": [...]}}}           — 종전 형식
      ② {"odev-1": {"files": [...]}, ...}                  — 최상위 에이전트 키(사이클171)
      ③ {"phases"|"batches"|"waves": [{"file_assignment": {...}} | {"files": [...]} | {"agents": {...}}]}
      ④ {"file_assignment": {...}}                         — 한 겹 감싼 형식
      ⑤ {"files": [...]}                                   — 평면 형식
    """
    groups = []
    if not isinstance(assignment, dict) or _depth > 4:
        return groups
    if isinstance(assignment.get("files"), list):
        groups.append(assignment)
    for key in _ASSIGNMENT_NESTED_KEYS:
        nested = assignment.get(key)
        if isinstance(nested, dict):
            # agents/file_assignment 의 값은 에이전트별 dict 다 — 에이전트 dict 하나를 그룹으로 본다.
            for value in nested.values():
                if isinstance(value, dict):
                    groups.extend(_file_groups_from_assignment(value, _depth + 1))
    for key in _ASSIGNMENT_LIST_KEYS:
        seq = assignment.get(key)
        if isinstance(seq, list):
            for entry in seq:
                groups.extend(_file_groups_from_assignment(entry, _depth + 1))
    for key, value in assignment.items():
        if key in _ASSIGNMENT_NESTED_KEYS or key in _ASSIGNMENT_LIST_KEYS or key == "files":
            continue
        # 최상위 에이전트 키(odev-N 등) — files 배열을 가진 dict 만 인정한다.
        if isinstance(value, dict) and isinstance(value.get("files"), list):
            groups.extend(_file_groups_from_assignment(value, _depth + 1))
    return groups


def _files_from_assignment(assignment):
    """다중 스키마 file_assignment 에서 (파일 목록, 삭제 선언 집합) 을 돌려준다.

    삭제 선언(deleted_files)은 ★같은 그룹의 files 에 있는 경로만★ 인정한다(종전 규칙 유지).
    파일 목록은 등장 순서를 유지하며 중복을 제거한다.
    """
    files, seen, deleted = [], set(), set()
    for group in _file_groups_from_assignment(assignment):
        listed = [str(f) for f in group.get("files", [])]
        for f in listed:
            if f not in seen:
                seen.add(f)
                files.append(f)
        declared = group.get("deleted_files", [])
        if isinstance(declared, list):
            listed_set = set(listed)
            deleted.update(str(d) for d in declared if str(d) in listed_set)
    return files, deleted


# ★사이클197 (d) — 배정표 files 항목 형식 fail-closed★ (AC-J6)
#   종전 _files_from_assignment 는 files 항목을 str() 로만 읽었다. c197 배정표 v1 은 files 를
#   [{"path":…, "action":…}] dict 로 적었고, str(dict) 는 "{'path': '…Service.cs', …}" 라 CRUD_SUSPECT_PATTERN
#   (끝이 .cs 여야 한다)에 걸리지 않아 의심 0건 = 경로 축 무력화(fail-open)였다. 상대경로도 판정기 cwd 에
#   따라 다른 파일을 열거나 못 연다. ⇒ dict·비문자열·상대경로 항목이 하나라도 있으면 경로 축을
#   "확인 불가(unverifiable)" 로 돌린다. 판정을 무르게 하지 않는다 — 면제를 주지 않는 쪽으로만 움직인다.
def _assignment_bad_entries(assignment):
    """files 항목 중 경로 축이 판독할 수 없는 항목 목록 [(사유, 표시값)] — dict/비문자열/빈 문자열/상대경로."""
    bad = []
    for group in _file_groups_from_assignment(assignment):
        for f in group.get("files", []):
            if not isinstance(f, str):
                bad.append((f"{type(f).__name__} 항목", _norm(json.dumps(f, ensure_ascii=False))[:80]))
            elif not f.strip():
                bad.append(("빈 문자열", "''"))
            elif not os.path.isabs(f):
                bad.append(("상대경로", f[:80]))
    return bad


_ASSIGNMENT_BAD_LOGGED = set()


def _assignment_unverifiable(assignment, file_assignment_path):
    """판독 불가 항목이 있으면 사유 문자열(1회 출력), 없으면 None."""
    bad = _assignment_bad_entries(assignment)
    if not bad:
        return None
    reason = (f"files 항목 {len(bad)}건 판독 불가(dict·비문자열·상대경로) — 첫 항목: "
              f"{bad[0][0]} {bad[0][1]} — 절대경로 문자열 배열로 적어야 경로 축을 판정할 수 있다")
    if file_assignment_path not in _ASSIGNMENT_BAD_LOGGED:
        _ASSIGNMENT_BAD_LOGGED.add(file_assignment_path)
        print(f"CRUD_ASSIGNMENT_UNVERIFIABLE: {file_assignment_path}: {reason}", file=sys.stderr)
        for kind, shown in bad[:5]:
            print(f"  - {kind}: {shown}", file=sys.stderr)
    return reason


_PATH_SKIP_LOGGED = set()


def load_crud_suspect_files(file_assignment_path):
    """file_assignment.json 을 읽어 CRUD 의심 파일 목록을 반환한다.

    반환값: (suspects: list[str] | None, error: str | None)
      suspects=list → 로드 성공. CRUD_SUSPECT_PATTERN 매치 파일들(없으면 빈 리스트).
      suspects=None → 로드 실패. error 에 예외 메시지.

    ★배선 확장★ (odev, 팀리드 지시 — 세 번째 승인, 2026-08-29):
      기존에는 이 경로 대조가 is_non_crud_declared() 안에만 있어서, top-level
      crud_대상=false 선언이 없으면(=필드 부재) 한 번도 실행되지 않았다. 그 결과
      item_crud:false 거짓 기재 + CRUD 파일 변경 조합이 top-level 선언 없이도
      무사통과하는 구멍이 있었다(실측 재현: UserController.cs/api·handler.js/
      schema.sql 3종). is_non_crud_declared() 와 item_crud:false 개별 면제
      양쪽에서 공유하도록 이 로직을 헬퍼로 분리한다 — 새 휴리스틱이 아니라
      기존 CRUD_SUSPECT_PATTERN 재사용/재배선이다.
    """
    all_files = []
    try:
        with open(file_assignment_path, "r", encoding="utf-8") as fp:
            assignment = json.load(fp)
    except FileNotFoundError as exc:
        # 2026-10-06 정정: 부재일 때만 독립 산출 폴백. 실패하면 기존 fail-closed.
        derived, _derr = derive_changed_files(os.path.dirname(file_assignment_path))
        if derived is None:
            return None, str(exc)
        assignment = {}
        all_files.extend(derived)
    except (OSError, json.JSONDecodeError) as exc:
        return None, str(exc)

    # 사이클197 (d): dict·상대경로 항목은 경로 축 판독 불가 — 의심 0건(fail-open)이 아니라 로드 실패로 돌린다.
    bad_reason = _assignment_unverifiable(assignment, file_assignment_path)
    if bad_reason:
        return None, bad_reason

    # 사이클172 C25: agents 단일 형식 → 다중 스키마 합집합(_files_from_assignment).
    assigned, _deleted = _files_from_assignment(assignment)
    all_files.extend(assigned)

    suspects = [f for f in all_files if CRUD_SUSPECT_PATTERN.search(f)]

    # 2026-10-11 conv_179163042411 (5): 경로 축에는 "이번 파이프라인에서 손대지 않은 파일 skip" 만 적용한다.
    #   (이 함수는 의심 파일 목록만 낸다. 의심 파일의 무효화 판독 범위는 사이클197 (e) 사용자 결정으로
    #    "시작 시점 base/기준선 대비 변경 줄 ±DB_CONTEXT_WINDOW 줄의 쓰기 토큰" 이다 — WRITE_TOKEN_PATTERN 주석.
    #    종전 L-467 의 "건드렸으면 파일 전체로 판정" 은 base·기준선이 없을 때만 남는다.)
    #   조건: 시작시각 신뢰(_start_time_trusted) + 대상 mtime·ctime 모두 시작 이전(_untouched_since).
    #   시작시각 부재·불신·stat 실패(삭제 등)는 종전대로 suspect 유지(fail-closed). ctime 은 touch -d 로 되돌릴 수 없다.
    if suspects:
        session_dir = os.path.dirname(file_assignment_path)
        start = _read_start_time(session_dir)
        if start is not None and _start_time_trusted(session_dir, start):
            kept = []
            for f in suspects:
                if _untouched_since(f, start):
                    if f not in _PATH_SKIP_LOGGED:  # 소비처 3곳이 각각 호출하므로 1회만 출력
                        _PATH_SKIP_LOGGED.add(f)
                        print(f"CRUD_PATH_SKIP_PREEXISTING: {f} (mtime·ctime 모두 시작 이전 — 이번 파이프라인 미변경)")
                else:
                    kept.append(f)
            suspects = kept
    return suspects, None


# ─────────────────────────────────────────────────────────────────────────────
# ★DB 무접촉 실측 면제★ (사이클145 — 사용자 승인, odev-5 구현)
# ─────────────────────────────────────────────────────────────────────────────
#   배경: item_crud:false 의 재확인(content 축)은 AC 본문의 ★자연어 키워드★로
#     판정한다. 그래서 "DB ★저장★ 아님" 처럼 ★부정하는 문장의 단어★ 까지 CRUD 로
#     잡힌다(부분문자열 매칭이라 부정문을 해석하지 않는다). 사이클145 실측 —
#     V3/V4/A1/A8 4건이 전부 이 형태였고, 변경 파일은 .sh 9개로 DB 무접촉이었다.
#
#   ★해법의 성격이 중요하다★: 문구에서 '저장/등록' 을 지워 회피하는 것은
#     ★어휘 회피★ 이고 게이트를 무르게 만든다(그 안은 사용자가 택하지 않았다).
#     대신 ★변경 파일을 실제로 열어 DB 코드가 0건임을 실측★ 해서 면제한다.
#     "단어를 피했다" 가 아니라 "DB 코드가 없다" 가 근거다.
#
#   ★fail-closed 원칙★ — 아래 3가지는 전부 "면제하지 않는다":
#     · file_assignment.json 부재/파싱실패 → 확인 불가는 의심 없음이 아니다
#     · files 목록이 비어 있음            → 대조할 대상이 없으면 근거도 없다
#     · 파일 1개라도 못 읽음(권한/부재/인코딩) → 안 본 파일은 무해가 아니다
#   ⇒ 이 스크립트가 본문에서 스스로 경고한 함정("'확인할 수 없음' 이
#     '의심 없음' 으로 오인되는 것")을 그대로 지킨다.

# DB 접속 라이브러리/스키마명 + SQL DML/DDL. 대소문자 무시.
# UPDATE/DELETE 는 단독 단어가 흔해 오탐이 나므로 SET/FROM 까지 묶어서 본다.
DB_CONTACT_PATTERN = re.compile(
    r"(?i)(?:\bmysql\b|\bpymysql\b|\bpsycopg2?\b|\bsqlite3\b|\bMySqlConnector\b"
    r"|\bSqlConnection\b|\bmariadb\b|\bcspms\b|\bdqpms\b"
    r"|\bINSERT\s+INTO\b|\bUPDATE\s+\w+\s+SET\b|\bDELETE\s+FROM\b"
    r"|\bCREATE\s+TABLE\b|\bALTER\s+TABLE\b|\bDROP\s+TABLE\b|\bTRUNCATE\s+TABLE\b"
    r"|\bSELECT\b[\s\S]{0,200}?\bFROM\b)"
)


# 2026-10-20 역라우팅 #1 (conv_179239511726 — 사용자 선택 "가드 판정 개선 먼저"):
#   DB_CONTACT_PATTERN 은 \bmysql\b 처럼 라이브러리·스키마 이름만 나와도 매치한다. 그래서 mysql MCP 서버 실행
#   경로를 적은 .mcp.json 과 "mysql MCP tools/list 조회" 를 서술한 핸드오프 문서 5건이 db_found 로 잡혀
#   item_crud:false 면제가 무효가 됐다(실제 DB 쓰기 코드 0건). 판정을 무르게 하지 않고 범위만 좁힌다:
#     · 코드 파일(.py .sh .cs .js .ts .sql·확장자 없는 스크립트 등 DOC_CONFIG_EXTS 밖 전부)은 종전대로 이름 매치도 db_found.
#     · 문서·설정 파일(DOC_CONFIG_EXTS)은 같은 검사 범위(diff 변경 줄+근접 / 전체 스캔)를 DB_DML_PATTERN 으로 다시 본다.
#       DML/DDL 이 있으면 종전대로 db_found, 이름만 있으면 hits 에서 빼고 DB_NAME_MENTION_DOC_EXCLUDED 정보 줄을 낸다.
#     · 확장자는 경로 실측(os.path.splitext)이다 — 작성자 선언 필드가 아니다(L-467).
#     · 판독 실패·no_files·no_assignment 의 fail-closed, 삭제 파일 분류(_classify_deleted)는 바꾸지 않는다.
DOC_CONFIG_EXTS = frozenset({".md", ".json", ".txt", ".yaml", ".yml", ".toml"})
DB_DML_PATTERN = re.compile(
    r"(?i)(?:\bINSERT\s+INTO\b|\bUPDATE\s+\w+\s+SET\b|\bDELETE\s+FROM\b"
    r"|\bCREATE\s+TABLE\b|\bALTER\s+TABLE\b|\bDROP\s+TABLE\b|\bTRUNCATE\s+TABLE\b"
    r"|\bSELECT\b[\s\S]{0,200}?\bFROM\b)"
)


# ★사이클197 (e) — 경로 의심 파일의 무효화 판정은 "변경 hunk 의 실제 쓰기 토큰" 으로 한다★ (사용자 승인 18:4x, AC-J6)
#   종전 is_non_crud_declared 는 경로 의심 파일(Services/*.cs 등)의 ★파일 전체★ 를 DB_CONTACT_PATTERN 으로 봤다.
#   그 패턴은 스키마 이름(cspms·dqpms)·SELECT…FROM 같은 ★읽기·이름 토큰★ 도 DB 흔적으로 센다. c197 은 조회 SQL·
#   주석만 고친 Services 4파일이 주석 속 스키마 이름 때문에 crud_대상=false 선언 무효화 → MISSING_CRUD_EVIDENCE rc=1
#   하드 차단으로 확정됐다(oplan §12-2 실측). 이번에 바꾸지 않은 줄의 이름 토큰이 이번 작업을 CRUD 로 만든 것이다.
#   ⇒ 기준을 둘 다 좁힌다: (범위) pipeline_start_time 시점 base 대비 변경 줄 + 근접 DB_CONTEXT_WINDOW 줄
#      (종전 scan_db_contact 와 같은 _diff_db_hits 기계 — base 가 없으면 파일 전체), (토큰) 쓰기 문장만.
#   쓰기 토큰: DML 쓰기 3동사 문장·REPLACE/MERGE INTO·DDL·LOAD DATA·ExecuteNonQuery(Async)·ExecuteTransaction(Async)·
#     SaveChanges(Async)·BulkCopy/BulkLoader·executemany·commit(). 문자열 이어붙임(" + ")을 사이에 둔 조각도 잡는다.
#   [c197 odev_review J-B1·J-W1 반영] DML 3동사는 "동사 … 짝 키워드" 사이에 문장 경계(;) 없이 별칭·JOIN·수식어·
#     이어붙인 식별자를 허용한다 — UPDATE…SET(≤200자)·DELETE…FROM(≤120자)·INSERT…INTO|VALUES|VALUE|SELECT|SET(≤200자,
#     INTO 생략·LOW_PRIORITY·IGNORE 등 수식어 포함). 실행 API 에 Dapper Execute(Async)( · EF ExecuteSqlRaw/
#     ExecuteSqlInterpolated/ExecuteUpdate/ExecuteDelete(Async) 를 더했다. 범위를 넓혀 생기는 오탐(주석 속 영어 문장 등)은
#     종전 동작(차단) 쪽이라 fail-closed 로 받아들인다(리드 지시).
#   fail-closed 유지: 쓰기 토큰 1건·판독 실패·diff 판독 불가·스캔 예외는 전부 종전대로 "path" 무효화다.
#   한계: 쓰기 SQL 이 변경 줄에서 DB_CONTEXT_WINDOW 줄 밖에 있고 그 SQL 을 실행하는 줄만 바뀐 경우(예: 상수 SQL 을
#     멀리서 참조) — 실행 API(ExecuteNonQuery 등)가 변경 범위에 있으면 잡히고, 이름만 다른 사용자 정의 쓰기 메서드는
#     잡히지 않는다. 이 한계는 item_crud:true 항목·otest 증거 요구가 진다(이 판정은 crud_대상=false 선언의 모순 검사다).
# 이어붙임 사이: 공백, 또는 따옴표 + [식별자 + ] 따옴표(예: "UPDATE " + tbl + " SET") — J-B1 로 식별자 1토큰 허용
_SQL_GAP = r"""(?:\s|["']\s*\+\s*[@$]*(?:[\w.]+(?:\(\s*\))?\s*\+\s*[@$]*)?["'])+"""
WRITE_TOKEN_PATTERN = re.compile(
    r"(?i)(?:\bINSERT\b[^;]{0,200}?\b(?:INTO|VALUES?|SELECT|SET)\b"
    r"|\bREPLACE" + _SQL_GAP + r"(?:(?:LOW_PRIORITY|DELAYED)" + _SQL_GAP + r")?INTO\b"
    r"|\bMERGE" + _SQL_GAP + r"INTO\b"
    r"|\bUPDATE\b[^;]{0,200}?\bSET\b"
    r"|\bDELETE\b[^;]{0,120}?\bFROM\b"
    r"|\b(?:CREATE|ALTER|DROP|RENAME)" + _SQL_GAP + r"(?:TEMPORARY" + _SQL_GAP + r")?"
    r"(?:TABLE|INDEX|VIEW|DATABASE|SCHEMA|PROCEDURE|FUNCTION|TRIGGER|EVENT)\b"
    r"|\bTRUNCATE" + _SQL_GAP + r"(?:TABLE\b|[`\w.]+\s*[;\"'])"
    r"|\bLOAD" + _SQL_GAP + r"DATA\b"
    r"|\bExecuteNonQuery(?:Async)?\b|\bExecuteTransaction(?:Async)?\b|\bSaveChanges(?:Async)?\b"
    r"|\bExecute(?:Async)?\s*[<(]|\bExecuteSql(?:Raw|Interpolated)(?:Async)?\b|\bExecute(?:Update|Delete)(?:Async)?\b"
    r"|\b(?:Sql|MySql)BulkCopy\b|\bMySqlBulkLoader\b|\bexecutemany\b|\bcommit\(\s*\))"
)


def _write_token_hits(path, content, start, base_cache, session_dir):
    """경로 의심 파일 1개의 쓰기 토큰 판정. 반환: ("clean", None) / ("hit", 근거) / ("unreadable", 사유)."""
    import contextlib
    import io
    with contextlib.redirect_stdout(io.StringIO()):
        mode, info = _diff_db_hits(path, content, start, base_cache, session_dir=session_dir,
                                   pattern=WRITE_TOKEN_PATTERN)
    if mode in ("hit", "unreadable"):
        return mode, info
    if mode == "full":
        mo = WRITE_TOKEN_PATTERN.search(content)
        if mo:
            return "hit", f"전체 판독({info}): {_norm(mo.group(0))[:60]}"
    return "clean", None


def _is_doc_config(path):
    """경로 확장자(실측)가 문서·설정 파일(DOC_CONFIG_EXTS)인가."""
    return os.path.splitext(str(path))[1].lower() in DOC_CONFIG_EXTS


# 2026-11-01 (conv_rea_20261101): 서드파티 스킬 참조문서(.md)의 영어 산문 "select … from" 이 DB_DML_PATTERN 의
#   SELECT…FROM 가지에 걸려 db_found 가 났다(실제 DML 0건). 산문 문서(.md .txt)는 쓰기 DML/DDL 만 본다.
#   코드 파일·설정 파일(.json .yaml .yml .toml)은 종전 DB_DML_PATTERN 그대로이며 확장자는 경로 실측이다.
PROSE_DOC_EXTS = frozenset({".md", ".txt"})
DB_DML_WRITE_PATTERN = re.compile(
    r"(?i)(?:\bINSERT\s+INTO\b|\bUPDATE\s+\w+\s+SET\b|\bDELETE\s+FROM\b"
    r"|\bCREATE\s+TABLE\b|\bALTER\s+TABLE\b|\bDROP\s+TABLE\b|\bTRUNCATE\s+TABLE\b)"
)


def _doc_dml_pattern(path):
    """문서·설정 파일 재검사에 쓸 DML 패턴 — 산문 문서는 SELECT…FROM 가지를 뺀다."""
    if os.path.splitext(str(path))[1].lower() in PROSE_DOC_EXTS:
        return DB_DML_WRITE_PATTERN
    return DB_DML_PATTERN


# 2026-10-24 (conv_179279890015 후속 — 사용자 "사용자 승인 절차를 최소화 하라"):
#   코드 파일의 DB 이름 언급(주석·정규식 리터럴·다른 명령의 인자 문자열)이 db_found 를 내 비-CRUD 작업이
#   화면 승인을 거쳤다(hooks/candidates/pdg_core/pda_core.py:137·151·152, pda_test.sh:666·672).
#   판정을 무르게 하지 않고 "이름 언급" 과 "DB 접근 형태" 를 나눈다:
#     · 대상: CODE_ACCESS_EXTS 확장자 + CRUD 의심 경로·Queries 경로 아님 (경로 실측, 선언 아님 — L-467)
#     · 같은 범위 DML/DDL 0건 + 파일 전체 접근 형태 0건일 때만 적중을 정보 줄로 바꾼다.
#     · 새 적중은 만들지 않는다. 판독·파싱 실패·예외는 "unknown" → 종전대로 적중 유지(fail-closed).
CODE_ACCESS_EXTS = frozenset({".py", ".sh", ".bash", ".cs", ".js", ".ts", ".mjs", ".cjs"})
_DB_CLI = r"(?:mysql|mariadb|mysqldump|mysqladmin|mysqlimport|mysqlsh|psql|sqlite3)"
QUERIES_PATH_RE = re.compile(r"(?i)(?:^|[/\\])quer(?:y|ies)\w*(?:[/\\]|\.)")
SH_DB_ACCESS_PATTERN = re.compile(
    r"(?im)(?:^|[;&|`(]|\$\()\s*(?:sudo\s+|exec\s+|command\s+|nohup\s+|time\s+|env\s+(?:\w+=\S*\s+)*|\w+=\S*\s+)*"
    + _DB_CLI + r"(?=\s|$|[;&|)`])"
    r"|\b(?:bash|sh|dash|zsh|eval|ssh)\b[^\n]*?[\"']\s*" + _DB_CLI + r"(?=\s|[\"'])"
)
PY_DB_ACCESS_PATTERN = re.compile(
    r"(?m)^\s*(?:import|from)\s+(?:pymysql|MySQLdb|mysql(?:\.connector)?|psycopg2?|sqlite3|mariadb|sqlalchemy"
    r"|aiomysql|asyncpg)\b"
    r"|\b(?:pymysql|MySQLdb|psycopg2?|sqlite3|mariadb|connector|aiomysql|asyncpg)\s*\.\s*connect\s*\("
    r"|\bcreate_engine\s*\("
)
PY_DB_CLI_STRING = re.compile(r"^[rbuRBUfF]*(?:\"\"\"|'''|\"|')\s*" + _DB_CLI + r"(?=\s|[\"'])")
CSJS_DB_ACCESS_PATTERN = re.compile(
    r"(?i)\busing\s+(?:MySql|MySqlConnector|Npgsql|Microsoft\.Data\.Sqlite|System\.Data\.SqlClient"
    r"|Microsoft\.Data\.SqlClient|Dapper)\b"
    r"|\bnew\s+(?:MySql|Sql|Npgsql|Sqlite)(?:Connection|Command|DataAdapter)\s*\("
    r"|\brequire\s*\(\s*[\"'](?:mysql2?|mariadb|pg|sqlite3|better-sqlite3|knex|sequelize)\b"
    r"|\bfrom\s*[\"'](?:mysql2?|mariadb|pg|sqlite3|better-sqlite3|knex|sequelize)\b"
    r"|\b(?:createConnection|createPool)\s*\("
)


def _py_access_scan(content):
    """파이썬 소스에서 주석을 버리고 문자열 리터럴을 비운 코드에 접근 형태가 있는지 본다(access|mention)."""
    import ast
    import io
    import tokenize
    ast.parse(content)
    rows = {}
    last = {}
    fs_pending = None
    for tok in tokenize.generate_tokens(io.StringIO(content).readline):
        ttype, text, (srow, scol) = tok.type, tok.string, tok.start
        name = tokenize.tok_name.get(ttype, "")
        if name == "COMMENT":
            continue
        if name == "STRING":
            if PY_DB_CLI_STRING.search(text):
                return "access"
            text = '""'
        elif name == "FSTRING_START":
            fs_pending = text
            text = '""'
        elif name == "FSTRING_MIDDLE":
            if fs_pending is not None and PY_DB_CLI_STRING.search(fs_pending + text):
                return "access"
            fs_pending = None
            continue
        elif name == "FSTRING_END":
            continue
        elif name in ("NEWLINE", "NL", "INDENT", "DEDENT", "ENDMARKER"):
            if name == "INDENT":
                rows.setdefault(srow, []).append(text)
            continue
        if name != "FSTRING_START":
            fs_pending = None
        parts = rows.setdefault(srow, [])
        prev = last.get(srow)
        if prev in ("NAME", "NUMBER") and name in ("NAME", "NUMBER"):
            parts.append(" ")
        parts.append(text)
        last[srow] = name
    code = "\n".join("".join(rows[r]) for r in sorted(rows))
    return "access" if PY_DB_ACCESS_PATTERN.search(code) else "mention"


def _code_db_access(path, content):
    """코드 파일 전체에 DB 접근 형태가 있는가. ("access", 근거) | ("mention", None) | ("unknown", 사유)."""
    try:
        p = str(path)
        ext = os.path.splitext(p)[1].lower()
        if ext not in CODE_ACCESS_EXTS:
            return "unknown", f"대상 외 확장자 {ext or '(없음)'}"
        if CRUD_SUSPECT_PATTERN.search(p) or QUERIES_PATH_RE.search(p):
            return "unknown", "대상 외 경로(CRUD 의심·Queries)"
        if ext == ".py":
            if _py_access_scan(content) == "access":
                return "access", "py 접근 형태"
            return "mention", None
        if ext in (".sh", ".bash"):
            body = "\n".join("" if ln.lstrip().startswith("#") else ln for ln in content.split("\n"))
            mo = SH_DB_ACCESS_PATTERN.search(body)
            return ("access", _norm(mo.group(0))[:60]) if mo else ("mention", None)
        body = re.sub(r"/\*.*?\*/", "", content, flags=re.S)
        body = "\n".join("" if ln.lstrip().startswith("//") else ln for ln in body.split("\n"))
        mo = CSJS_DB_ACCESS_PATTERN.search(body)
        return ("access", _norm(mo.group(0))[:60]) if mo else ("mention", None)
    except Exception as e:  # noqa: BLE001 — 판독 실패는 fail-closed(적중 유지)
        return "unknown", f"{type(e).__name__}: {e}"


# 2026-10-11 역라우팅 #2 (conv_179163042411 — CRUD_GATE 자동 분류·재판정):
#   시험 픽스처 판별 단일 상수. 경로에 tests/·test/·__tests__/·fixtures/·fixture/ 디렉터리가 있거나
#   파일명이 test_*.py|test_*.sh|*_test.py|*_test.sh 이면 픽스처다(대소문자 구분 — 넓히지 않는다).
#   쓰임은 DB 접촉 축(scan_db_contact) 한 곳뿐이다:
#     · 기본(옵션 없음): 판정 무변경. db_found 의 매치 파일이 전부 픽스처면 정보 줄 DB_HITS_TEST_FIXTURE_ONLY 만 낸다.
#     · --exclude-test-fixtures: 픽스처 매치를 DB_SCAN_TEST_FIXTURE_EXCLUDED 로 출력하고 db_found 판정에서 뺀다.
#       판독은 그대로 한다(판독 실패는 종전대로 unreadable). 경로 축·증거·스냅샷 검사는 손대지 않는다.
#   ★선언이 아니라 경로 실측이다(L-467)★ — 작성자가 고르는 필드가 아니고, 픽스처가 아닌 파일의 매치는 그대로 남는다.
TEST_FIXTURE_RE = re.compile(
    r"(?:^|/)(?:tests?|__tests__|fixtures?)/"
    r"|(?:^|/)(?:test_[^/]*\.(?:py|sh)|[^/]*_test\.(?:py|sh))$"
)


def _is_test_fixture(path):
    """경로 문자열이 시험 픽스처(TEST_FIXTURE_RE)에 해당하는가."""
    return TEST_FIXTURE_RE.search(str(path).replace("\\", "/")) is not None


_SELF_SCAN_EXCLUDED_LOGGED = set()


def _gate_self_realpaths():
    """DB 접촉 스캔에서 제외할 판정기 자기 파일 정확히 2개의 realpath 집합."""
    here = os.path.realpath(__file__)
    return {here, os.path.join(os.path.dirname(here), "test_verify_crud_executed.py")}


def _is_gate_self_file(path):
    """후보 경로를 프로젝트 루트 기준 절대경로 → realpath 로 정규화해 자기 파일 2개와 정확 일치 비교한다."""
    if any(ch in path for ch in "*?") or path.endswith(("/", "\\")):
        return False
    base = os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    real = os.path.realpath(os.path.join(base, path))  # 절대경로면 base 는 무시된다
    if real in _gate_self_realpaths():
        if real not in _SELF_SCAN_EXCLUDED_LOGGED:
            _SELF_SCAN_EXCLUDED_LOGGED.add(real)
            print(f"SELF_SCAN_EXCLUDED: {real}")
        return True
    return False


# 2026-10-06 역라우팅 #2 정정 (conv_179129116825): 삭제 파일을 '판독 불가'와 분리한다.
#   file_assignment.json 이 있을 때 삭제된 파일은 open() 실패 → unreadable 로 무접촉 면제가 막혔다.
#   agent 의 deleted_files 선언(같은 agent files 부분집합)은 ★필요조건일 뿐★이고, 삭제 확정은
#   아래 독립 실측(부재 + git 저장소 판별 + 인덱스/HEAD/이력 분기)으로만 내린다(L-467).
#   이력에만 있음 / git 아님 / git 실패는 전부 unreadable(fail-closed).
def _classify_deleted(path):
    """선언된 부재 경로를 git 으로 실측해 (kind, info) 를 반환한다.

    kind: "confirmed"(info=untracked-never|tracked-head-scanned) / "db_found"(info=매치) / "unreadable"(info=사유)
    """
    absolute = os.path.abspath(path)
    anchor = os.path.dirname(absolute)
    while not os.path.isdir(anchor):
        parent = os.path.dirname(anchor)
        if parent == anchor:
            return "unreadable", "존재하는 상위 디렉토리 없음 — 삭제 확정 불가"
        anchor = parent
    top = _run_git(["rev-parse", "--show-toplevel"], anchor)
    root = top.decode("utf-8", "replace").strip() if top is not None else ""
    if not root:
        return "unreadable", "git 저장소 판별 실패 — 삭제 확정 불가(fail-closed)"
    rel = os.path.relpath(os.path.realpath(absolute), os.path.realpath(root))
    if rel == os.curdir or rel.startswith(os.pardir):
        return "unreadable", "git 저장소 밖 경로 — 삭제 확정 불가(fail-closed)"
    rel = rel.replace(os.sep, "/")

    in_index = _run_git(["ls-files", "--error-unmatch", "--", rel], root) is not None
    in_head = _run_git(["cat-file", "-e", f"HEAD:{rel}"], root) is not None
    if in_index or in_head:
        # (A) 추적 파일 삭제 — 마지막 내용을 DB 패턴으로 스캔한다(DB 코드를 지운 것도 DB 관련 변경).
        blob = _run_git(["show", f":{rel}"], root) if in_index else None
        if blob is None and in_head:
            blob = _run_git(["show", f"HEAD:{rel}"], root)
        if blob is None:
            return "unreadable", "git show 실패 — 삭제 전 내용 판독 불가(fail-closed)"
        try:
            content = blob.decode("utf-8", errors="strict")
        except UnicodeDecodeError as exc:
            return "unreadable", f"삭제 전 내용 디코딩 실패 — {exc}"
        mo = DB_CONTACT_PATTERN.search(content)
        if mo:
            return "db_found", _norm(mo.group(0))[:60]
        return "confirmed", "tracked-head-scanned"

    log = _run_git(["log", "--all", "--format=%H", "-1", "--", rel], root)
    if log is None:
        return "unreadable", "git log 실패 — 삭제 확정 불가(fail-closed)"
    if log.strip():
        # (C) 인덱스·HEAD 에 없고 과거 이력에만 있음 — 판정 근거가 모호하다.
        return "unreadable", "과거 이력에만 존재 — 삭제 확정 불가(fail-closed)"
    # (B) 저장소 어디에도 내용이 존재한 적 없음 — 납품물 기여 바이트 0.
    return "confirmed", "untracked-never"


# 2026-10-06 역라우팅 #3 정정 (conv_179129116825): DB 접촉 스캔을 '이번 사이클 변경 줄' 단위로.
#   파일 전체 스캔은 이번에 손대지 않은 기존 DB 문자열(settings.json 의 "Bash(mysql:*)" 등)까지 근거로 삼아
#   비-CRUD 작업을 차단했다. 시작 이전 커밋(base)의 원시 blob 과 작업트리를 difflib 로 비교해
#   추가/제거 줄 + 근접(DB_CONTEXT_WINDOW) 줄만 본다. git diff 는 쓰지 않는다(필터·textconv·rm --cached 우회 차단).
#   폴백: 시작시각 부재·git 아님·base 없음 → 종전 전체 스캔(더 엄격). 저장소인데 git 실패 → unreadable.
DB_CONTEXT_WINDOW = 10
_NO_REPLACE = ["--no-replace-objects"]


# 2026-10-11 사이클181 B (conv_179172160300): 읽기 전용 git 호출 캐시. 판정 규칙은 바꾸지 않고 호출 수만 줄인다.
#   - 캐시는 base_cache 안 예약 키에 둔다 → 수명이 scan_db_contact 1회(같은 base_cache)로 한정된다.
#   - 성공(rc=0) 결과만 기억한다. 실패는 기억하지 않아 다음 호출이 종전처럼 다시 시도한다.
#   - _owning_root·_diff_db_hits_git 의 ls-files/ls-tree 는 저장소별 일괄 목록(ls-files -s -z 1회,
#     ls-tree -r -t -z <base> 1회)을 dict 로 조회한다. -t 를 넣어 base 에서 디렉터리였던 경로도 종전처럼
#     tree 항목을 돌려준다. 인덱스는 상위 디렉터리 집합도 만들어 rel 이 디렉터리일 때 종전 pathspec
#     접두 일치(`ls-files -- rel` 이 하위 파일을 돌려줌)와 같게 한다(R4).
#   - 동치가 확실하지 않은 경우는 종전 개별 호출로 폴백한다: rel 에 pathspec 특수문자(*?[\) 또는 ':' 시작,
#     pathspec 동작을 바꾸는 GIT_*_PATHSPECS 환경변수, rel 의 상위가 gitlink(하위 저장소), 일괄 목록 조회 실패.
#   - status/log(derive_changed_files)·_classify_deleted 는 대상이 아니다(시각 의존·실패 의미 보존).
_GIT_CACHE_ENABLED = True
_GIT_CACHE_KEY = "\0git-cache"  # 절대경로 root 와 겹치지 않는 예약 키
_PATHSPEC_SPECIAL = "*?[\\"
_PATHSPEC_ENV = ("GIT_GLOB_PATHSPECS", "GIT_NOGLOB_PATHSPECS", "GIT_ICASE_PATHSPECS", "GIT_LITERAL_PATHSPECS")


def _git_cache(base_cache):
    """캐시 저장소(dict)를 돌려준다. 캐시가 꺼져 있으면 None."""
    if not _GIT_CACHE_ENABLED:
        return None
    return base_cache.setdefault(_GIT_CACHE_KEY, {"memo": {}, "list": {}})


def _run_git_ro(args, cwd, base_cache):
    """읽기 전용 git 호출. 성공 결과만 base_cache 수명 동안 기억한다."""
    cache = _git_cache(base_cache)
    if cache is None:
        return _run_git(args, cwd)
    key = (tuple(args), cwd)
    if key in cache["memo"]:
        return cache["memo"][key]
    out = _run_git(args, cwd)
    if out is not None:
        cache["memo"][key] = out
    return out


def _bulk_lookup_ok(rel):
    """일괄 목록 조회가 종전 pathspec 개별 호출과 동치인 rel 인가."""
    if rel.startswith(":") or any(ch in rel for ch in _PATHSPEC_SPECIAL):
        return False
    return not any(os.environ.get(k) for k in _PATHSPEC_ENV)


def _ancestors(rel):
    """'a/b/c' → ['a', 'a/b'] (자기 자신 제외)."""
    parts = rel.split("/")
    return ["/".join(parts[:i]) for i in range(1, len(parts))]


def _parse_listing(out, kind_field, link_value):
    """-z 목록을 {경로: 원 항목 bytes}, gitlink 집합으로 바꾼다."""
    entries, links = {}, set()
    for rec in out.split(b"\0"):
        if not rec:
            continue
        meta, _, raw = rec.partition(b"\t")
        path = raw.decode("utf-8", "surrogateescape")
        entries.setdefault(path, rec)
        fields = meta.split()
        if len(fields) > kind_field and fields[kind_field] == link_value:
            links.add(path)
    return entries, links


def _bulk_listing(key, args, root, base_cache, kind_field, link_value, with_dirs):
    """저장소별 일괄 목록을 1회 조회해 기억한다. 실패하면 None(기억하지 않음)."""
    lists = _git_cache(base_cache)["list"]
    if key in lists:
        return lists[key]
    out = _run_git(["-C", root] + _NO_REPLACE + args, root)
    if out is None:
        return None
    entries, links = _parse_listing(out, kind_field, link_value)
    dirs = set()
    if with_dirs:
        for path in entries:
            dirs.update(_ancestors(path))
    lists[key] = (entries, dirs, links)
    return lists[key]


def _index_has(root, rel, base_cache):
    """종전 `ls-files -z -- rel` 결과가 비어 있지 않은가. 반환: True/False, git 실패면 None."""
    if _git_cache(base_cache) is not None and _bulk_lookup_ok(rel):
        listing = _bulk_listing(("index", root), ["ls-files", "-s", "-z"], root, base_cache,
                                0, b"160000", True)
        if listing is not None:
            entries, dirs, links = listing
            if not any(a in links for a in _ancestors(rel)):
                return rel in entries or rel in dirs
    out = _run_git_ro(["-C", root] + _NO_REPLACE + ["ls-files", "-z", "--", rel], root, base_cache)
    if out is None:
        return None
    return bool(out.strip(b"\0"))


def _tree_entry(root, base, rel, base_cache):
    """종전 `ls-tree -z <base> -- rel` 출력과 같은 bytes(첫 항목 + NUL 또는 b"")를 돌려준다. git 실패면 None."""
    if _git_cache(base_cache) is not None and _bulk_lookup_ok(rel):
        listing = _bulk_listing(("tree", root, base), ["ls-tree", "-r", "-t", "-z", base], root, base_cache,
                                1, b"commit", False)
        if listing is not None:
            entries, _, links = listing
            if not any(a in links for a in _ancestors(rel)):
                rec = entries.get(rel)
                return rec + b"\0" if rec is not None else b""
    return _run_git_ro(["-C", root] + _NO_REPLACE + ["ls-tree", "-z", base, "--", rel], root, base_cache)


# [사이클196 oi-fix-1 P2] item_crud:false 경로 책임 이전(ITEM_CRUD_FALSE_PATH_COVERED)의 적용 시작 시각.
#   이 시각 이후 시작한 파이프라인(session-env/<UUID>/pipeline_start_time)에만 켠다 — 진행 중 사이클(c196, 시작 07:58)의
#   판정 기준을 사이클 도중 바꿔 자기 마커를 통과시키는 일을 막는다. 시작 시각을 읽지 못하면 끈다(종전 동작).
#   환경변수 VCE_ITEM_CRUD_FALSE_COVER=0 은 강제 OFF 만 한다(강제 ON 수단은 두지 않는다 — 에이전트 셸에서 켤 수 없게).
ITEM_CRUD_FALSE_COVER_SINCE = 1792724295  # 2026-10-23 11:58:15 KST


def _item_crud_false_cover_enabled(session_dir):
    if os.environ.get("VCE_ITEM_CRUD_FALSE_COVER") == "0":
        return False, "VCE_ITEM_CRUD_FALSE_COVER=0(강제 OFF)"
    st = _read_start_time(session_dir) if session_dir else None
    if st is None:
        return False, "pipeline_start_time 판독 불가(기본 OFF)"
    if st >= ITEM_CRUD_FALSE_COVER_SINCE:
        return True, f"파이프라인 시작 {st} ≥ 도입 {ITEM_CRUD_FALSE_COVER_SINCE}"
    return False, f"파이프라인 시작 {st} < 도입 {ITEM_CRUD_FALSE_COVER_SINCE}(진행 중 사이클 — 다음 사이클부터 적용)"


def _read_start_time(session_dir):
    """pipeline_start_time(정수 epoch)을 읽는다. 부재/파싱 실패면 None."""
    try:
        with open(os.path.join(session_dir, "pipeline_start_time"), "r", encoding="utf-8") as fp:
            return int(fp.read().strip())
    except (OSError, ValueError):
        return None


def _scan_base(root, start):
    """저장소의 base 커밋을 정한다. 반환: ("base", sha) / ("none", 사유) / ("error", 사유)."""
    git = ["-C", root] + _NO_REPLACE
    if _run_git(git + ["rev-parse", "--verify", "-q", "HEAD^{commit}"], root) is None:
        return "none", "HEAD 없음(unborn)"
    listing = _run_git(git + ["rev-list", "--first-parent", "--timestamp", "--max-count=500", "HEAD"], root)
    objdir = _run_git(git + ["rev-parse", "--git-path", "objects"], root)
    if listing is None or objdir is None:
        return "error", "rev-list/git-path 실패"
    objdir = objdir.decode("utf-8", "replace").strip()
    if not os.path.isabs(objdir):
        objdir = os.path.join(root, objdir)
    for line in listing.decode("utf-8", "replace").splitlines():
        parts = line.split()
        if len(parts) != 2 or not parts[0].isdigit():
            return "error", f"rev-list 출력 해석 실패: {line[:40]}"
        ts, sha = int(parts[0]), parts[1]
        if ts > start:
            continue  # (a) committer 시각이 시작 이후
        loose = os.path.join(objdir, sha[:2], sha[2:])
        try:
            if os.stat(loose).st_mtime > start:
                continue  # (b) 실제 기록 시각이 시작 이후(커밋 시각 위조 대비)
        except FileNotFoundError:
            pass  # 팩된 객체 — (a) 만 적용
        except OSError as exc:
            return "error", f"객체 파일 확인 실패: {exc}"
        return "base", sha
    return "none", "시작 이전 커밋 없음(500개 내)"


def _split_lines(text):
    """선두 BOM 제거 + 줄 분할 + 줄 끝 CR 제거(줄바꿈 차이만으로 전 줄이 변경되는 것을 막는다)."""
    if text.startswith("﻿"):
        text = text[1:]
    return [ln[:-1] if ln.endswith("\r") else ln for ln in text.split("\n")]


def _match_ranges(lines, pattern=None):
    """DB_CONTACT_PATTERN(또는 pattern) 매치마다 (시작줄, 끝줄, 매치) 를 0-기준 줄 번호로 반환한다."""
    pattern = pattern or DB_CONTACT_PATTERN
    text = "\n".join(lines)
    return [(text.count("\n", 0, mo.start()), text.count("\n", 0, mo.end()), mo.group(0))
            for mo in pattern.finditer(text)]


def _near(ranges, lo, hi):
    """블록 [lo, hi] 와 DB_CONTEXT_WINDOW 줄 이내인 매치를 반환한다. 없으면 None."""
    for a, b, m in ranges:
        if max(0, lo - b, a - hi) <= DB_CONTEXT_WINDOW:
            return m
    return None


def _base_for(root, start, base_cache):
    """저장소별 base 를 1회 계산·캐시하고 DB_SCAN_BASE 를 1회 출력한다."""
    if root not in base_cache:
        base_cache[root] = _scan_base(root, start)
        kind, info = base_cache[root]
        shown = info[:12] if kind == "base" else "none"
        reason = "시작 이전 첫 커밋" if kind == "base" else info
        print(f"DB_SCAN_BASE: {root} base={shown} ({reason})")
    return base_cache[root]


def _owning_root(absolute, start, base_cache):
    """파일을 실제로 추적하는 가장 가까운 저장소를 찾는다(중첩 저장소 보정).

    상위로 올라가며 후보 저장소의 인덱스(ls-files) 또는 base 트리(ls-tree)에 경로가 있는지 본다.
    반환: ("root", root, rel) / ("full", 사유) — 추적 저장소 없음·저장소 밖 / ("unreadable", 사유) — 후보 git 실패.
    """
    probe = os.path.dirname(absolute)
    nearest = None
    while True:
        top = _run_git_ro(["-C", probe] + _NO_REPLACE + ["rev-parse", "--show-toplevel"], probe, base_cache)
        root = top.decode("utf-8", "replace").strip() if top is not None else ""
        if not root:
            break
        rel = os.path.relpath(os.path.realpath(absolute), os.path.realpath(root))
        if rel == os.curdir or rel.startswith(os.pardir):
            break
        rel = rel.replace(os.sep, "/")
        nearest = nearest or (root, rel)
        indexed = _index_has(root, rel, base_cache)
        if indexed is None:
            return "unreadable", f"ls-files 실패({root}) — fail-closed"
        if indexed:
            _base_for(root, start, base_cache)
            return "root", root, rel
        kind, info = _base_for(root, start, base_cache)
        if kind == "error":
            return "unreadable", f"base 산출 실패({root}) — {info}(fail-closed)"
        if kind == "base":
            in_base = _tree_entry(root, info, rel, base_cache)
            if in_base is None:
                return "unreadable", f"ls-tree 실패({root}) — fail-closed"
            if in_base.strip(b"\0"):
                return "root", root, rel
        parent = os.path.dirname(root)
        if parent == root:
            break
        probe = parent
    if nearest is None:
        return "full", "git 저장소 밖"
    return "full", f"추적 저장소 없음({nearest[0]}) — base 에 없는 경로"


# 2026-10-10 conv_179160716700 (F-CRUD-1 오탐 근본 수정 R1): untracked 파일 기준선.
#   untracked 파일은 git base 가 없어 전체 스캔됐고, 파이프라인 이전부터 있던 SQL 픽스처 문자열을
#   "이번 변경"으로 오판했다. write_guard 가 편집 직전 원본을 보관한 기준선이 있으면 그것과 diff 하고,
#   기준선이 없어도 mtime·ctime 이 모두 시작 이전이면 이번 파이프라인에서 손대지 않은 파일이다.
#   기준선은 (a) .path 내용 == 대상 realpath (b) 기준선 자신이 이번 파이프라인에서 생성(max(mtime,ctime) ≥ start)
#   일 때만 인정한다. 그 외는 없는 것으로 보고 종전 판정(시각 판정 → 전체 스캔)으로 떨어진다(fail-closed).
#   ctime 은 사용자가 되돌릴 수 없으므로(touch -d 는 mtime 만 바꾼다) 시각 위조로 회피할 수 없다.
BASELINE_DIRNAME = "baseline_untracked"


# 2026-10-10 역라우팅 #1 (otest 실측): pipeline_start_time 을 DML 선삽입 직후 시각으로 다시 쓰면
#   SKIP_PREEXISTING 이 DML 이 든 신규 untracked 파일을 clean 으로 넘겼다(종전 판정기는 rc=1).
#   1차 방어는 write_guard 의 쓰기 차단이고, 여기는 2차 방어다. 아래 중 하나라도 해당하면 시작시각을
#   신뢰하지 않고 완화 경로(기준선·미변경 skip)를 끈다 → 종전 전체 스캔(fail-closed).
#     (a) 시작시각이 현재보다 미래
#     (b) pipeline_start_time 파일의 ctime·mtime 이 내용값보다 START_REWRITE_TOLERANCE 초 이상 늦다(나중에 다시 쓴 흔적 —
#         ctime 은 되돌릴 수 없다)
#     (c) evidence/ok_started(진입 시 같은 시점 기록)가 없거나(ok_started_missing — 역라우팅 #2), 내용값·ctime 이
#         시작시각과 허용치 이상 어긋난다
#     (d) 시작시각 파일 판독 실패
#   잔존 한계: 두 파일을 같은 순간에 모두 다시 쓰면 (b)(c) 로는 구별되지 않는다 — 1차(write_guard) 차단이 담당한다.
START_REWRITE_TOLERANCE = 120
_START_TRUST_CACHE = {}


def _start_time_trusted(session_dir, start):
    """시작시각을 완화 경로의 근거로 써도 되는가. 판정은 세션당 1회, 무효면 START_TIME_UNTRUSTED 를 1회 출력한다."""
    import time
    if not session_dir or start is None:
        return False
    key = (session_dir, start)
    if key in _START_TRUST_CACHE:
        return _START_TRUST_CACHE[key]
    reason = None
    try:
        st = os.stat(os.path.join(session_dir, "pipeline_start_time"))
        if start > time.time():
            reason = f"시작시각 {start} 이 현재보다 미래"
        elif max(st.st_ctime, st.st_mtime) - start >= START_REWRITE_TOLERANCE:
            late = max(st.st_ctime, st.st_mtime)
            reason = (f"pipeline_start_time 파일 ctime/mtime {int(late)} 이 내용값 {start} 보다 "
                      f"{int(late - start)}초 늦음 — 나중에 다시 쓴 흔적")
        else:
            ok_path = os.path.join(session_dir, "evidence", "ok_started")
            # 역라우팅 #2: ok_started 부재도 무효다. 전제 — ok 진입 경로(/ok·/o1~/o5·oroof(구 oralph)·oto 등)는 모두 ok 를
            #   경유해 evidence/ok_started 를 시작시각과 같은 시점에 만든다(odev-2 확인). 부재를 "확인 생략"으로
            #   두면 'ok_started 삭제 + 시작시각 재기록' 으로 (c) 교차 확인이 통째로 무력화된다(otest 실증).
            if not os.path.lexists(ok_path):
                reason = "ok_started_missing — evidence/ok_started 부재로 시작시각 교차 확인 불가"
            else:
                ok_st = os.lstat(ok_path)
                with open(ok_path, "r", encoding="utf-8") as fp:
                    raw = fp.read().strip()
                ok_val = int(raw) if raw.isdigit() else None
                if ok_val is not None and abs(ok_val - start) >= START_REWRITE_TOLERANCE:
                    reason = f"evidence/ok_started 값 {ok_val} 과 시작시각 {start} 불일치"
                elif abs(ok_st.st_ctime - start) >= START_REWRITE_TOLERANCE:
                    reason = f"evidence/ok_started ctime {int(ok_st.st_ctime)} 과 시작시각 {start} 불일치"
    except (OSError, ValueError) as exc:
        reason = f"시작시각 파일 판독 실패({exc})"
    if reason:
        print(f"START_TIME_UNTRUSTED: {reason} — 기준선·미변경 skip 을 쓰지 않고 종전 전체 스캔(fail-closed)")
    _START_TRUST_CACHE[key] = reason is None
    return reason is None


def _untracked_baseline(path, session_dir, start):
    """현재 파이프라인의 유효한 기준선 원본 줄 목록을 반환한다. 반환: (lines|None, 사유)."""
    import hashlib
    if not session_dir or start is None:
        return None, "세션/시작시각 없음"
    real = os.path.realpath(path)
    stem = os.path.join(session_dir, BASELINE_DIRNAME, hashlib.sha1(real.encode("utf-8")).hexdigest())
    orig, meta = stem + ".orig", stem + ".path"
    if not os.path.lexists(orig):
        return None, "기준선 없음"
    try:
        with open(meta, "r", encoding="utf-8") as fp:
            recorded = fp.read().strip()
        st = os.lstat(orig)
        if os.path.islink(orig) or recorded != real:
            return None, "기준선 .path 불일치"
        if max(st.st_mtime, st.st_ctime) < start:
            return None, "이전 파이프라인 기준선"
        with open(orig, "r", encoding="utf-8", errors="strict") as fp:
            return _split_lines(fp.read()), "기준선"
    except (OSError, UnicodeDecodeError) as exc:
        return None, f"기준선 판독 실패({exc})"


def _untouched_since(path, start):
    """대상 파일의 mtime·ctime 이 모두 시작 이전인가(= 이번 파이프라인에서 미변경)."""
    try:
        st = os.stat(path)
    except OSError:
        return False
    return max(st.st_mtime, st.st_ctime) < start


def _diff_lines_hits(old, new, pattern=None):
    """base 줄 목록과 현재 줄 목록을 비교해 변경 줄 + 근접 DB 매치를 찾는다. 반환: ("clean", None) / ("hit", 근거)."""
    import difflib
    pattern = pattern or DB_CONTACT_PATTERN
    old_ranges, new_ranges = _match_ranges(old, pattern), _match_ranges(new, pattern)
    ops = difflib.SequenceMatcher(None, old, new, autojunk=False).get_opcodes()
    for tag, i1, i2, j1, j2 in ops:
        if tag in ("replace", "insert"):
            mo = pattern.search("\n".join(new[j1:j2]))
            if mo:
                return "hit", f"L{j1 + 1}+: {_norm(mo.group(0))[:60]}"
        if tag in ("replace", "delete"):
            mo = pattern.search("\n".join(old[i1:i2]))
            if mo:
                return "hit", f"L{i1 + 1}-: {_norm(mo.group(0))[:60]}"
    for tag, i1, i2, j1, j2 in ops:
        if tag in ("replace", "insert"):
            m = _near(new_ranges, j1, j2 - 1)
            if m:
                return "hit", f"L{j1 + 1}근접: {_norm(m)[:60]}"
        if tag in ("replace", "delete"):
            m = _near(old_ranges, i1, i2 - 1)
            if m:
                return "hit", f"L{i1 + 1}근접(제거): {_norm(m)[:60]}"
    return "clean", None


def _diff_db_hits(path, content, start, base_cache, session_dir=None, pattern=None):
    """변경 줄 단위 DB 검사. 반환: ("full", 사유) / ("clean", None) / ("hit", 근거) / ("unreadable", 사유)."""
    if start is None:
        return "full", "pipeline_start_time 부재"
    result = _diff_db_hits_git(path, content, start, base_cache, pattern)
    if result[0] != "full":
        return result
    # git base 로 비교할 수 없는 파일(untracked 등) — 기준선 diff → 미변경 skip → 종전 전체 스캔.
    #   두 완화 경로는 시작시각을 근거로 삼으므로, 시작시각이 변조 흔적을 보이면 쓰지 않는다.
    if not _start_time_trusted(session_dir, start):
        return result
    old, why = _untracked_baseline(path, session_dir, start)
    if old is not None:
        print(f"DB_SCAN_BASELINE: {path} (편집 직전 기준선 대비 변경 줄만 검사)")
        return _diff_lines_hits(old, _split_lines(content), pattern)
    if why != "기준선 없음" and why != "세션/시작시각 없음":
        print(f"DB_SCAN_BASELINE_IGNORED: {path} ({why})")
    if _untouched_since(path, start):
        print(f"DB_SCAN_SKIP_PREEXISTING: {path} (mtime·ctime 모두 시작 이전 — 이번 파이프라인 미변경)")
        return "clean", None
    return result


def _diff_db_hits_git(path, content, start, base_cache, pattern=None):
    """git base 대비 변경 줄 단위 DB 검사(기존 판정). 반환 형식은 _diff_db_hits 와 같다."""
    owner = _owning_root(os.path.abspath(path), start, base_cache)
    if owner[0] != "root":
        return owner
    _, root, rel = owner
    kind, info = base_cache[root]
    if kind == "none":
        return "full", f"base 없음 — {info}"
    if kind == "error":
        return "unreadable", f"base 산출 실패 — {info}(fail-closed)"
    base = info

    git = ["-C", root] + _NO_REPLACE
    tree = _tree_entry(root, base, rel, base_cache)
    if tree is None:
        return "unreadable", "ls-tree 실패(fail-closed)"
    entry = tree.decode("utf-8", "replace").split("\0")[0]
    if not entry:
        return "full", "base 에 없는 경로"
    meta = entry.split("\t", 1)[0].split()
    if len(meta) != 3 or meta[1] != "blob":
        return "unreadable", f"base 항목이 blob 아님({entry[:40]})"
    blob = _run_git_ro(git + ["cat-file", "blob", meta[2]], root, base_cache)
    if blob is None:
        return "unreadable", "cat-file 실패 — base 내용 판독 불가(fail-closed)"
    try:
        old = _split_lines(blob.decode("utf-8", errors="strict"))
    except UnicodeDecodeError as exc:
        return "unreadable", f"base 내용 디코딩 실패 — {exc}"
    return _diff_lines_hits(old, _split_lines(content), pattern)


# ★배정표 디렉터리 표기 전개★ (사이클214 R1-나 — 배정표 146행 디렉터리 표기가 판독 불가로 남아 무해 확인 불가)
#   끝이 "/" 인 실재 디렉터리는 그 아래 일반 파일을 개별 판독 대상으로 펼친다(더 많이 읽는 쪽 — 완화 아님).
#   제외: bin·obj·.git·node_modules·__pycache__ 하위. 상한 초과·권한 오류·일반 파일 0개는 종전대로 판독 불가.
#   와일드카드(* ?)·"\" 끝 표기·부재 디렉터리는 전개하지 않는다(종전대로 판독 불가).
DIR_EXPAND_EXCLUDE = {"bin", "obj", ".git", "node_modules", "__pycache__"}
DIR_EXPAND_LIMIT = 200


def _expand_assigned_dir(path):
    """디렉터리 표기 1개 → (파일 목록, None) / (None, 판독 불가 사유)."""
    # 2026-11-06 과제3: 끝 "/" 유무와 무관하게 실재 디렉터리(최상위 디렉터리 symlink 포함)면 전개한다.
    #   최상위만 realpath 로 바꿔 walk 한다. 하위 링크 디렉터리·상한·일반 파일 0개·walk 오류는 종전대로 판독 불가.
    if any(ch in path for ch in "*?") or path.endswith("\\") or not os.path.isdir(path):
        return None, "와일드카드/디렉토리 표기 — 개별 판독 불가"
    found, errors = [], []
    for root, dirs, names in os.walk(os.path.realpath(path), onerror=errors.append):
        dirs[:] = sorted(d for d in dirs if d not in DIR_EXPAND_EXCLUDE)
        for d in dirs:
            # os.walk 는 디렉터리 링크를 따라가지 않아 조용히 빠진다 → 판독 누락 대신 판독 불가로 본다.
            if os.path.islink(os.path.join(root, d)):
                return None, f"디렉토리 표기 안 링크 디렉터리({os.path.join(root, d)}) — 개별 판독 불가"
        for name in sorted(names):
            full = os.path.join(root, name)
            if os.path.isfile(full):
                found.append(full)
                if len(found) > DIR_EXPAND_LIMIT:
                    return None, f"디렉토리 표기 전개 상한({DIR_EXPAND_LIMIT}개) 초과 — 개별 판독 불가"
    if errors:
        return None, f"디렉토리 표기 전개 실패 — {errors[0]}"
    if not found:
        return None, "디렉토리 표기 전개 결과 일반 파일 0개 — 개별 판독 불가"
    return found, None


def scan_db_contact(file_assignment_path, exclude_test_fixtures=False):
    """변경 파일 전수를 열어 DB 접속/DML 흔적을 실측한다.

    exclude_test_fixtures=True (--exclude-test-fixtures): 시험 픽스처(TEST_FIXTURE_RE) 파일의 매치를
      DB_SCAN_TEST_FIXTURE_EXCLUDED 로 출력하고 hits 에서 뺀다. 판독·판독 실패 처리는 그대로다.
    db_found 일 때 detail["fixture_only"] 는 매치 파일이 전부 픽스처인지(정보용 — 판정에 쓰지 않는다).

    반환값: (clean: bool, detail: dict)
      clean=True  → 전수 판독 성공 + DB 패턴 0건. ★이때만 면제 가능★.
      clean=False → 면제 불가. detail["reason"] 이 사유:
        "no_assignment" : file_assignment.json 부재/파싱 실패 (확인 불가)
        "no_files"      : files 목록이 비어 있음 (대조 대상 없음)
        "unreadable"    : 1개 이상 판독 실패 (권한/부재/인코딩)
        "db_found"      : DB 패턴 발견 → detail["hits"] 에 (파일, 매치) 목록
      detail["deleted"] : 삭제 확정 (파일, untracked-never|tracked-head-scanned) 목록 (2026-10-06 역라우팅 #2)
    """
    all_files = []
    try:
        with open(file_assignment_path, "r", encoding="utf-8") as fp:
            assignment = json.load(fp)
    except FileNotFoundError as exc:
        # 2026-10-06 정정: 부재일 때만 독립 산출 폴백. 삭제된 파일은 DB 코드가 없으므로 판독 제외.
        derived, _derr = derive_changed_files(os.path.dirname(file_assignment_path))
        if derived is None:
            return False, {"reason": "no_assignment", "error": str(exc)}
        assignment = {}
        all_files.extend(p for p in derived if os.path.exists(p))
    except (OSError, json.JSONDecodeError) as exc:
        return False, {"reason": "no_assignment", "error": str(exc)}

    # 사이클197 (d): dict·상대경로 항목이 있으면 무접촉 실측도 근거가 없다(fail-closed).
    bad_reason = _assignment_unverifiable(assignment, file_assignment_path)
    if bad_reason:
        return False, {"reason": "no_assignment", "error": bad_reason}

    # 사이클172 C25: agents 단일 형식 → 다중 스키마 합집합(_files_from_assignment).
    #   2026-10-06 역라우팅 #2 규칙(같은 그룹 files 에 있는 경로만 삭제 선언 인정)은 헬퍼가 유지한다.
    assigned, deleted_declared = _files_from_assignment(assignment)
    all_files.extend(assigned)

    if not all_files:
        return False, {"reason": "no_files"}

    # 2026-10-06 정정 (사유: 판정기 자기 참조 오탐, 사용자 승인 "게이트 자기 파일만 예외"):
    #   판정기 자신과 그 테스트는 DB 패턴 목록·픽스처 문자열을 품고 있어 항상 DB 접촉으로 잡혔다.
    #   realpath 정확 일치 2개 파일만 DB 접촉 스캔에서 제외한다(부분일치·glob·디렉토리 단위 금지).
    #   제외 후 남은 파일이 없으면 판독 대상이 없을 뿐 "목록 부재"가 아니므로 clean 이다.
    all_files = [p for p in all_files if not _is_gate_self_file(p)]

    hits, unreadable, deleted = [], [], []
    # 사이클214 R1-나: 디렉터리 표기는 그 아래 일반 파일로 전개해 같은 판독을 한다(_expand_assigned_dir).
    expanded = []
    for path in all_files:
        if any(ch in path for ch in "*?") or path.endswith(("/", "\\")) or os.path.isdir(path):
            sub, why = _expand_assigned_dir(path)
            if sub is None:
                # 와일드카드/전개 불가 디렉토리 표기는 "무해 확인" 이 불가능하므로 판독 실패로 본다.
                unreadable.append((path, why))
                continue
            expanded.extend(p for p in sub if p not in expanded and not _is_gate_self_file(p))
        else:
            expanded.append(path)
    all_files = expanded
    start, base_cache = _read_start_time(os.path.dirname(file_assignment_path)), {}
    for path in all_files:
        # 2026-10-06 역라우팅 #2: 선언 + 부재 실측일 때만 git 분류. 존재하면 선언을 무시하고 일반 판독한다.
        if path in deleted_declared and not os.path.lexists(path):
            kind, info = _classify_deleted(path)
            if kind == "confirmed":
                deleted.append((path, info))
                print(f"DELETED_CONFIRMED: {path} ({info})")
            elif kind == "db_found":
                hits.append((path, info))
            else:
                unreadable.append((path, info))
            continue
        try:
            with open(path, "r", encoding="utf-8", errors="strict") as fp:
                content = fp.read()
        except (OSError, UnicodeDecodeError) as exc:
            unreadable.append((path, str(exc)))
            continue
        # 2026-10-06 역라우팅 #3: diff 가능하면 변경 줄+근접만, 아니면 종전 전체 스캔.
        mode, info = _diff_db_hits(path, content, start, base_cache,
                                   session_dir=os.path.dirname(file_assignment_path))
        if mode == "hit" and _is_doc_config(path):
            # 2026-10-20 역라우팅 #1: 같은 범위를 DML/DDL 로만 다시 본다(재실행의 정보 줄 중복 출력은 버린다).
            import contextlib
            import io
            with contextlib.redirect_stdout(io.StringIO()):
                dmode, dinfo = _diff_db_hits(path, content, start, base_cache,
                                             session_dir=os.path.dirname(file_assignment_path),
                                             pattern=_doc_dml_pattern(path))
            if dmode == "clean":
                print(f"DB_NAME_MENTION_DOC_EXCLUDED: {path}: {info}")
                continue
            mode, info = dmode, (dinfo if dmode == "hit" else info)
        if mode == "hit" and not _is_doc_config(path):
            # 2026-10-24: 코드 파일의 이름 언급만(DML 0건 + 파일 전체 접근 형태 0건) 정보 줄로 바꾼다.
            import contextlib
            import io
            with contextlib.redirect_stdout(io.StringIO()):
                dmode, _dinfo = _diff_db_hits(path, content, start, base_cache,
                                              session_dir=os.path.dirname(file_assignment_path),
                                              pattern=DB_DML_PATTERN)
            if dmode == "clean":
                akind, _ainfo = _code_db_access(path, content)
                if akind == "mention":
                    print(f"DB_NAME_MENTION_CODE_EXCLUDED: {path}: {info}")
                    continue
        if mode == "hit":
            hits.append((path, info))
        elif mode == "unreadable":
            unreadable.append((path, info))
        elif mode == "full":
            print(f"DB_SCAN_FULL: {path} ({info})")
            doc = _is_doc_config(path)
            if not doc and not DB_DML_PATTERN.search(content):
                mo = DB_CONTACT_PATTERN.search(content)
                if mo:
                    akind, _ainfo = _code_db_access(path, content)
                    if akind == "mention":
                        print(f"DB_NAME_MENTION_CODE_EXCLUDED: {path}: {_norm(mo.group(0))[:60]}")
                        continue
            for mo in (_doc_dml_pattern(path) if doc else DB_CONTACT_PATTERN).finditer(content):
                hits.append((path, _norm(mo.group(0))[:60]))
                break  # 파일당 1건만 보고하면 충분하다
            else:
                mo = DB_CONTACT_PATTERN.search(content) if doc else None
                if mo:
                    print(f"DB_NAME_MENTION_DOC_EXCLUDED: {path}: {_norm(mo.group(0))[:60]}")

    fixture_excluded = []
    if exclude_test_fixtures and hits:
        fixture_excluded = [(p, m) for p, m in hits if _is_test_fixture(p)]
        hits = [(p, m) for p, m in hits if not _is_test_fixture(p)]
        for p, m in fixture_excluded:
            print(f"DB_SCAN_TEST_FIXTURE_EXCLUDED: {p}: {m}")

    if unreadable:
        return False, {"reason": "unreadable", "unreadable": unreadable,
                       "total": len(all_files), "deleted": deleted}
    if hits:
        return False, {"reason": "db_found", "hits": hits, "total": len(all_files),
                       "deleted": deleted,
                       "fixture_only": all(_is_test_fixture(p) for p, _ in hits)}
    if deleted:
        # 삭제 확정은 판독 대상에서 뺀다. 남은 판독 0 + HEAD 스캔 0 이면 실제로 본 것이 없다 → no_files.
        gone = {p for p, _ in deleted}
        all_files = [p for p in all_files if p not in gone]
        if not all_files and not any(k == "tracked-head-scanned" for _, k in deleted):
            return False, {"reason": "no_files", "deleted": deleted}
    return True, {"total": len(all_files), "files": all_files, "deleted": deleted}


def is_non_crud_declared(data, file_assignment_path):
    """acceptance_criteria.json 최상위의 crud_대상=false 선언이 유효한 면제인가.

    반환값: (exempt: bool, invalid_reason: str|None)
      exempt=True  → 면제 (invalid_reason=None)
      exempt=False → 면제 아님. invalid_reason 으로 무효화 사유를 구분한다:
        - None            :애초에 crud_대상=false 선언 자체가 없음(필드 부재/불충분) — 기존 정상 흐름
        - "none"          : crud_대상 필드 자체가 부재 — "파일 레벨 선언을 하지 않았다"는
                            뜻이며 "검증 불가"가 아니다. item_crud 항목 레벨 선언은
                            파일 레벨 선언 유무와 독립적으로 유효해야 하므로 trust_item_crud
                            를 꺾지 않는다(★A8 결함 수정의 핵심★). item_crud:false 개별
                            선언의 거짓 여부는 main() 의 경로 재대조(load_crud_suspect_files)
                            가 여전히 담당한다.
        - "content"       : AC 본문이 실제 CRUD 를 요구 — 그 항목(content_suspects)이
                            이미 특정됐으므로 main() 이 항목 단위로 계속 처리 가능
        - "path"          : file_assignment.json 의 실제 변경 파일이 CRUD 의심 경로 —
                            AC 항목 텍스트와 무관한 구조적 모순이므로 항목 단위로 흡수되지
                            않는다. main() 은 이 경우 즉시 차단해야 한다(★회귀 수정의 핵심★).
        - "unverifiable"  : file_assignment.json 로드 실패 — 판정 불가(진짜 검증 불가능)

    ★왜 tri-state 로 나눴나 (회귀 수정, odev, 팀리드 지시)★:
      기존에는 bool 하나만 반환해 "path 기인 무효화"와 "그냥 선언 자체가 없음"을
      main() 이 구분할 수 없었다. 그래서 path 기인으로 CRUD_DECLARATION_OVERRIDDEN
      로그가 찍혀도 main() 은 그냥 다음 단계(항목별 is_crud_item)로 넘어갔고,
      거기서 item_crud=False 전부이면 raw_crud 가 비어 RC=0 으로 새어나갔다.
      path 기인 무효화는 애초에 "이 AC 항목들이 CRUD 증거를 요구하는가"와 무관한
      구조적 모순(선언 vs 실제 변경 파일)이므로, 항목 재판정으로 흡수시키면 안 되고
      즉시 차단해야 한다 — 이것이 요청받은 "경로 기반 override 를 최우선으로" 의 의미다.

    fail-closed 원칙 (유지):
      - crud_대상 이 False 가 아니면(필드 없음 포함) → (False, None) (면제 아님, 기존 로직 그대로)
      - crud_대상=False 인데 crud_미해당_사유 가 비어 있으면 → (False, None) (선언 불충분)
      - ★AC 본문이 CRUD 를 요구★(is_crud_item) 하는데 ★검증형 맥락이 아니면★
        (is_inspection_only 가 False) → (False, "content") (자기모순 선언 — 면제 무효화)
        판정 근거: 역라우팅 2회차 지시 — 파일 경로보다 AC 내용이 더 신뢰할 수 있는 신호.
        기존 is_crud_item/is_inspection_only 를 그대로 재사용해 어휘 상수를 새로 만들지 않는다.
      - file_assignment.json 로드 실패 → (False, "unverifiable") (판정 불가)
      - file_assignment.json 의 files 가 CRUD 의심 패턴과 하나라도 매치 → (False, "path")
        (거짓 선언으로 게이트 무력화 시도 — 선언 무효화, 경로 기반 보조 수단이 최우선)
      - 위 전부 통과 → (True, None) (면제)
    """
    if not isinstance(data, dict):
        return False, None
    if "crud_대상" not in data:
        # ★A8 — F-CRUD-1 잔존 결함 수정★ (odev, 팀리드 지시, 2026-08-30):
        #   crud_대상 필드 자체가 부재(가장 흔한 정상 케이스)한 경우를 종전에는
        #   "unverifiable" 과 동일 취급해 trust_item_crud=False 를 강제했다.
        #   그 결과 item_crud 구조화 필드(사이클45 도입)가 파일 레벨 선언이
        #   없다는 이유만으로 거의 항상 무력화되고, 항목별 판정이 매번
        #   자연어 폴백(category/CRUD_KEYWORDS)으로 되돌아갔다.
        #
        #   의미론 정리: crud_대상=false 는 "이 파일 전체가 비-CRUD"라는
        #   ★파일 레벨★ 선언이다. crud_대상 필드 부재는 그 파일 레벨 선언을
        #   ★하지 않았다★는 뜻일 뿐 "검증 불가"가 아니다. item_crud 는
        #   ★항목 레벨★ 선언이며 파일 레벨 선언 유무와 독립적으로 유효해야 한다.
        #   ⇒ 부재는 파일 레벨 면제(exempt=True)를 주지 않을 뿐이며,
        #     item_crud 항목 레벨 판정까지 무력화할 이유가 없다.
        #
        #   "선언은 검증을 이길 수 없다" 균형은 그대로 유지된다:
        #     item_crud:false 개별 선언의 거짓 여부는 main() 의
        #     item_crud_suspect_files 재대조(load_crud_suspect_files)가
        #     trust_item_crud 값과 무관하게 항상 수행한다 — 이 재대조는
        #     invalid_reason 이 아니라 exempted 루프에서 별도로 돈다.
        return False, "none"
    if data.get("crud_대상") is not False:
        # crud_대상 필드가 존재하지만 False 가 아닌 값(true 등) — 명시적으로
        # "이 파일은 CRUD 대상이다"라고 선언한 것과 같은 취급이다. 필드 부재와
        # 달리 판정 가능한 명시값이 있으므로 기존처럼 무효화 처리한다. 단
        # "unverifiable"(검증 불가)이 아니라 애초에 면제 선언이 아니므로
        # trust_item_crud 를 꺾을 이유가 없다 — None 으로 되돌린다(기존 정상 흐름).
        return False, None

    reason = str(data.get("crud_미해당_사유", "")).strip()
    if not reason:
        print(
            "CRUD_DECLARATION_INSUFFICIENT: crud_대상=false 인데 crud_미해당_사유 가 비어있음 — "
            "면제 거부(fail-closed)",
            file=sys.stderr,
        )
        return False, None

    # ★경로 기반 검사를 최우선으로★ (회귀 수정, odev, 팀리드 지시)
    #   "선언(item_crud)이 검증(경로 재대조)을 이기면 검증이 존재할 이유가 없다."
    #   AC 본문 검사보다 먼저 실제 변경 파일을 본다 — 파일 경로는 작성자의 자연어
    #   선택과 무관한 객관적 사실이므로, 이것이 CRUD 의심 경로면 AC 본문 판정을
    #   거칠 필요도 없이 즉시 무효화한다.
    #   ★배선 확장(odev, 팀리드 지시)★: 이 로직은 load_crud_suspect_files() 로
    #   분리되어 main() 의 item_crud:false 개별 면제 경로에서도 재사용된다.
    suspects, load_error = load_crud_suspect_files(file_assignment_path)
    if load_error is not None:
        print(
            f"CRUD_DECLARATION_UNVERIFIABLE: file_assignment.json 로드 실패({load_error}) — "
            "판정 불가, 면제 거부(fail-closed)",
            file=sys.stderr,
        )
        return False, "unverifiable"

    # ★경로 매칭 파일은 내용 실측 후 무효화★ (폴더명 Services 오탐 수정, 2026-09-29,
    #   Present 프로젝트 — 사용자 승인)
    #   배경: CRUD_SUSPECT_PATTERN 의 `services?` 세그먼트가 DB 와 무관한 WinForms
    #     추적 엔진(Present/Services/Tracking/*.cs)에 걸려, 경로 이름만으로 면제가
    #     무효화되고 뒤의 DB 무접촉 실측 면제(scan_db_contact)까지 도달하지 못했다.
    #   해법: 패턴은 그대로 두고, 매칭된 파일을 scan_db_contact 와 같은 기준
    #     (DB_CONTACT_PATTERN, 와일드카드/디렉토리 표기·판독 실패 = 불가)으로 전수
    #     판독한다. DB 흔적 0건 + 전수 판독 성공일 때만 "경로 이름만으로는 무효화하지
    #     않음"으로 보고 아래 판정(content 축 등)을 계속한다.
    #   fail-closed 유지: DB 흔적 1건 이상, 판독 실패, 스캔 중 예외는 전부 종전과
    #     동일하게 "path" 로 무효화한다.
    if suspects:
        path_hits, path_unreadable = [], []
        # 사이클197 (e): 파일 전체의 DB 이름 토큰이 아니라 변경 범위의 쓰기 토큰(WRITE_TOKEN_PATTERN 주석 참조).
        _wt_session = os.path.dirname(file_assignment_path)
        _wt_start, _wt_cache = _read_start_time(_wt_session), {}
        try:
            # 2026-11-06 과제3: 디렉터리 표기(끝 "/" 유무·symlink 무관)는 _expand_assigned_dir 로 펼친다.
            #   전개 불가(와일드카드·하위 링크·상한·빈 디렉터리·walk 오류)는 종전대로 판독 불가.
            scan_paths = []
            for path in suspects:
                if any(ch in path for ch in "*?") or path.endswith(("/", "\\")) or os.path.isdir(path):
                    sub, why = _expand_assigned_dir(path)
                    if sub is None:
                        path_unreadable.append((path, why))
                        continue
                    scan_paths.extend(p for p in sub if p not in scan_paths)
                else:
                    scan_paths.append(path)
            for path in scan_paths:
                try:
                    with open(path, "r", encoding="utf-8", errors="strict") as fp:
                        path_content = fp.read()
                except (OSError, UnicodeDecodeError) as exc:
                    path_unreadable.append((path, str(exc)))
                    continue
                wmode, winfo = _write_token_hits(path, path_content, _wt_start, _wt_cache, _wt_session)
                if wmode == "hit":
                    path_hits.append((path, winfo))
                elif wmode == "unreadable":
                    path_unreadable.append((path, winfo))
        except Exception as exc:  # 스캔 자체 실패도 확인 불가로 본다(fail-closed)
            path_unreadable.append(("<scan>", f"{type(exc).__name__}: {exc}"))

        if path_hits or path_unreadable:
            print(
                "CRUD_DECLARATION_OVERRIDDEN: crud_대상=false 선언이 실제 변경 파일과 모순 — "
                "면제 무효화(fail-closed, 경로 기인)",
                file=sys.stderr,
            )
            for f in suspects:
                print(f"  - CRUD 의심 파일: {f}", file=sys.stderr)
            for f, m in path_hits:
                print(f"  - 쓰기 토큰(변경 범위): {f} | {m}", file=sys.stderr)
            for f, e in path_unreadable:
                print(f"  - 판독 불가: {f} | {e}", file=sys.stderr)
            return False, "path"

        print(
            f"CRUD_PATH_SUSPECT_CLEARED: 경로 패턴 매칭 {len(suspects)}개 파일 전수 판독 결과 "
            "변경 범위(시작 시점 base 대비 변경 줄+근접) 쓰기 토큰 0건 — 경로 이름만으로는 무효화하지 않음"
        )
        for f in suspects:
            print(f"  - 경로 매칭(내용 무해): {f}")

    # ★AC 내용 기반 검사★ (역라우팅 2회차 — 경로 화이트리스트의 구조적 한계 대응)
    #   crud_대상=false 를 선언해놓고 AC 본문에 저장/등록 등 CRUD 요구가 있으면
    #   그 자체가 자기모순이다. is_inspection_only 가 부정문/검증 맥락(grep, 무변경 확인 등)을
    #   함께 걸러주므로, 순수 검증형 AC 는 오탐 없이 통과한다.
    #   ★회귀 수정(odev, 팀리드 지시)★: item_crud 는 "작성자 선언"이고 여기서 계산하는
    #   content_suspects 는 그 선언을 "검증"하는 장치다. 선언이 검증을 이기면 검증이
    #   존재할 이유가 없으므로, 이 계산에서는 item_crud 를 신뢰하지 않고(trust_item_crud=False)
    #   항상 원래의 category/키워드 기반 판정으로 CRUD 본문 요구를 재확인한다.
    #   (전 항목 item_crud=False 로 선언해도 실제 본문이 CRUD 를 요구하면 여기서 잡힌다.)
    #   ★skip_demand_gate=True(odev, 팀리드 지시 — 신규 발견 과잉차단 수정)★:
    #   is_non_crud_declared() 에 도달했다는 사실 자체가 "이 파일 전체가 비-CRUD
    #   작업"이라는 top-level 명시 선언(crud_대상=false + crud_미해당_사유) 문맥임을
    #   증명한다. 그 문맥에서 demand_blob 의 CRUD 동사 하나로 verify_blob 검사도
    #   못 받고 조기 차단하는 것은 과하다("hook 등록 상태를 점검한다" 같은 검증형
    #   AC 오탐). 회피 방지는 이 완화의 책임이 아니다 — 아래 path 교차검증(수정 1,
    #   load_crud_suspect_files)이 거짓 선언을 실제 변경 파일로 여전히 잡는다.
    ac_items = []
    if isinstance(data.get("items"), list):
        ac_items = [i for i in data["items"] if isinstance(i, dict)]
    else:
        for bucket in ("must", "should", "nice", "criteria"):
            bucket_value = data.get(bucket)
            if isinstance(bucket_value, list):
                ac_items.extend(i for i in bucket_value if isinstance(i, dict))

    content_suspects = [
        item for item in ac_items
        if is_crud_item(item, trust_item_crud=False)
        and not is_inspection_only(item, trust_item_crud=False, skip_demand_gate=True)
    ]
    if content_suspects:
        print(
            "CRUD_DECLARATION_OVERRIDDEN: crud_대상=false 선언이 AC 본문의 CRUD 요구와 모순 — "
            "면제 무효화(fail-closed, AC 내용 기인)",
            file=sys.stderr,
        )
        for item in content_suspects:
            item_id = str(item.get("id") or item.get("name") or "?")
            title = _norm(
                item.get("criterion") or item.get("title") or item.get("desc") or ""
            )[:70]
            print(f"  - CRUD 의심 AC: {item_id} | {title}", file=sys.stderr)
        return False, "content"

    return True, None


def is_crud_item(item, trust_item_crud=True):
    """이 검수 항목이 CRUD 실행 증거를 요구하는 항목인가.

    ★item_crud 구조화 필드 — 1순위 판정★ (is_inspection_only 와 동일 원칙).
    필드가 bool 로 존재하면 그 값을 그대로 따르고 category/키워드 분석은
    건너뛴다. 필드 부재 시에만 기존 category/CRUD_KEYWORDS 폴백을 탄다.

    ★trust_item_crud=False — 회귀 수정★ (odev, 팀리드 지시):
      is_non_crud_declared() 의 content_suspects 계산에서는 item_crud 를
      "작성자 선언"으로 보고 신뢰하지 않는다. 선언(item_crud)이 검증(경로/
      category/키워드 재대조)을 이기면 검증 장치가 존재할 이유가 없기
      때문이다. 이 인자가 False 면 item_crud 값과 무관하게 항상
      category/CRUD_KEYWORDS 판정으로 폴백한다. 기본값 True 는 기존
      호출부(항목 레벨 판정) 동작을 그대로 유지한다.
    """
    if trust_item_crud and isinstance(item, dict):
        item_crud = item.get("item_crud")
        if isinstance(item_crud, bool):
            return item_crud

    category = str(item.get("category", "")).strip().lower()
    if category in CRUD_CATEGORIES:
        return True
    haystack = " ".join(
        _norm(item.get(key, ""))
        for key in ("criterion", "item", "name", "desc", "description", "verify")
    )
    # 2026-10-10 (R2): 부정 의미가 확정된 고정 복합어만 지운 뒤 매칭한다. 남은 문장에 다른 CRUD
    #   어휘가 있으면 그대로 CRUD 다(축소 조작 — 어휘 확장·절 분리 규칙 아님, L-466 준수).
    for phrase in NEGATED_COMPOUNDS:
        haystack = haystack.replace(phrase, " ")
    return any(keyword in haystack for keyword in CRUD_KEYWORDS)


def load_criteria(path):
    """acceptance_criteria.json 을 읽어 must/should/nice 를 단일 리스트로 편다."""
    with open(path, "r", encoding="utf-8") as fp:
        data = json.load(fp)

    items = []
    if isinstance(data, list):
        items = list(data)
    elif isinstance(data, dict):
        for bucket in ("must", "should", "nice", "criteria", "items"):
            bucket_value = data.get(bucket)
            if isinstance(bucket_value, list):
                for entry in bucket_value:
                    if isinstance(entry, dict):
                        entry = dict(entry)
                        entry.setdefault("_bucket", bucket)
                        items.append(entry)
    return items


def adapt_goal_to_criteria(goal_path):
    """goal.json(계약 문서)을 acceptance_criteria.json 과 같은 모양으로 변환한다.

    ★왜 필요한가 (사이클142 B3)★
      main() 은 acceptance_criteria.json 부재 시 tier=O3~O5 를 즉시 차단한다.
      그런데 goal.json 방식 계약(oto/oroof, 구 oralph)은 그 파일을 애초에 산출하지 않는다.
      ⇒ 면제 분기(is_non_crud_declared, crud_대상=false)에 ★도달조차 못 하고★
        구조적으로 otest_done 을 찍을 수 없었다.

    ★설계 원칙 — 면제가 아니라 번역이다★
      goal.json 에는 crud_대상 필드가 없다. 그러므로 이 어댑터는 면제를 주지 않는다.
      acceptance[] 를 criteria 항목으로 ★번역만★ 하고, CRUD 판정은 기존 로직이
      그대로 수행한다. "goal.json 이면 통과"는 vacuous truth 가 되므로 하지 않는다.

    반환: (criteria_dict, 항목수) — 항목이 0개면 (None, 0).
    """
    with open(goal_path, "r", encoding="utf-8") as fp:
        goal = json.load(fp)
    if not isinstance(goal, dict):
        return None, 0

    acceptance = goal.get("acceptance")
    if not isinstance(acceptance, list) or not acceptance:
        return None, 0

    items = []
    for entry in acceptance:
        if not isinstance(entry, dict):
            continue
        # goal.acceptance 의 desc/check 를 criteria 의 자연어 필드로 옮긴다.
        # 기존 is_crud_item() 이 읽는 키 이름(criterion/desc/verify)에 맞춘다.
        translated = {
            "id": entry.get("id", ""),
            "criterion": entry.get("desc", ""),
            "desc": entry.get("desc", ""),
            "verify": entry.get("check", ""),
            "category": entry.get("kind", ""),
            "_bucket": "must",
            "_from_goal": True,
        }
        # 사이클172 C25: goal 쪽에 구조화 선언이 있으면 그대로 옮긴다(번역 — 새 면제 아님).
        for key in ("item_crud", "verify_kind"):
            if key in entry:
                translated[key] = entry[key]
        items.append(translated)
    if not items:
        return None, 0

    # crud_대상 은 ★의도적으로 넣지 않는다★ — 넣으면 파일 레벨 면제를 공짜로 주는 셈이다.
    # 필드 부재는 is_non_crud_declared() 에서 "none"(면제 아님, 정상 흐름)으로 처리된다.
    return {"criteria": items}, len(items)


def load_evidence(path):
    """evidence/make_ok 을 읽는다. JSON 이 아니면 원문 텍스트로 취급한다."""
    with open(path, "r", encoding="utf-8") as fp:
        raw = fp.read()
    try:
        return json.loads(raw), raw
    except json.JSONDecodeError:
        return None, raw


def find_result(evidence_json, evidence_raw, item_id):
    """evidence 에서 해당 검수 ID 의 결과 레코드를 찾는다."""
    if isinstance(evidence_json, dict):
        for result in evidence_json.get("criteria_results", []) or []:
            if isinstance(result, dict) and str(result.get("id", "")) == str(item_id):
                return result
    # JSON 이 아니면 원문에서 해당 ID 줄을 찾아 텍스트 레코드로 반환한다.
    for line in evidence_raw.splitlines():
        if item_id and item_id in line:
            return {"id": item_id, "_raw_line": line}
    return None


# ─────────────────────────────────────────────────────────────────────────────
# ★goal_id 별칭 대조★ (사이클177 A12 — 결함1)
# ─────────────────────────────────────────────────────────────────────────────
#   --emit-from-goal 은 판정 행을 goal id(A1~A18)로 기록하고, CRUD 항목은 AC id(AC-0xx)로 찾는다.
#   그래서 정직한 선언으로도 "make_partial 에 기록 없음 — 거부"가 났다(c176).
#   규칙: ① 별칭은 item["goal_id"] 와 ★정확 일치★ 하는 행만 잡는다(접두·부분 일치 금지 — A1 ≠ A12).
#         ② AC id 행이 있으면 그것이 우선이다(별칭은 AC 행이 없을 때만).
#         ③ 별칭 행에서는 status 만 가져온다. write_log·상태변화 같은 증거 필드는 ★그 AC 자신의★
#            항목 evidence 파일에서만 병합한다 — goal 행 1개의 증거로 그 아래 AC 여러 개가 함께
#            통과하지 않게 한다(증거 요구는 AC 단위로 유지).
def _goal_alias(item):
    """항목의 goal_id 별칭(정확 일치 전용). 없거나 자기 id 와 같으면 빈 문자열."""
    if not isinstance(item, dict):
        return ""
    gid = str(item.get("goal_id") or "").strip()
    iid = str(item.get("id") or item.get("ID") or item.get("name") or "").strip()
    return gid if gid and gid != iid else ""


def _load_item_evidence(ev_map, item_id):
    """AC 항목 자신의 evidence 파일(JSON dict)을 읽는다. 없거나 깨졌으면 빈 dict."""
    path = (ev_map or {}).get(item_id)
    if not path:
        return {}
    try:
        with open(path, "r", encoding="utf-8") as fp:
            ev = json.load(fp)
    except (OSError, json.JSONDecodeError):
        return {}
    return ev if isinstance(ev, dict) else {}


def _alias_record(item_id, gid, goal_row, ev_map):
    """goal 행을 AC 단위 레코드로 편다. goal 행의 증거 필드는 가져오지 않는다."""
    rec = {"id": item_id, "status": str(goal_row.get("status", "")), "goal_alias": gid}
    for key, value in _load_item_evidence(ev_map, item_id).items():
        if key not in ("id", "status", "goal_alias"):
            rec.setdefault(key, value)
    return rec


def _resolve_result(evidence_json, evidence_raw, item, ev_map=None):
    """find_result + goal_id 별칭. AC id 행이 없을 때만 goal 행(정확 일치)을 AC 단위 레코드로 쓴다."""
    item_id = str(item.get("id") or item.get("ID") or item.get("name") or "").strip()
    if isinstance(evidence_json, dict):
        rows = [r for r in (evidence_json.get("criteria_results", []) or []) if isinstance(r, dict)]
        for row in rows:
            if str(row.get("id", "")) == item_id:
                return row
        gid = _goal_alias(item)
        if gid:
            for row in rows:
                if str(row.get("id", "")) == gid:
                    return _alias_record(item_id, gid, row, ev_map)
    return find_result(evidence_json, evidence_raw, item_id)


def has_write_log_evidence(result):
    """증거 ① — 테스트 시각 이후의 저장 경로 실행 로그가 기록되어 있는가."""
    if not isinstance(result, dict):
        return False
    for key in ("write_log", "log_evidence", "app_log", "execution_log", "log_excerpt"):
        if str(result.get(key, "")).strip():
            return True
    blob = _norm(result)
    # 로그 인용 안에 저장 실행을 나타내는 흔적이 있는지 본다.
    return bool(re.search(r"(저장 완료|INSERT|UPDATE|DELETE|레코드 (생성|업데이트))", blob))


def _normalize_rowset(value):
    """행 집합을 순서 무관 비교가 가능한 형태로 정규화한다.

    전건 DELETE→재INSERT 는 물리적 행 순서를 보존하지 않으므로,
    순서 차이를 내용 변화로 오인하면 안 된다 (odev-1 지적).
    중복 행도 의미가 있을 수 있어 set 이 아니라 ★정렬된 multiset★ 으로 만든다.
    """
    if isinstance(value, (list, tuple)):
        return sorted(_norm(item) for item in value)
    if isinstance(value, dict):
        return sorted(f"{k}={_norm(v)}" for k, v in value.items())
    return _norm(value)


def has_state_change_evidence(result):
    """증거 ② — DB 상태가 실제로 변했다는 실측 기록이 있는가.

    ⚠️ COUNT 단독으로 정의하면 안 된다 (odev-1 지적, 2026-08-24 실측).
       cspms.t_ProjectCategory 저장은 ★전건 DELETE → 전건 재INSERT★ 구조라
       (1002:5693 DELETE / 1002:5705 foreach INSERT),
       같은 선택으로 저장하면 최종 COUNT 가 정확히 동일하다.
       즉 ★COUNT 불변 = 미실행 이 아니다.★ COUNT 만 요구하면
       UPSERT형·전건재작성형 테이블에서 정상 저장에 FAIL 이 나는 위양성이 발생한다.

    그래서 아래 ①~③ 중 ★하나라도★ 만족하면 상태 변화로 인정한다.
      ① 행 집합/내용 변화 — PK 집합 diff 또는 특정 컬럼 값 변화 (COUNT 불변이어도 잡힌다)
      ② 갱신 시각 변화   — MOD_DT / UpdatedAt 등 UPDATE 가 실제로 돌았다는 직접 증거
      ③ COUNT 변화       — 등록/삭제형 검증에는 여전히 유효
    """
    if not isinstance(result, dict):
        return False

    # ③ COUNT 변화 (등록/삭제형)
    before = result.get("count_before")
    after = result.get("count_after")
    if isinstance(before, int) and isinstance(after, int) and before != after:
        return True
    delta = result.get("count_delta")
    if isinstance(delta, int) and delta != 0:
        return True

    # ① 행 집합/내용 변화 — 전건 재작성형 테이블의 정본 증거
    #    ⚠️ ★순서 의존 비교 금지★ (odev-1 지적, 2026-08-24):
    #       전건 DELETE→재INSERT 는 물리적 행 순서가 바뀔 수 있다.
    #       리스트를 그대로 != 비교하면 내용이 같은데 순서만 달라도 "변화 있음"으로
    #       ★오탐(거짓 통과)★ 한다. 차단력에는 영향이 없지만 증거의 정확도가 무너진다.
    #       ⇒ 집합(multiset)으로 정규화해 비교한다.
    rb = result.get("rowset_before")
    ra = result.get("rowset_after")
    if rb is not None and ra is not None:
        if _normalize_rowset(rb) != _normalize_rowset(ra):
            return True
    for key in ("row_diff", "pk_diff", "value_before", "value_after", "content_change"):
        if str(result.get(key, "")).strip():
            # value_before/after 쌍은 실제로 달라야 인정한다.
            if key == "value_before" or key == "value_after":
                vb = str(result.get("value_before", "")).strip()
                va = str(result.get("value_after", "")).strip()
                if vb and va and vb != va:
                    return True
                continue
            return True

    # ② 갱신 시각 변화 — UPDATE 가 돌았다는 직접 증거
    mb = str(result.get("modified_before", "")).strip()
    ma = str(result.get("modified_after", "")).strip()
    if mb and ma and mb != ma:
        return True

    # 텍스트 표기 폴백: "COUNT 12 -> 13" 처럼 값이 실제로 달라진 기록.
    blob = _norm(result)
    match = re.search(r"COUNT\D{0,20}?(\d+)\s*(?:->|→|=>)\s*(\d+)", blob)
    if match and match.group(1) != match.group(2):
        return True
    return False


# 하위 호환 별칭 — 종전 이름으로 호출하는 곳이 있어도 동작하게 둔다.
has_count_delta_evidence = has_state_change_evidence


def is_guard_only(item, result):
    """차단 확인만 하고 저장을 태우지 않은 전형적 형태인가."""
    blob = _norm(item) + " " + _norm(result)
    return any(hint in blob for hint in GUARD_ONLY_HINTS)


# ─────────────────────────────────────────────────────────────────────────────
# ★goal 게이트 → make_ok / make_partial 연결★ (사이클172 C25 — F-CRUD-1 ⑰-③)
# ─────────────────────────────────────────────────────────────────────────────
#   배경: goal 체계(cNNN_gate.py + goal_autoscript_run.sh) 사이클에는 make_ok 를 만드는
#     단계가 없었다. otest_done(--final)은 CRUD 항목이 있으면 make_ok 를 요구하므로
#     ★구조적으로★ 막혔고, c171 은 사용자가 PARTIAL 을 손으로 쓰고 DISABLE_DONE_GATE 를 썼다.
#   연결 규칙 (정직 원칙 — FAIL 을 PASS 로 바꾸는 경로를 만들지 않는다):
#     · 게이트 rc=0 + 판정 행이 전부 PASS(1건 이상)        → make_ok 후보 작성
#         └ 후보를 ★이 스크립트의 CRUD 검사로 다시 통과★ 해야만 make_ok 로 확정한다.
#           CRUD 항목의 write_log+상태변화 증거가 없으면 make_ok 가 아니라 make_partial 이다.
#     · 그 외(rc≠0, FAIL/UNDET/NOSCRIPT, ALLBLOCKED/DEFERRED)  → make_partial (make_ok 는 쓰지 않는다)
#     · 판정 행이 0건(게이트 자체가 돌지 않음)               → 아무것도 쓰지 않고 rc=3(판정불가)
#   make_partial 은 "통과"가 아니라 ★미통과 목록의 기록★ 이다. --final 은 이 기록이 있을 때만
#     "미통과로 명시된 CRUD 항목"을 PARTIAL 로 인정한다(아래 _acknowledge_partial).

_GATE_LINE = re.compile(r"^([^\t\r\n]+)\t([A-Z]+)\t?(.*)$")


def _parse_gate_output(text):
    """goal_autoscript_run.sh 출력(ID<TAB>STATUS<TAB>사유)을 레코드 목록으로 편다."""
    records = []
    for line in (text or "").splitlines():
        mo = _GATE_LINE.match(line.strip("\n"))
        if not mo:
            continue
        records.append({"id": mo.group(1).strip(), "status": mo.group(2).strip(),
                        "gate_detail": mo.group(3).strip()})
    return records


def _item_evidence_map(criteria_path):
    """AC 항목 id → 항목 evidence 파일(JSON dict) 경로. evidence_dir + item.evidence 규칙."""
    mapping = {}
    try:
        with open(criteria_path, "r", encoding="utf-8") as fp:
            data = json.load(fp)
    except (OSError, json.JSONDecodeError, TypeError):
        return mapping
    base = data.get("evidence_dir", "") if isinstance(data, dict) else ""
    goal_keys = []
    for item in load_criteria(criteria_path):
        ev = item.get("evidence")
        if not isinstance(ev, str) or not ev.strip():
            continue
        path = ev if os.path.isabs(ev) else os.path.join(str(base or os.path.dirname(criteria_path)), ev)
        mapping[str(item.get("id", ""))] = path
        gid = _goal_alias(item)
        if gid:
            goal_keys.append((gid, path))
    # c177 결함1: 게이트 판정 행은 goal id 라 AC id 키로는 병합이 0건이었다. goal_id 로도 등록한다.
    #   AC id 키를 덮어쓰지 않고(정확 일치 키가 우선), 같은 goal 아래 AC 가 여럿이면 첫 항목만 등록한다.
    #   이 병합은 goal 행의 참고 정보일 뿐이다 — AC 단위 판정은 _resolve_result 가 AC 자신의 파일로 한다.
    for gid, path in goal_keys:
        mapping.setdefault(gid, path)
    return mapping


def _write_json_atomic(path, payload):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.tmp{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as fp:
        json.dump(payload, fp, ensure_ascii=False, indent=2)
    os.replace(tmp, path)


# ─────────────────────────────────────────────────────────────────────────────
# ★실업무 행 스냅샷 선행 게이트★ (사이클172 C26 보강1 — L-1200 티켓 19772 원값 미확보)
# ─────────────────────────────────────────────────────────────────────────────
#   PreToolUse_snapshot_gate.sh 는 팀원의 직접 SQL 만 본다. 앱 UI → GW → DB 쓰기는 hook 이 관측할 수
#   없으므로 make_ok 확정 시점에 사후로 막는다.
#   대상: is_crud_item(item) 이 True 인 항목. 면제: item 또는 항목 증거에 "live_rows": false 를 명시한 항목
#         ([cNNNtest] 표식 신규 행만 다룸). 표식 문구만으로는 면제하지 않는다 — L-1200 은 표식 행 등록의
#         부수효과로 실업무 티켓 MOD_DT 가 바뀐 사고다.
#   조건: ① 항목 증거의 "snapshot"(경로 또는 목록) 또는 snapshot_*.json 중 "item"==ID / 파일명에 _ID_ 토큰
#            (검색 위치: session-env/<UUID>/evidence, criteria evidence_dir)
#         ② 그 파일이 JSON 이고 rows 가 list
#         ③ 파일 mtime < 첫 쓰기 시각(write_ts·first_write_ts·gw_log_ts 중 최소, ISO8601 또는 epoch)
#   하나라도 못 맞추면 SNAPSHOT_MISSING / SNAPSHOT_INVALID / WRITE_TS_MISSING / SNAPSHOT_AFTER_WRITE → make_partial.
_WRITE_TS_KEYS = ("write_ts", "first_write_ts", "gw_log_ts")


def _parse_ts(value):
    import datetime as _dt
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return float(value)
    text = str(value or "").strip()
    if not text:
        return None
    if re.fullmatch(r"\d{9,11}(?:\.\d+)?", text):
        return float(text)
    try:
        dt = _dt.datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return None
    return dt.timestamp()  # naive 는 로컬 시각으로 해석


def _snapshot_violations(item_rows, criteria_path, evidence_dir, items_override=None, require_all=False,
                         strict=False, fresh_after=None):
    """strict=True(c177 결함2 — PARTIAL 인정 경로)면 추가로 막는다.
         · SNAPSHOT_EMPTY  : 크기 0 파일 또는 rows=[] 뿐(원값을 확보하지 못한 스냅샷)
         · SNAPSHOT_STALE  : fresh_after(기준시각) 이전 mtime 뿐(이번 파이프라인 이전의 옛 스냅샷)
       strict=False 면 종전 동작과 같다(rows=[] 도 유효)."""
    import glob as _glob
    if items_override is not None:
        items = {str(i.get("id", "")): i for i in items_override}
    else:
        items = {str(i.get("id", "")): i for i in load_criteria(criteria_path)} if criteria_path else {}
    bases = [evidence_dir]
    try:
        with open(criteria_path, "r", encoding="utf-8") as fp:
            cdata = json.load(fp)
        if isinstance(cdata, dict) and cdata.get("evidence_dir"):
            bases.append(str(cdata["evidence_dir"]))
    except (OSError, json.JSONDecodeError, TypeError):
        pass
    pool = []
    for base in bases:
        pool.extend(_glob.glob(os.path.join(base, "snapshot_*.json")))
    out = []
    for rec in item_rows:
        rid = rec["id"]
        item = items.get(rid)
        if item is None or not is_crud_item(item):
            continue
        # 이미 미통과(FAIL 등)이거나 CRUD 실행 증거가 없는 항목은 기존 경로(not_passed / MAKE_OK_REFUSED_CRUD)가 처리한다
        #   require_all=True(main 의 DB 무접촉 면제 직전 — 뒤에 CRUD 증거 검사가 없다)면 건너뛰지 않는다
        if not require_all and (rec.get("status") != "PASS"
                                or not (has_write_log_evidence(rec) and has_state_change_evidence(rec))):
            continue
        if item.get("live_rows") is False or rec.get("live_rows") is False:
            continue
        snap = rec.get("snapshot")
        cands = []
        if snap:
            for s in (snap if isinstance(snap, list) else [snap]):
                s = str(s)
                cands.extend([s] if os.path.isabs(s) else [os.path.join(b, s) for b in bases])
        else:
            tok = re.compile(r"(?:^|[_.-])" + re.escape(rid) + r"(?:[_.-]|$)")
            for p in pool:
                if tok.search(os.path.basename(p)):
                    cands.append(p)
                    continue
                try:
                    with open(p, "r", encoding="utf-8") as fp:
                        if str(json.load(fp).get("item", "")) == rid:
                            cands.append(p)
                except (OSError, json.JSONDecodeError, AttributeError):
                    pass
        valid = []
        empty = 0
        for p in cands:
            try:
                if strict and os.path.isfile(p) and os.path.getsize(p) == 0:
                    empty += 1
                    continue
                with open(p, "r", encoding="utf-8") as fp:
                    d = json.load(fp)
                if isinstance(d, dict) and isinstance(d.get("rows"), list):
                    if strict and not d["rows"]:
                        empty += 1
                        continue
                    valid.append((os.path.getmtime(p), p))
            except (OSError, json.JSONDecodeError):
                continue
        if not cands:
            out.append({"id": rid, "status": "SNAPSHOT_MISSING",
                        "detail": "실업무 행 CRUD 항목인데 snapshot_*.json 없음(테스트 표식 행만이면 live_rows:false 명시)"})
            continue
        if not valid and empty:
            out.append({"id": rid, "status": "SNAPSHOT_EMPTY",
                        "detail": f"스냅샷 {empty}개가 크기 0 또는 rows=[] — 원값을 확보하지 못했다"})
            continue
        if not valid:
            out.append({"id": rid, "status": "SNAPSHOT_INVALID", "detail": "스냅샷 파일이 JSON+rows(list) 형식이 아님"})
            continue
        if strict and fresh_after is not None:
            fresh = [v for v in valid if v[0] >= fresh_after]
            if not fresh:
                out.append({"id": rid, "status": "SNAPSHOT_STALE",
                            "detail": f"스냅샷 mtime({max(valid)[0]:.0f}) < 기준시각({fresh_after:.0f}) — "
                                      f"이번 파이프라인 이전의 옛 스냅샷: {max(valid)[1]}"})
                continue
            valid = fresh
        ts = [t for t in (_parse_ts(rec.get(k)) for k in _WRITE_TS_KEYS) if t is not None]
        if not ts:
            out.append({"id": rid, "status": "WRITE_TS_MISSING",
                        "detail": "첫 쓰기 시각(write_ts/first_write_ts/gw_log_ts)이 증거에 없어 선후 판정 불가"})
            continue
        first_write = min(ts)
        mt, path = min(valid)
        if mt >= first_write:
            out.append({"id": rid, "status": "SNAPSHOT_AFTER_WRITE",
                        "detail": f"스냅샷 mtime({mt:.0f}) ≥ 첫 쓰기({first_write:.0f}) — 원값이 아님: {path}"})
    return out


def _main_snapshot_fail(crud_items, evidence_json, evidence_raw, criteria_path, evidence_path, require_all=False,
                        strict=False, fresh_after=None):
    """main()/--final 경로의 스냅샷 선행 검사. 위반이 있으면 stderr 에 사유를 찍고 True.

    항목 evidence 파일 필드(write_ts·snapshot·live_rows)도 병합한다(emit_from_goal 과 같은 규칙).
    strict=True 는 PARTIAL 인정 경로 전용이다 — crud_items 는 PASS 로 인정된 항목만 넘어오며,
    빈 스냅샷·옛 스냅샷(fresh_after 이전)도 막는다(c177 결함2).
    """
    ev_map = _item_evidence_map(criteria_path) if criteria_path and os.path.isfile(criteria_path) else {}
    snap_rows = []
    for item in crud_items:
        item_id = str(item.get("id") or item.get("ID") or item.get("name") or "").strip()
        result = _resolve_result(evidence_json, evidence_raw, item, ev_map) if evidence_raw is not None else None
        rec = dict(result) if isinstance(result, dict) else {}
        rec["id"] = item_id
        rec.setdefault("status", "PASS")
        if strict:
            rec["status"] = "PASS"  # 호출자가 PASS 로 인정한 항목만 넘긴다
        ev_path = ev_map.get(item_id)
        if ev_path:
            try:
                with open(ev_path, "r", encoding="utf-8") as fp:
                    ev = json.load(fp)
                if isinstance(ev, dict):
                    for key, value in ev.items():
                        if key not in ("id", "status"):
                            rec.setdefault(key, value)
            except (OSError, json.JSONDecodeError):
                pass
        snap_rows.append(rec)
    snap_fail = _snapshot_violations(snap_rows, criteria_path, os.path.dirname(os.path.abspath(evidence_path)),
                                     items_override=crud_items, require_all=require_all,
                                     strict=strict, fresh_after=fresh_after)
    if not snap_fail:
        return False
    print("MISSING_SNAPSHOT_EVIDENCE: 실업무 행 스냅샷 선행 증거 불충분 — PASS 마킹 거부 (L-1200)", file=sys.stderr)
    for sf in snap_fail:
        print(f"  - {sf['id']}: {sf['status']} — {sf['detail']}", file=sys.stderr)
    print("  [cNNNtest] 신규 행만 다뤘다면 항목 증거에 \"live_rows\": false 를 명시하라.", file=sys.stderr)
    return True


def _snapshot_fresh_bound(criteria_path, session_dir):
    """옛 스냅샷 판정 기준시각. criteria 의 created_at → 세션 pipeline_start_time 순. 둘 다 없으면 None."""
    try:
        with open(criteria_path, "r", encoding="utf-8") as fp:
            data = json.load(fp)
        if isinstance(data, dict):
            ts = _parse_ts(data.get("created_at"))
            if ts is not None:
                return ts
    except (OSError, json.JSONDecodeError, TypeError):
        pass
    start = _read_start_time(session_dir) if session_dir else None
    return float(start) if start is not None else None


# ─────────────────────────────────────────────────────────────────────────────
# ★--ac-records 공식 입력★ (사이클177 A12 — 결함3(c))
# ─────────────────────────────────────────────────────────────────────────────
#   c176 은 make_partial 에 AC 레코드를 손으로 append 해 통과 경로를 확보했다. 그 파일은 무검증 입력이었다.
#   이제 AC 레코드는 --emit-from-goal --ac-records <json> 으로만 넣는다. 검사:
#     · JSON list 또는 {"records":[...]}, 각 레코드는 dict + id + status(PASS/FAIL/UNDET/NOSCRIPT)
#     · id 는 criteria 에 실존하는 항목이어야 하고(정확 일치), 게이트 판정 행 id 와 겹치면 안 되며, 중복 금지
#     · 레코드의 goal_id 는 criteria 항목의 goal_id 와 같아야 한다
#     · 위반 1건이라도 있으면 rc=2 로 아무것도 쓰지 않는다(일부만 반영하지 않는다)
#   반영 규칙(정직 원칙 — FAIL 을 PASS 로 바꾸는 경로를 만들지 않는다):
#     · PASS 레코드인데 그 goal 행이 PASS 가 아니면 미통과(GOAL_NOT_PASS)
#     · PASS 레코드인데 CRUD 항목이고 write_log+상태변화 증거가 없으면 미통과(CRUD_EVIDENCE_MISSING)
_AC_RECORD_STATUS = ("PASS", "FAIL", "UNDET", "NOSCRIPT")
# ★사이클197 (c) — status 어휘 대응표(단일 출처, AC-J4)★
#   ac_gate.py 기록 어휘(PASS·FAIL·PARTIAL·BLOCKED·NA)와 goal_autoscript_run 출력 어휘(PASS·FAIL·UNDET·NOSCRIPT)가
#   달라, ac_gate 규약대로 쓴 PARTIAL·BLOCKED·NA 기록이 --ac-records 에서 파일 전체 rc=2 로 거부됐다(c197 계획 §12-4).
#   ⇒ 두 어휘를 이 표 하나로 해석한다. 통과 계열은 PASS 하나뿐이고 나머지는 전부 미통과다(통과로 접히는 경로 없음).
#     fail  : 미충족(FAIL·PARTIAL)  / undet: 판정불가(UNDET·NOSCRIPT·BLOCKED) / na: 근거 있는 N/A — 리드 결정(19:22)으로 미통과
#   결합 규칙(_load_ac_records): 기록과 게이트의 "통과 여부" 가 어긋나면 어느 방향이든 rc=2(기록으로 판정을 뒤집지 못한다).
#     유일한 예외: 기록 NA + 게이트 PASS — ac_gate 가 na_allowed+na_basis 를 확인한 NA 를 PASS(N/A) rc0 로 내기 때문에
#     게이트는 PASS 가 된다. 이 조합은 거부하지 않고 not_passed(status=NA)로 정직하게 기록한다(fail-closed).
_STATUS_CLASS = {"PASS": "pass", "FAIL": "fail", "PARTIAL": "fail", "UNDET": "undet", "NOSCRIPT": "undet",
                 "BLOCKED": "undet", "NA": "na"}
_AC_RECORD_INPUT_STATUS = tuple(_STATUS_CLASS)


def _is_pass_status(status):
    """대응표 기준 통과 계열인가 — PASS 만 True. 모르는 어휘도 False(미통과)."""
    return _STATUS_CLASS.get(str(status or "").strip()) == "pass"
# 게이트 판정 행과 같은 id 의 AC 레코드를 결합할 때 레코드에서 가져오지 않는 키(판정·출처는 게이트 것이 정본)
_AC_MERGE_SKIP_KEYS = ("id", "status", "source", "gate_detail", "goal_id", "evidence_file", "judged_by")


# ─────────────────────────────────────────────────────────────────────────────
# ★판정은 게이트, 증거는 기록 — 같은 id 는 "대체"가 아니라 "결합"★ (사이클195 역라우팅 #4)
# ─────────────────────────────────────────────────────────────────────────────
#   c195 부터 게이트(cNNN_gate.py)가 AC id 로 직접 판정한다(c177 의 goal id A1~A18 ≠ AC id 와 다르다).
#   그러면 게이트 행에는 판정(PASS/FAIL)만 있고 write_log·상태변화 증거는 시험 기록(ac_records)에만 있는데,
#   종전 규칙 "게이트 판정 행 id 와 겹치면 rc=2" 가 그 기록의 병합을 막아 CRUD 항목이 영원히
#   CRUD_EVIDENCE_MISSING 이 됐다(otest_done 기록 불가). 그래서 겹치는 id 는 다음 규칙으로 결합한다.
#     · 레코드 status 는 게이트 판정과 ★같아야★ 한다 — 다르면 rc=2(기록으로 판정을 바꾸는 경로는 없다).
#     · 결합 시 status·source·gate_detail 은 게이트 것을 유지하고, 그 외 필드(write_log·value_before/after·
#       row_diff·files·snapshot·write_ts·live_rows …)만 게이트 행에 setdefault 로 옮긴다.
#     · 게이트가 판정하지 않은 id(블록·유예·goal 에 없음)인데 criteria 에 gate_kind 가 있는 항목의 PASS 레코드는
#       거부한다 — 게이트를 거치지 않은 PASS 다(gate_kind 가 없는 c177 식 항목은 종전대로 추가 행이 된다).
#     · 파일을 여러 개 주면(--ac-records 반복) 같은 id 는 mtime 이 가장 늦은 파일의 행을 쓴다(cNNN_gate 규칙 4 와
#       같다). 한 파일 안의 중복은 종전대로 오류다.
#   카나리(gate_kind=canary + expected_result)는 emit_from_goal 이 "판정 결과 == expected_result 면 정상" 으로 읽는다.
def _load_ac_records(paths, criteria_path, gate_status):
    """반환: (records, error). error 가 있으면 records 는 쓰지 않는다.

    paths: 경로 문자열 또는 경로 목록. gate_status: {게이트 판정 id: status}(set 도 받는다 — 그때는 status 미상).
    반환 행의 "merge_into_gate" 가 True 면 게이트 행에 증거만 결합할 행이다(판정은 게이트 행의 것).
    """
    if isinstance(paths, (str, bytes, os.PathLike)):
        paths = [paths]
    if isinstance(gate_status, dict):
        gate_map = {str(k): v for k, v in gate_status.items()}
    else:
        gate_map = {str(k): None for k in (gate_status or ())}
    if not criteria_path:
        return [], "--ac-records 는 acceptance_criteria.json 이 있어야 대조할 수 있다"
    items = {str(i.get("id", "")).strip(): i for i in load_criteria(criteria_path)}
    # 파일 단위로 읽고(한 파일 안 중복은 오류), 파일 간 같은 id 는 mtime 이 늦은 쪽이 이긴다
    by_id, errors = {}, []
    for path in paths:
        try:
            with open(path, "r", encoding="utf-8") as fp:
                data = json.load(fp)
            mtime = os.path.getmtime(path)
        except (OSError, json.JSONDecodeError) as exc:
            return [], f"--ac-records 읽기 실패({exc})"
        records = data.get("records") if isinstance(data, dict) else data
        if not isinstance(records, list) or not records:
            return [], f"--ac-records 는 비어 있지 않은 list 또는 {{\"records\": [...]}} 이어야 한다: {path}"
        seen = set()
        for idx, rec in enumerate(records):
            if not isinstance(rec, dict):
                errors.append(f"[{idx}] dict 아님")
                continue
            rid = str(rec.get("id") or "").strip()
            status = str(rec.get("status") or "").strip()
            if not rid:
                errors.append(f"[{idx}] id 없음")
                continue
            if rid not in items:
                errors.append(f"{rid}: criteria 에 없는 id")
                continue
            if rid in seen:
                errors.append(f"{rid}: 중복({os.path.basename(path)})")
                continue
            if status not in _AC_RECORD_INPUT_STATUS:
                errors.append(f"{rid}: status={status or '(없음)'} — {'/'.join(_AC_RECORD_INPUT_STATUS)} 중 하나여야 한다")
                continue
            item_gid = _goal_alias(items[rid])
            rec_gid = str(rec.get("goal_id") or "").strip()
            if rec_gid and rec_gid != item_gid:
                errors.append(f"{rid}: goal_id={rec_gid} ≠ criteria goal_id={item_gid or '(없음)'}")
                continue
            seen.add(rid)
            prev = by_id.get(rid)
            if prev is not None and prev[0] >= mtime:
                continue  # 더 늦은 파일의 행이 이미 있다
            by_id[rid] = (mtime, path, dict(rec), status, item_gid)
    out = []
    for rid in sorted(by_id):
        mtime, path, rec, status, item_gid = by_id[rid]
        row = rec
        row["id"], row["status"], row["source"] = rid, status, "ac_records"
        if item_gid:
            row["goal_id"] = item_gid
        if rid in gate_map:
            gate_st = gate_map[rid]
            if gate_st is None:
                errors.append(f"{rid}: 게이트 판정 행 id 와 겹친다")
                continue
            # 사이클197 (c): 문자열 일치가 아니라 대응표의 "통과 여부" 로 비교한다. 어긋나면 어느 방향이든 rc=2.
            #   예외는 기록 NA + 게이트 PASS 하나(대응표 주석) — 결합은 하되 emit 이 not_passed(status=NA)로 옮긴다.
            na_on_pass = status == "NA" and _is_pass_status(gate_st)
            if _is_pass_status(status) != _is_pass_status(gate_st) and not na_on_pass:
                errors.append(f"{rid}: 기록 status={status} ≠ 게이트 판정 {gate_st}(통과 여부 불일치) — "
                              "판정은 게이트가 한다(기록으로 바꿀 수 없다)")
                continue
            row["merge_into_gate"] = True
            row["record_status"] = status
            row["record_file"] = path
        elif status == "PASS" and items[rid].get("gate_kind"):
            errors.append(f"{rid}: 게이트가 판정하지 않은 id(gate_kind={items[rid].get('gate_kind')}) 의 PASS 기록 — "
                          "게이트를 거치지 않은 PASS 는 받지 않는다")
            continue
        out.append(row)
    if errors:
        return [], "; ".join(errors[:10]) + (f" 외 {len(errors) - 10}건" if len(errors) > 10 else "")
    return out, None


def _canary_expectations(criteria_path):
    """criteria 의 gate_kind=canary 항목 → {id: expected_result(대문자)}. expected_result 가 없으면 포함하지 않는다."""
    out = {}
    if not criteria_path:
        return out
    for item in load_criteria(criteria_path):
        if not isinstance(item, dict) or str(item.get("gate_kind", "")).strip().lower() != "canary":
            continue
        exp = str(item.get("expected_result") or "").strip().upper()
        if exp in _AC_RECORD_STATUS:
            out[str(item.get("id", "")).strip()] = exp
    return out


def _crud_scope_for_emit(args, config_dir, criteria_path):
    """기록 단계용 CRUD 집합 — main()(--final)과 같은 입력(기준표·배정표)으로 _derive_crud_items 를 돈다.

    사이클197 (a) — judge_rca §16-C 결함 3. 반환 dict:
      outcome : _derive_crud_items 의 outcome(exempt/content_cleared/no_crud/conflict/crud) 또는 no_criteria/criteria_error
      ids     : 증거를 요구하는 CRUD 항목 id 집합(outcome=crud 이고 DB 무접촉 면제가 아닐 때만 채운다 — main 과 같다)
      items   : ids 에 해당하는 기준표 항목
      detail  : 판정 출력 끝 2000자(make_* 기록의 crud_scope.detail 로 남긴다)
    판정 출력은 모아 두고 화면에는 요약 1줄만 낸다(--final 과 같은 줄이 기록 단계에 섞여 소비자가 오독하지 않게).
    """
    import contextlib
    import io
    out = {"outcome": "no_criteria", "ids": set(), "items": [], "detail": ""}
    if not criteria_path:
        return out
    try:
        items = load_criteria(criteria_path)
        with open(criteria_path, "r", encoding="utf-8") as fp:
            raw = json.load(fp)
    except (OSError, json.JSONDecodeError) as exc:
        out.update(outcome="criteria_error", detail=str(exc))
        return out
    if args.uuid:
        fa_path = os.path.join(config_dir, "session-env", args.uuid, "file_assignment.json")
    else:
        fa_path = os.path.join(os.path.dirname(criteria_path), "file_assignment.json")
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
        res = _derive_crud_items(items, raw, fa_path,
                                 exclude_test_fixtures=bool(getattr(args, "exclude_test_fixtures", False)))
    out["outcome"], out["detail"] = res["outcome"], buf.getvalue()[-2000:]
    if res["outcome"] == "crud" and not res.get("db_clean"):
        out["items"] = list(res["crud_items"])
        out["ids"] = {str(i.get("id", "")).strip() for i in res["crud_items"]}
    return out


def emit_from_goal(args, config_dir, criteria_path, session_dir):
    """goal 게이트를 실행해 make_ok 또는 make_partial 을 기록한다.

    반환 rc: 0=make_ok 확정 / 1=make_partial 기록(미통과 존재) / 2=--ac-records 검사 위반(아무것도 안 씀)
             / 3=판정불가(아무것도 안 씀)
    """
    import subprocess
    import time as _time

    goal_path = args.goal or os.path.join(session_dir, "goal.json")
    # 사이클182 항목3(L-609): --before-stage 미지정 + --gate-cmd 미지정이면 세션 state 로 기본값을 정한다.
    #   PLAN·OK·DEV·TEST(odone 이전) → odone 적용. DONE·FINISH·IDLE·판독 불가 → 미적용(전수 판정).
    #   명시 플래그가 항상 우선한다. 판정 규칙(goal_autoscript_run.sh) 자체는 바꾸지 않는다.
    before_stage = args.before_stage
    if not before_stage and not args.gate_cmd:
        stage_word = ""
        try:
            with open(os.path.join(session_dir, "state"), "r", encoding="utf-8") as fp:
                stage_word = (fp.read().split() or [""])[0].upper()
        except OSError:
            stage_word = ""
        if stage_word in ("PLAN", "OK", "DEV", "TEST"):
            before_stage = "odone"
            print(f"BEFORE_STAGE_DEFAULT: state={stage_word} → --before-stage odone")
    deferred = []
    if before_stage and not args.gate_cmd:
        # 판정에서 빠지는 항목(valid_after == before_stage)을 기록한다 — 통과가 아니라 유예다.
        try:
            with open(goal_path, "r", encoding="utf-8") as fp:
                goal_doc = json.load(fp)
            deferred = [str(a.get("id", "")) for a in (goal_doc.get("acceptance") or [])
                        if isinstance(a, dict) and (a.get("valid_after") or "") == before_stage]
        except (OSError, json.JSONDecodeError, AttributeError):
            deferred = []
    defer_fields = {"deferred": deferred, "before_stage": before_stage} \
        if before_stage and not args.gate_cmd else {}
    if args.gate_cmd:
        cmd = args.gate_cmd
    else:
        runner = os.path.join(config_dir, "hooks", "lib", "goal_autoscript_run.sh")
        cmd = (f"bash '{runner}' --goal '{goal_path}' --timeout {int(args.gate_timeout)}"
               + (f" --before-stage '{before_stage}'" if before_stage else ""))
    proc = subprocess.run(cmd, shell=True, capture_output=True, text=True,
                          stdin=subprocess.DEVNULL)
    gate_rc = proc.returncode
    records = _parse_gate_output(proc.stdout)
    print(f"GOAL_GATE_RUN: rc={gate_rc} 판정행={len(records)}건 — {cmd}")

    item_rows = [r for r in records if r["status"] in ("PASS", "FAIL", "UNDET", "NOSCRIPT")]
    special = [r for r in records if r not in item_rows]
    if not item_rows:
        print("GOAL_GATE_UNDETERMINED: 항목 판정 행 0건 — make_ok/make_partial 을 쓰지 않는다(판정불가)",
              file=sys.stderr)
        if proc.stderr.strip():
            print("  " + proc.stderr.strip().splitlines()[0], file=sys.stderr)
        for r in special:
            print(f"  - {r['id']}\t{r['status']}\t{r['gate_detail']}", file=sys.stderr)
        return 3

    evidence_map = _item_evidence_map(criteria_path) if criteria_path else {}
    for rec in item_rows:
        ev_path = evidence_map.get(rec["id"])
        if not ev_path:
            continue
        rec["evidence_file"] = ev_path
        try:
            with open(ev_path, "r", encoding="utf-8") as fp:
                ev = json.load(fp)
        except (OSError, json.JSONDecodeError):
            continue
        if isinstance(ev, dict):
            for key, value in ev.items():
                if key not in ("id", "status", "gate_detail", "source", "evidence_file"):
                    rec.setdefault(key, value)
    for rec in item_rows:
        rec["source"] = "goal_gate"
    gate_status = {r["id"]: r["status"] for r in item_rows}

    # ★카나리 계약★ (사이클195 역라우팅 #4): gate_kind=canary 항목은 "판정 결과 == expected_result" 가 정상이다.
    #   카나리의 목적은 판정기를 거치지 않고 전부 PASS 로 적는 것을 잡는 것이므로 게이트는 계속 FAIL 을 내고,
    #   소비자인 이 함수가 그 FAIL 을 "정상(canary_ok)" 으로 읽는다. 반대로 카나리가 PASS 로 나오면(=게이트 우회)
    #   CANARY_VIOLATION 으로 미통과에 넣는다. 판정 행의 status 는 관측값 그대로 둔다(손으로 PASS 로 바꾸지 않는다).
    canary_exp = _canary_expectations(criteria_path)
    canary_ok_ids, canary_block = [], []
    for rec in item_rows:
        exp = canary_exp.get(rec["id"])
        if exp is None:
            continue
        rec["gate_kind"], rec["expected_result"] = "canary", exp
        if rec["status"] == exp:
            rec["canary_ok"] = True
            canary_ok_ids.append(rec["id"])
        else:
            rec["canary_ok"] = False
            canary_block.append({"id": rec["id"], "status": "CANARY_VIOLATION",
                                 "detail": f"카나리 판정 {rec['status']} ≠ expected_result {exp} — 판정기 우회 의심"})
    for cid in sorted(set(canary_exp) - set(gate_status)):
        print(f"CANARY_ABSENT: {cid} — criteria 는 카나리인데 게이트 판정 행에 없다(블록·유예·goal 미등재 여부 확인)",
              file=sys.stderr)
    if canary_ok_ids:
        print(f"CANARY_OK: {', '.join(canary_ok_ids)} — 판정 결과가 expected_result 와 일치(정상, 미통과 아님)")

    # c177 결함3(c): AC 레코드 공식 입력 — 수기 append 를 대체한다(검사 위반 시 아무것도 쓰지 않는다)
    # c195: 게이트 판정 행과 같은 id 는 증거만 결합한다(판정은 게이트, 증거는 기록 — 위 _load_ac_records 주석).
    ac_rows = []
    ac_paths = getattr(args, "ac_records", None) or []
    if isinstance(ac_paths, str):
        ac_paths = [ac_paths]
    if ac_paths:
        loaded, ac_err = _load_ac_records(ac_paths, criteria_path, gate_status)
        if ac_err:
            print(f"AC_RECORDS_REJECTED: {ac_err} — make_ok/make_partial 을 쓰지 않는다", file=sys.stderr)
            return 2
        gate_by_id = {r["id"]: r for r in item_rows}
        merged_ids = []
        for row in loaded:
            if row.get("merge_into_gate"):
                target = gate_by_id[row["id"]]
                for key, value in row.items():
                    if key not in _AC_MERGE_SKIP_KEYS and key not in ("merge_into_gate", "record_file"):
                        target.setdefault(key, value)
                target["evidence_source"] = "ac_records"
                target["record_file"] = row.get("record_file", "")
                merged_ids.append(row["id"])
            else:
                ac_rows.append(row)
        print(f"AC_RECORDS_LOADED: {len(loaded)}건(결합 {len(merged_ids)} / 추가 {len(ac_rows)}) — {', '.join(ac_paths)}")
        if merged_ids:
            print(f"AC_RECORDS_MERGED: {', '.join(merged_ids)} — 게이트 판정 행에 기록의 증거 필드를 결합(판정 무변경)")
    # ★사이클197 (a) — 기록 단계 ↔ 최종 마킹 대칭 (judge_rca §16-C 결함 1·2·3)★
    #   종전: ① 결합 행(merge_into_gate)은 아래 증거 검사를 거치지 않았고 ② 게이트 rc≠0 이면 CRUD 재검사(all_pass
    #   분기)가 돌지 않았으며 ③ CRUD 집합이 is_crud_item 기준이라 --final 의 crud_items(경로 무효화·자연어 불신 재확인)
    #   보다 좁았다. 그래서 c196 은 기록 단계 PASS 36 / 증거 거부 0 이었는데 --final 은 14건을 거부했다 — 기록 단계의
    #   '증거 부재 0' 은 측정값 0 이 아니라 측정을 안 한 것이었다.
    #   ⇒ CRUD 집합은 main() 과 같은 함수(_derive_crud_items)로 만들고, PASS 행 전체(게이트 행·결합 행·추가 행)를
    #     all_pass·게이트 rc 와 무관하게 검사한다. 미충족은 not_passed(CRUD_EVIDENCE_MISSING)로 옮긴다(판정 status 무변경).
    crud_scope = _crud_scope_for_emit(args, config_dir, criteria_path)
    crud_ids_all = crud_scope["ids"]
    print(f"CRUD_SCOPE: outcome={crud_scope['outcome']} 증거 요구 CRUD {len(crud_ids_all)}건"
          + (f"({', '.join(sorted(crud_ids_all))})" if crud_ids_all else "")
          + " — --final 과 같은 산출(_derive_crud_items)")
    ac_block = []
    for row in ac_rows:
        gid = row.get("goal_id", "")
        if row["status"] == "PASS" and gid and gid in gate_status and gate_status[gid] != "PASS":
            ac_block.append({"id": row["id"], "status": "GOAL_NOT_PASS",
                             "detail": f"goal {gid} 판정 {gate_status[gid]} — AC PASS 를 인정하지 않는다"})
    item_rows.extend(ac_rows)
    # 사이클197 (c): 게이트 PASS 행에 결합된 기록이 NA(대응표 na 계열)면 미통과로 옮긴다 — 판정 status 는 게이트 것 유지.
    for row in item_rows:
        _rs = row.get("record_status")
        if _rs and row["status"] == "PASS" and not _is_pass_status(_rs):
            ac_block.append({"id": row["id"], "status": _rs,
                             "detail": f"기록 {_rs} — 게이트 PASS(N/A) 이나 대응표상 미통과(사이클197 (c))"})
    _goal_blocked = {b["id"] for b in ac_block}
    _canary_ok_now = set(canary_ok_ids)
    for row in item_rows:
        if row["status"] != "PASS" or row["id"] in _goal_blocked or row["id"] in _canary_ok_now:
            continue
        if row["id"] in crud_ids_all and not (has_write_log_evidence(row) and has_state_change_evidence(row)):
            ac_block.append({"id": row["id"], "status": "CRUD_EVIDENCE_MISSING",
                             "detail": "PASS 기록이나 write_log+상태변화 증거 없음(--final 과 같은 CRUD 집합)"})
    # 행이 없는 CRUD 항목: goal 별칭(정확 일치)으로 판정됐으면 그 AC 자신의 증거를 보고, 별칭도 없으면 기록 누락이다
    #   (--final 의 _acknowledge_partial 이 '기록 없음 — 거부' 로 내는 항목을 기록 시점에 미통과로 드러낸다).
    _row_ids = {r["id"] for r in item_rows}
    _alias_view = {"criteria_results": item_rows}
    for _item in crud_scope["items"]:
        _iid = str(_item.get("id", "")).strip()
        if not _iid or _iid in _row_ids:
            continue
        _gid = _goal_alias(_item)
        _rec = _resolve_result(_alias_view, "", _item, evidence_map) if _gid else None
        if isinstance(_rec, dict) and _rec.get("goal_alias"):
            if _rec.get("status") == "PASS" and not (
                    has_write_log_evidence(_rec) and has_state_change_evidence(_rec)):
                ac_block.append({"id": _iid, "status": "CRUD_EVIDENCE_MISSING",
                                 "detail": f"goal {_gid} PASS 이나 이 AC 의 write_log+상태변화 증거 없음"})
            continue  # 별칭 goal 행이 PASS 가 아니면 그 goal 행이 미통과로 기록된다
        ac_block.append({"id": _iid, "status": "CRUD_RECORD_MISSING",
                         "detail": "--final 이 CRUD 로 보는 항목인데 판정 행·기록이 없다"})
    if crud_scope["outcome"] == "conflict":
        ac_block.append({"id": "*", "status": "CRUD_DECLARATION_CONFLICT",
                         "detail": "crud_대상=false 선언이 실제 변경 파일·AC 본문과 모순 — --final 은 증거와 무관하게 거부한다. "
                                   + crud_scope["detail"][-200:]})
    blocked_ids = {b["id"] for b in ac_block}
    canary_ok_set = set(canary_ok_ids)

    stamp = _time.strftime("%Y-%m-%dT%H:%M:%S%z")
    evidence_dir = os.path.join(session_dir, "evidence")
    make_ok = os.path.join(evidence_dir, "make_ok")
    make_partial = os.path.join(evidence_dir, "make_partial")
    passed = [r["id"] for r in item_rows
              if r["status"] == "PASS" and r["id"] not in blocked_ids and r["id"] not in canary_ok_set]
    not_passed = [{"id": r["id"], "status": r["status"], "detail": r.get("gate_detail", "")}
                  for r in item_rows if r["status"] != "PASS" and r["id"] not in canary_ok_set] \
        + canary_block + ac_block
    # 카나리가 정상(expected_result 와 일치)인 FAIL 만으로 게이트 rc 가 1 이면 실효 rc 는 0 이다.
    #   UNDET·NOSCRIPT 행이 하나라도 있으면(rc=3) 그대로 판정불가다 — 카나리는 FAIL 만 흡수한다.
    effective_gate_rc = gate_rc
    if gate_rc == 1 and canary_ok_set:
        fail_rows = [r["id"] for r in item_rows if r["status"] == "FAIL"]
        undet_rows = [r["id"] for r in item_rows if _STATUS_CLASS.get(r["status"]) == "undet"]
        if fail_rows and not undet_rows and all(fid in canary_ok_set for fid in fail_rows):
            effective_gate_rc = 0
            print(f"GOAL_GATE_EFFECTIVE_RC: 1 → 0 — FAIL 행이 전부 정상 카나리({', '.join(fail_rows)})")
    defer_fields = dict(defer_fields, canary_ok=sorted(canary_ok_set), effective_gate_rc=effective_gate_rc,
                        crud_scope={"outcome": crud_scope["outcome"], "ids": sorted(crud_ids_all),
                                    "detail": crud_scope["detail"]})
    # 실업무 행 스냅샷 선행 게이트(사이클172 C26 보강1, L-1200) — 미충족 CRUD 항목은 미통과로 옮긴다
    snap_fail = _snapshot_violations([r for r in item_rows if r["id"] not in blocked_ids], criteria_path, evidence_dir)
    for sf in snap_fail:
        if sf["id"] in passed:
            passed.remove(sf["id"])
        not_passed.append(sf)
        print(f"SNAPSHOT_GATE: {sf['id']} {sf['status']} — {sf['detail']}", file=sys.stderr)
    all_pass = effective_gate_rc == 0 and not not_passed and not special
    # 사이클197 (a): 게이트는 전부 PASS 인데 CRUD 증거 검사만으로 미통과가 생긴 경우 종전 출력 토큰을 그대로 낸다
    #   (otest_make SKILL.md:131 소비 문구 — 출력 형식 회귀 방지, L-1358).
    _crud_only_block = [b for b in ac_block
                        if b["status"] in ("CRUD_EVIDENCE_MISSING", "CRUD_RECORD_MISSING", "CRUD_DECLARATION_CONFLICT")]
    if (effective_gate_rc == 0 and not special and _crud_only_block
            and len(_crud_only_block) == len(not_passed)):
        print("MAKE_OK_REFUSED_CRUD: 게이트는 전부 PASS 지만 CRUD 실행 증거가 부족하다 — make_partial 로 기록",
              file=sys.stderr)

    crud_block = ""
    if all_pass:
        candidate = os.path.join(evidence_dir, f".make_ok.candidate{os.getpid()}")
        _write_json_atomic(candidate, {"result": "PASS", "source": "goal_gate", "gate_rc": gate_rc,
                                       "generated_at": stamp, **defer_fields,
                                       "criteria_results": item_rows})
        check = [sys.executable, os.path.abspath(__file__), "--evidence", candidate]
        # 재검사도 본 검사와 같은 입력을 본다 — criteria 가 없으면 원래 지정 경로(부재 포함)를 그대로 넘겨
        # main() 의 부재 규칙(tier 차단 / goal.json 폴백)을 동일하게 타게 한다(인자 누락 INPUT_ERROR 방지).
        check_criteria = criteria_path or args.criteria
        check += ["--criteria", check_criteria] if check_criteria else []
        check += ["--uuid", args.uuid] if args.uuid else []
        # [D-9 사이클199] 재검사도 본 실행의 DB 접촉 축 옵션을 그대로 따른다 — 빠지면 본 실행은 픽스처 적중을 빼고
        #   (content_cleared) 재검사는 빼지 않아(db_found) "*" CRUD_EVIDENCE_MISSING 으로 거부됐다(경로 실측 옵션, 선언 아님).
        #   emit 전용 인자(--goal·--gate-cmd·--gate-timeout·--before-stage·--ac-records)는 재검사(증거 모드)가 쓰지 않으므로 넘기지 않는다.
        check += ["--exclude-test-fixtures"] if getattr(args, "exclude_test_fixtures", False) else []
        chk = subprocess.run(check, capture_output=True, text=True,
                             env=dict(os.environ, CLAUDE_CONFIG_DIR=config_dir))
        if chk.returncode == 0:
            os.replace(candidate, make_ok)
            if os.path.isfile(make_partial):
                os.replace(make_partial, f"{make_partial}.superseded_{int(_time.time())}")
            print(f"MAKE_OK_FROM_GOAL: 전 항목 {len(passed)}건 게이트 PASS + CRUD 증거 검사 통과 → {make_ok}")
            return 0
        try:
            os.remove(candidate)
        except OSError:
            pass
        crud_block = (chk.stdout + chk.stderr).strip()[:2000]
        print("MAKE_OK_REFUSED_CRUD: 게이트는 전부 PASS 지만 CRUD 실행 증거가 부족하다 — make_partial 로 기록",
              file=sys.stderr)
        # CRUD 증거가 없는 CRUD 항목을 미통과로 옮긴다(게이트 PASS 를 저장 검증 통과로 위장하지 않는다).
        crud_ids = set(crud_ids_all)  # 사이클197 (a): --final 과 같은 산출(_derive_crud_items)
        for rec in item_rows:
            if rec["id"] in crud_ids and not (has_write_log_evidence(rec) and has_state_change_evidence(rec)):
                not_passed.append({"id": rec["id"], "status": "CRUD_EVIDENCE_MISSING",
                                   "detail": "게이트 PASS 이나 write_log+상태변화 증거 없음"})
        # c177 결함1: 자기 행 없이 goal 행(정확 일치 별칭)으로만 판정된 CRUD AC 도 AC 단위로 미통과를 적는다
        row_ids = {r["id"] for r in item_rows}
        alias_view = {"criteria_results": item_rows}
        for item in (load_criteria(criteria_path) if criteria_path else []):
            iid = str(item.get("id", ""))
            if iid not in crud_ids or iid in row_ids or not _goal_alias(item):
                continue
            rec = _resolve_result(alias_view, "", item, evidence_map)
            if isinstance(rec, dict) and rec.get("goal_alias") and not (
                    has_write_log_evidence(rec) and has_state_change_evidence(rec)):
                not_passed.append({"id": iid, "status": "CRUD_EVIDENCE_MISSING",
                                   "detail": f"goal {rec['goal_alias']} PASS 이나 이 AC 의 write_log+상태변화 증거 없음"})
        if not not_passed:
            not_passed.append({"id": "*", "status": "CRUD_EVIDENCE_MISSING", "detail": crud_block[:300]})

    if os.path.isfile(make_ok):
        # 이전 make_ok 이 남아 있으면 이번 결과(미통과)와 모순된다 — 지우지 않고 보존 개명한다.
        os.replace(make_ok, f"{make_ok}.superseded_{int(_time.time())}")
    _write_json_atomic(make_partial, {
        "result": "PARTIAL",
        "source": "goal_gate",
        "gate_rc": gate_rc,
        "generated_at": stamp,
        "passed": passed,
        "not_passed": not_passed,
        "special": special,
        "crud_check_output": crud_block,
        **defer_fields,
        "criteria_results": item_rows,
    })
    print(f"MAKE_PARTIAL_FROM_GOAL: PASS {len(passed)}건 / 미통과 {len(not_passed)}건 → {make_partial}")
    for np_ in not_passed:
        print(f"  - {np_['id']}: {np_['status']} {np_['detail'][:120]}")
    print("  ⚠️ make_partial 은 통과가 아니다. otest_done 은 'PARTIAL' 로 시작하고 미통과 id 를 나열해 기록하라.")
    return 1


def _acknowledge_partial(evidence_path, crud_items, ev_map=None):
    """--final + make_ok 부재 시, make_partial 이 미통과를 ★명시★ 한 경우에만 PARTIAL 로 인정한다.

    반환: (ok: bool, lines: list[str], passed_items: list[item]). ok=False 면 종전대로 차단한다.
      · make_partial 부재/파싱실패/result≠PARTIAL/not_passed 비어 있음 → 인정 안 함
      · CRUD 항목이 make_partial 어디에도 없음(passed·not_passed 모두 부재) → 인정 안 함(기록 누락)
      · passed 로 기록된 CRUD 항목은 write_log+상태변화 증거가 있어야 한다 → 없으면 인정 안 함
      · c177 결함1: AC id 로 기록이 없으면 goal_id 별칭(정확 일치)으로 찾는다. 별칭으로 PASS 를 찾았어도
        증거는 AC 단위(AC 레코드 또는 그 AC 자신의 evidence 파일)여야 한다 — goal 행 증거로 대신하지 않는다.
      · passed_items: PASS 로 인정된 CRUD 항목 — 호출자가 스냅샷 선행 검사(결함2)에 넘긴다.
    """
    partial_path = os.path.join(os.path.dirname(evidence_path), "make_partial")
    try:
        with open(partial_path, "r", encoding="utf-8") as fp:
            partial = json.load(fp)
    except (OSError, json.JSONDecodeError):
        return False, [], []
    if not isinstance(partial, dict) or partial.get("result") != "PARTIAL":
        return False, ["make_partial result≠PARTIAL — 인정하지 않는다"], []
    not_passed = partial.get("not_passed")
    if not isinstance(not_passed, list) or not not_passed:
        return False, ["make_partial not_passed 가 비어 있다 — 전부 통과면 make_ok 이어야 한다"], []
    # 사이클197 (a): 기록 단계가 '판정 행·기록이 없다' 로 적은 CRUD_RECORD_MISSING 은 기록이 아니다 — 종전대로
    #   '기록 없음 — 거부' 로 남긴다(goal_id 오기 등 배선 결함을 PARTIAL 로 접지 않는다. 최종 마킹 판정 완화 없음).
    np_ids = {str(e.get("id")) for e in not_passed
              if isinstance(e, dict) and e.get("status") != "CRUD_RECORD_MISSING"}
    passed_ids = {str(p) for p in partial.get("passed", []) if p is not None}
    results = {str(r.get("id")): r for r in partial.get("criteria_results", []) or []
               if isinstance(r, dict)}
    lines, ok, passed_items = [], True, []
    for item in crud_items:
        iid = str(item.get("id") or "").strip()
        gid = _goal_alias(item)
        if iid in np_ids or "*" in np_ids:
            lines.append(f"  - {iid}: 미통과로 기록됨(PARTIAL) — 저장 검증 미완료")
        elif iid in passed_ids:
            rec = results.get(iid)
            if has_write_log_evidence(rec) and has_state_change_evidence(rec):
                lines.append(f"  - {iid}: PASS + CRUD 증거 확인")
                passed_items.append(item)
            else:
                ok = False
                lines.append(f"  - {iid}: PASS 로 기록됐으나 write_log+상태변화 증거 없음 — 거부")
        elif gid and gid in np_ids:
            lines.append(f"  - {iid}: goal {gid} 미통과로 기록됨(PARTIAL, 별칭 정확 일치) — 저장 검증 미완료")
        elif gid and gid in passed_ids:
            rec = results.get(iid)
            if rec is None and gid in results:
                rec = _alias_record(iid, gid, results[gid], ev_map)
            if has_write_log_evidence(rec) and has_state_change_evidence(rec):
                lines.append(f"  - {iid}: goal {gid} PASS(별칭) + 이 AC 의 CRUD 증거 확인")
                passed_items.append(item)
            else:
                ok = False
                lines.append(f"  - {iid}: goal {gid} PASS(별칭) 이나 이 AC 의 write_log+상태변화 증거 없음 — 거부")
        else:
            ok = False
            lines.append(f"  - {iid}: make_partial 에 기록 없음 — 거부"
                         + (f"(goal_id={gid} 행도 없음, 별칭은 정확 일치만)" if gid else ""))
    return ok, lines, passed_items


def criteria_source_conflict(criteria_path):
    """세션 루트·plans/ 기준표 두 사본이 모두 있고 내용이 다르면 사유 문자열, 아니면 None (L-1342)."""
    p = os.path.abspath(criteria_path)
    if os.path.basename(p) != "acceptance_criteria.json":
        return None
    d = os.path.dirname(p)
    if os.path.basename(d) == "plans":
        root, plans = os.path.join(os.path.dirname(d), "acceptance_criteria.json"), p
    else:
        root, plans = p, os.path.join(d, "plans", "acceptance_criteria.json")
    if not (os.path.isfile(root) and os.path.isfile(plans)):
        return None
    try:
        with open(root, "rb") as f1, open(plans, "rb") as f2:
            a, b = f1.read(), f2.read()
    except OSError as exc:
        return f"기준표 사본을 읽지 못했다 — {exc}"
    if a == b:
        return None
    return (f"기준표 두 사본이 다르다 — 세션 루트 {root} ({len(a)}바이트) ≠ plans/ {plans} ({len(b)}바이트)")


def _derive_crud_items(items, criteria_raw_data, file_assignment_path, exclude_test_fixtures=False):
    """F-CRUD-1 의 CRUD 집합 산출 — main()(--final 포함)과 emit_from_goal(기록 단계)이 같이 쓰는 단일 함수.

    사이클197 (a) — judge_rca §16-C 결함 3: 기록 단계는 is_crud_item 만으로 CRUD 집합을 만들어 --final 의
    crud_items(경로 무효화·자연어 불신 재확인·검증형 면제 포함)보다 좁았다. 그래서 기록 단계는 PASS 로 적고
    최종 마킹은 거부했다. 이 함수 본문은 종전 main() 의 해당 구간을 그대로 옮긴 것이다(판정·출력 무변경).
    반환 dict 의 outcome:
      exempt / content_cleared / no_crud — CRUD 증거 요구 없음(main rc 0)
      conflict                            — crud_대상=false 선언이 경로·본문과 모순(main rc 1, 증거로 구제 불가)
      crud                                — crud_items·db_clean·db_detail 로 이어서 판정
    """
    exempt, invalid_reason = is_non_crud_declared(criteria_raw_data, file_assignment_path)
    if exempt:
        reason = str(criteria_raw_data.get("crud_미해당_사유", "")).strip()
        print(f"NON_CRUD_EXEMPT: 비-CRUD 작업 선언으로 면제 — 사유: {reason}")
        return {"outcome": "exempt"}

    # ★content 무효화 → 사실 축(변경 파일 DB 실측) 이관★ (2026-10-08 역라우팅 #1, 사용자 결정)
    #   원인: content 무효화는 CRUD_KEYWORDS 부분문자열 기반 자연어 추정이라 부정어
    #     ("전역 status-interval 무변경" 의 "변경")까지 CRUD 로 읽는다. 그런데도 아래의
    #     하드 차단이 사실 축 scan_db_contact() 에 도달하기 전에 rc=1 로 끝냈다.
    #   역전 실측: 같은 AC 에서 crud_대상/crud_미해당_사유 만 지우면 none 경로 실측 면제로
    #     rc=0 이 된다 — 비-CRUD 를 정직하게 선언한 쪽만 더 강하게 막혔다.
    #   L-467(선언은 검증을 이길 수 없다) 유지: 면제 근거는 선언이 아니라 변경 파일 전수
    #     판독 결과(clean) 하나뿐이다. 항목 재판정(is_crud_item)으로 흘리지 않는다
    #     (과거 "raw_crud 가 비어 RC=0" 누수 회귀 방지).
    #   이중 신호 차단: 경로 패턴 의심 파일이 하나라도 있으면(내용 무해로 path 단계를
    #     통과했더라도) AC 본문 의심과 겹친 것으로 보고 면제하지 않는다.
    #   그 외(db_found/unreadable/no_assignment/no_files/path_and_content)는 기존 하드 차단으로 진행.
    if invalid_reason == "content":
        content_path_suspects, content_path_err = load_crud_suspect_files(file_assignment_path)
        content_db_clean, content_db_detail = scan_db_contact(
            file_assignment_path, exclude_test_fixtures=exclude_test_fixtures)
        if content_db_detail.get("reason") == "db_found" and content_db_detail.get("fixture_only"):
            print(f"DB_HITS_TEST_FIXTURE_ONLY: {len(content_db_detail['hits'])}")
        if content_path_suspects is None:
            content_db_clean = False
            content_db_detail = {"reason": "no_assignment", "error": content_path_err}
        elif content_db_clean and content_path_suspects:
            content_db_clean = False
            content_db_detail = {"reason": "path_and_content", "suspects": content_path_suspects}
        if content_db_clean:
            print(
                "CONTENT_OVERRIDE_FACT_CLEARED: AC 본문 기인 무효화 — "
                "변경 파일 실측 DB 접촉 0건 + 경로 의심 0건으로 면제"
            )
            print(f"  검사 대상: {content_db_detail['total']}개 파일 (전수 판독 성공)")
            for f in content_db_detail["files"]:
                print(f"    - {f}")
            return {"outcome": "content_cleared"}
        print(
            f"CONTENT_OVERRIDE_FACT_BLOCKED: 실측 사유={content_db_detail.get('reason')} — "
            "종전대로 하드 차단",
            file=sys.stderr,
        )
        # 사이클214 R1-나: 차단 줄만으로는 어느 파일이 왜 막혔는지 몰라 원인 추적이 불가했다 → 경로별 상세 줄.
        _r = content_db_detail.get("reason")
        if _r == "unreadable":
            _rows = content_db_detail.get("unreadable", [])
        elif _r == "db_found":
            _rows = content_db_detail.get("hits", [])
        elif _r == "path_and_content":
            _rows = [(p, "경로 패턴 CRUD 의심") for p in content_db_detail.get("suspects", [])]
        else:
            _rows = [("file_assignment", content_db_detail.get("error") or _r)]
        for _p, _why in _rows[:10]:
            print(f"CONTENT_OVERRIDE_FACT_DETAIL: {_p}: {_why}", file=sys.stderr)
        if len(_rows) > 10:
            print(f"CONTENT_OVERRIDE_FACT_DETAIL: (외 {len(_rows) - 10}건 생략)", file=sys.stderr)

    # ★경로 기반 무효화는 즉시 하드 차단★ (회귀 수정, odev, 팀리드 지시)
    #   invalid_reason="path" 는 AC 항목 텍스트와 무관하게 "실제 변경 파일이
    #   CRUD 의심 경로"라는 구조적 모순이다. 이 경우를 아래의 항목별
    #   is_crud_item/evidence 검사로 넘기면, 항목 텍스트에 CRUD 요구 문구가
    #   없을 때(예: "훅 정상 동작 확인") raw_crud 가 비어 다시 새어나간다
    #   (이번 회귀의 실제 재현 형태). 선언이 검증(경로 재대조)을 이기게
    #   두지 않기 위해, 유효한 AC 항목 존재 여부와 무관하게 여기서 즉시
    #   MISSING_CRUD_EVIDENCE 로 차단한다 — evidence 로 구제될 수 없는 결함.
    if invalid_reason in ("path", "content"):
        # ★path/content 비대칭 회귀 수정★ (odev, 팀리드 지시):
        #   둘 다 "선언이 실제와 모순된다"는 확정 사실이며, 근거가 파일 경로냐 AC
        #   본문이냐만 다르다. content 만 항목별 재판정(is_crud_item)으로 흘려보내면
        #   raw_crud 가 비어 RC=0 으로 새어나갈 수 있다(이번 회귀의 실제 재현 형태).
        #   path 와 동일 강도로 즉시 하드 차단한다.
        reason_label = "실제 변경 파일" if invalid_reason == "path" else "AC 본문 요구 내용"
        print(
            f"MISSING_CRUD_EVIDENCE: crud_대상=false 선언이 {reason_label}과 모순 — "
            "PASS 마킹 거부",
            file=sys.stderr,
        )
        if invalid_reason == "path":
            print(
                "  파일 경로가 CRUD 의심 대상인데 비-CRUD 로 선언했다 — "
                "선언(item_crud 포함)이 경로 재대조를 이길 수 없다.",
                file=sys.stderr,
            )
        else:
            print(
                "  AC 본문이 CRUD 를 요구하는데 비-CRUD 로 선언했다 — "
                "선언(item_crud 포함)이 AC 본문 재대조를 이길 수 없다.",
                file=sys.stderr,
            )
        return {"outcome": "conflict", "invalid_reason": invalid_reason}

    # ★unverifiable 분기 누락 수정★ (odev, 팀리드 지시 — (a)등급 결함):
    #   file_assignment.json 로드 실패는 "경로가 CRUD 가 아님을 확인했다"가 아니라
    #   "확인할 수 없었다"이다. 확인할 수 없으면 crud_대상=false 선언을 신뢰해서는
    #   안 된다 — 로그가 이미 "판정 불가, 면제 거부(fail-closed)"라고 말하고 있으므로
    #   동작을 그 말과 일치시킨다.
    #   단 "path"처럼 즉시 하드 차단하면(가안) 순수 검증형 AC(예: .sh/.md 인프라
    #   작업)까지 file_assignment.json 부재만으로 막혀 과잉 차단이 된다. 그래서
    #   면제만 거부하고 trust_item_crud=False 를 강제해 이후 항목별 판정이
    #   item_crud 선언을 신뢰하지 않고 category/키워드 기반 AC 본문 재확인으로
    #   폴백하게 한다(나안) — 검증형 AC 는 그대로 통과하고, CRUD 문구가 있는
    #   AC 만 raw_crud 로 잡혀 증거 요구로 이어진다.
    #
    #   ★A8 — "none"(crud_대상 필드 부재)은 "unverifiable"과 다르다★:
    #   "unverifiable"은 file_assignment.json 을 읽을 수 없어 아무것도 확인할
    #   수 없는 상태이고, "none"은 파일 레벨 선언을 하지 않았을 뿐 항목 레벨
    #   item_crud 선언은 여전히(item_crud:false 개별 재대조와 함께) 유효한
    #   상태다. 아래 비교는 "unverifiable"만 배제하므로 "none"에서는
    #   trust_item_crud=True 로 유지되어 item_crud 구조화 필드가 실질적으로
    #   작동한다 — 이것이 A8 결함 해소의 핵심이다.
    trust_item_crud = invalid_reason != "unverifiable"

    # ★item_crud:false 개별 면제도 실제 변경 파일과 교차검증★ (odev, 팀리드 지시
    #   — 세 번째 승인, 2026-08-29, F-CRUD-1 배선 확장):
    #   top-level crud_대상 선언이 없으면(=is_non_crud_declared 가 위에서
    #   "none" 또는 "unverifiable" 로 리턴, A8 이전에는 전부 "unverifiable")
    #   is_non_crud_declared() 내부의 path 대조가 한 번도 안 돈다. 그 틈에서
    #   item_crud:false 거짓 기재 + CRUD 파일 변경 조합이 무사통과했다
    #   (실측 재현: UserController.cs / api/handler.js / schema.sql).
    #   ⇒ item_crud:false 로 면제되려는 항목에도 동일한 CRUD_SUSPECT_PATTERN
    #   재대조를 적용한다. file_assignment.json 은 항목마다 다시 읽지 않고
    #   루프 진입 전 한 번만 로드해 재사용한다. 로드 실패(unverifiable)는
    #   기존 정책 그대로 두고(동작 변경 금지) 이 교차검증 없이 자연어/필드
    #   판정만으로 진행한다 — file_assignment.json 부재만으로 순수 검증형
    #   AC(.sh/.md 등)까지 막으면 과잉 차단이기 때문이다.
    item_crud_suspect_files, _item_crud_load_error = load_crud_suspect_files(
        file_assignment_path
    )

    # ★A8 — raw_crud 진입 자체가 item_crud:false 로 막히는 결함 수정★
    #   (odev, 팀리드 지시, 2026-08-30):
    #   trust_item_crud=True(=crud_대상 부재/"none")인 상태에서 item_crud=False
    #   이면 is_crud_item() 이 category/키워드 재확인도 없이 즉시 False 를
    #   반환한다 — 그 결과 이 항목은 raw_crud 에 아예 들어오지 못해, 아래
    #   item_crud_suspect_files 교차검증 루프(raw_crud 를 순회)가 이 항목을
    #   ★한 번도 보지 못한다★. "선언(item_crud)이 검증(경로 재대조)을 이긴다"는
    #   바로 그 회귀가 raw_crud 진입 단계에서 재발한 것이다.
    #   ⇒ item_crud:false 로 선언됐더라도 실제 변경 파일이 CRUD 의심 경로이면
    #   raw_crud 에 강제 포함시켜, 아래 교차검증 루프가 반드시 이 항목을
    #   재평가하게 한다. 파일이 의심스럽지 않으면(item_crud_suspect_files 없음)
    #   기존과 동일하게 is_crud_item() 판정만 따른다(동작 변경 없음).
    #
    # ★역라우팅 2회차 — file_assignment.json 로드 실패 시 fail-safe 대칭 적용★
    #   (odev, 팀리드 지시, 2026-08-30):
    #   위 force-include 조건은 item_crud_suspect_files 가 ★채워져 있을 때★만
    #   발동한다. 그런데 load_crud_suspect_files() 가 file_assignment.json 을
    #   아예 읽지 못하면(부재/파싱 실패) suspects=None 을 반환하므로 이 조건이
    #   falsy 가 되어 세이프넷이 통째로 미발동한다 — "확인할 수 없음"이
    #   "의심 없음"으로 오인되는 것이다. is_non_crud_declared() 는 이미 같은
    #   상황(load_error is not None)에서 "unverifiable" 을 반환해 선언을
    #   신뢰하지 않는데, 이 force-include 지점만 그 원칙에서 벗어나 있었다.
    #   ⇒ 로드 실패(_item_crud_load_error is not None) 도 "경로를 확인할 수
    #   없다" 는 동일한 불확실 신호이므로 OR 로 추가해, item_crud:false 선언을
    #   신뢰하지 않고 category/키워드 재확인(is_crud_item trust_item_crud=False)
    #   으로 폴백시킨다. 로드가 ★성공★ 했고 의심 파일이 없는 경우(예: 무해
    #   파일만 있는 정상 비-CRUD 작업)는 이 분기와 무관하며 기존 동작
    #   그대로 유지된다 — 과잉 차단 방지는 아래 is_inspection_only 예외
    #   루프(검증형 AC 면제)가 계속 담당한다.
    force_recheck_item_crud_false = (
        bool(item_crud_suspect_files) or _item_crud_load_error is not None
    )

    # ★B2 — item_crud:false 개별 선언의 content 축 재확인★ (사이클51, otest-3 지적,
    #   goal.json B2):
    #   위 force_recheck_item_crud_false 는 ★경로 신호만★ 본다. crud_대상(top-level)이
    #   부재하고 file_assignment.json 이 무해 파일만 들고 있으면(item_crud_suspect_files
    #   가 빈 리스트) 이 조건은 False 로 고정되고, item_crud:false 로 선언된 항목은
    #   raw_crud 진입 자체가 막혀 아래 exempted 루프까지 도달하지 못한다. 그런데 AC
    #   본문이 명백히 CRUD 를 요구("사용자 정보를 저장하고 등록한다")해도 그 내용은
    #   한 번도 재확인되지 않는다 — is_non_crud_declared() 의 content_suspects 가
    #   top-level 선언 문맥에서만 도는 것과 정확히 같은 공백이 item 개별 선언
    #   경로에는 아예 존재하지 않았던 것이다.
    #
    #   ★국소 수정 vs 설계 통합 판단★: content 재확인 자체는 이미 존재하는 장치
    #   (is_crud_item(trust_item_crud=False) — category/키워드 폴백)다. 새 어휘나
    #   새 판정 함수를 만들지 않고, 기존 force_recheck 게이트를 "파일 단위 스칼라"에서
    #   "항목 단위 함수"로 바꿔 path 신호와 content 신호를 대칭으로 OR 한다. 이것으로
    #   path/content 두 축이 모두 raw_crud 강제포함 조건에 동등하게 반영되므로,
    #   is_non_crud_declared() 를 통째로 재작성하는 설계 통합 없이도 공백이 닫힌다 —
    #   조건식에 새 절을 얹는 것이 아니라 기존 스칼라를 항목 단위로 일반화하는 것이므로
    #   "or/and 2곳 대칭" 복잡도가 늘지 않는다(이미 있던 두 자리를 그대로 재사용).
    #
    #   ★과잉차단 방지★: content 신호는 is_crud_item(trust_item_crud=False) 를 그대로
    #   재사용하므로, exempted 루프의 is_inspection_only(effective_trust=False) 가
    #   여전히 부정문/검증형 맥락(무해 파일만 + 검증형 AC, model/ 단독 등)을 걸러내
    #   기존 과잉차단 방지 축을 깨지 않는다. content 축 강제포함은 "재확인 대상에
    #   넣는다"일 뿐 "즉시 CRUD 로 확정한다"가 아니다 — 최종 판정은 여전히
    #   is_inspection_only 가 담당한다(exempted 루프 재사용, 신규 로직 없음).
    def _force_recheck(item):
        if not isinstance(item, dict):
            return False
        if not (isinstance(item.get("item_crud"), bool) and item.get("item_crud") is False):
            return False
        if force_recheck_item_crud_false:
            return True
        # content 축: item_crud:false 선언을 불신하고 category/키워드로 재확인했을 때
        # 실제로는 CRUD 요구가 있는가. path 신호가 없어도 이것만으로 재확인 대상이다.
        return is_crud_item(item, trust_item_crud=False)

    raw_crud = [
        item for item in items
        if isinstance(item, dict) and (
            is_crud_item(item, trust_item_crud=trust_item_crud)
            or (_force_recheck(item) and is_crud_item(item, trust_item_crud=False))
        )
    ]

    # ★검증형 AC 면제 — 반드시 로그로 남긴다★ (사이클32 G-1)
    #   조용히 빼면 다음 사이클에 ★진짜 저장 누락★ 을 이 통로로 놓친다.
    #   무엇을 왜 뺐는지 매 실행마다 출력해 사람이 검토할 수 있게 한다.
    crud_items, exempted = [], []
    # 사이클172 C25: AC 에 명시적 CRUD 항목(item_crud:true)이 있는가 — 경로 의심 파일의 증거 책임 소재.
    crud_declared_ids = [
        str(i.get("id", "?")) for i in items
        if isinstance(i, dict) and i.get("item_crud") is True
    ]
    crud_declared_present = bool(crud_declared_ids)
    for item in raw_crud:
        item_crud_declared_false = (
            isinstance(item, dict)
            and isinstance(item.get("item_crud"), bool)
            and item.get("item_crud") is False
        )

        # ★역라우팅 2회차 — 예외판정도 재확인 경로에 맞춰 신뢰를 꺾는다★
        #   (odev, 팀리드 지시, 2026-08-30):
        #   raw_crud 강제포함(위)이 is_crud_item(trust_item_crud=False) 로
        #   item_crud:false 선언을 이미 불신하고 넣은 항목인데, 여기서
        #   is_inspection_only(trust_item_crud=True) 를 그대로 부르면 그
        #   함수 내부의 item_crud 조기 반환(라인 204~207)이 같은 선언을
        #   다시 신뢰해 "검증형"으로 예외 처리해버린다 — raw_crud 강제포함이
        #   무의미해지는 재발. force_recheck_item_crud_false 이고 false 로
        #   선언된 항목은 trust_item_crud=False 로 호출해 자연어
        #   (WRITE_DEMAND_HINTS/INSPECTION_HINTS) 재확인으로 폴백시킨다.
        #   ★B2 — content 축도 동일하게★ (사이클51): _force_recheck() 가 path 뿐 아니라
        #   content(is_crud_item(trust_item_crud=False)) 로도 True 가 될 수 있으므로
        #   여기서도 스칼라 force_recheck_item_crud_false 대신 _force_recheck(item) 을
        #   써야 raw_crud 강제포함과 exempted 판정의 불신 여부가 어긋나지 않는다.
        distrust_this_item = _force_recheck(item) and item_crud_declared_false
        effective_trust = False if distrust_this_item else trust_item_crud

        # ★B2 — skip_demand_gate 동일 적용★ (사이클51):
        #   is_non_crud_declared() 의 content_suspects 계산은 skip_demand_gate=True 로
        #   호출한다 — "이미 비-CRUD 문맥에 도달했다"는 사실 자체가 신호이므로
        #   WRITE_DEMAND_HINTS 조기 차단을 건너뛰고 verify_blob(방법론)만 본다
        #   (그 근거는 위 is_inspection_only 문서화 참조). 여기 exempted 루프도
        #   distrust_this_item 일 때는 동일한 문맥이다 — item_crud:false 선언 +
        #   path/content 재확인 사유 발생. 이 조합에 도달했다는 것 자체가 이미
        #   "작성자가 검증형이라고 선언했다"는 뜻이므로, 같은 트러스트 완화를
        #   대칭 적용하지 않으면 "hook 등록 상태를 점검한다"처럼 CRUD 동사
        #   하나만으로 정상 검증형 AC 가 즉시 차단되는 회귀가 생긴다(과잉차단
        #   금지 항목 위반). 회피 방지는 이 완화의 책임이 아니다 — path 재확인
        #   (item_crud_suspect_files)과 verify_blob(INSPECTION_HINTS) 판정이
        #   여전히 거짓 선언을 잡아낸다.
        if not is_inspection_only(
            item, trust_item_crud=effective_trust, skip_demand_gate=distrust_this_item
        ):
            crud_items.append(item)
            continue

        # ★사이클172 C25 — verify_kind:"inspection" 선언도 경로 재대조 대상이다★
        #   item_crud 필드 없이 verify_kind 만 쓴 항목이 경로 재대조를 건너뛰지 않게 선언 집합에 넣는다.
        #   단 AC 에 item_crud:true 항목이 ★따로 존재★ 하면, CRUD 의심 파일의 저장 증거 요구는
        #   그 CRUD 항목들이 진다(evidence 의 write_log+상태변화 필수 — 아래 검사 그대로).
        #   그때 검증 방법을 inspection 으로 ★명시★ 한 항목까지 같은 파일을 이유로 CRUD 로
        #   끌어오면, 다중 batch 사이클에서 조회 검증 항목 전부가 저장 증거를 요구받는 오탐이 된다(c171).
        #   CRUD 항목이 하나도 없으면(=의심 파일을 맡은 선언이 없음) 종전대로 무효화한다.
        declared_inspection = _declares_inspection(item)
        declared_non_crud = item_crud_declared_false or declared_inspection
        if declared_non_crud and item_crud_suspect_files and declared_inspection and crud_declared_present:
            print(
                f"INSPECTION_KIND_PATH_COVERED: {item.get('id', '?')} — verify_kind=inspection 명시, "
                f"CRUD 의심 파일 {len(item_crud_suspect_files)}개는 item_crud:true 항목 "
                f"{len(crud_declared_ids)}건({', '.join(crud_declared_ids)})의 저장 증거로 검사한다"
            )
            exempted.append(item)
            continue
        # ★사이클196 oi-fix-1 P2 — item_crud:false 선언에도 C25 와 같은 증거 책임 이전을 적용한다(대칭)★
        #   c196 실측: verify_kind 0/40·item_crud true 14/false 26 기준표에서 AC-003·016·025·030·031·036 이
        #   세션 전체 CRUD 의심 파일(.sql·Services/*.cs)과 대조돼 DECLARATION_CONFLICT 로 무효화됐다. 이 항목들은
        #   불신 모드 자연어 재확인(is_inspection_only, trust=False)까지 통과해 여기 왔으므로 남은 사유는 경로뿐이다.
        #   C25 와 같은 근거로, 같은 AC 에 item_crud:true 항목이 따로 있으면 의심 파일의 저장 증거는 그 항목들이 진다
        #   (아래 write_log·상태변화 검사 그대로). item_crud:true 가 0건이면 종전대로 무효화한다(거짓 면제 차단 유지).
        #   적용 시점: 진행 중 사이클의 판정 기준을 바꾸지 않도록 이 기능 도입 시각 이후 시작한 파이프라인부터만 켠다.
        if (declared_non_crud and item_crud_suspect_files and item_crud_declared_false and crud_declared_present):
            _fc_on, _fc_why = _item_crud_false_cover_enabled(os.path.dirname(file_assignment_path))
            if _fc_on:
                print(
                    f"ITEM_CRUD_FALSE_PATH_COVERED: {item.get('id', '?')} — item_crud:false(자연어 재확인 통과), "
                    f"CRUD 의심 파일 {len(item_crud_suspect_files)}개는 item_crud:true 항목 "
                    f"{len(crud_declared_ids)}건({', '.join(crud_declared_ids)})의 저장 증거로 검사한다 [{_fc_why}]"
                )
                exempted.append(item)
                continue
            print(f"ITEM_CRUD_FALSE_COVER_OFF: {item.get('id', '?')} — {_fc_why} → 종전 판정", file=sys.stderr)
        if declared_non_crud and item_crud_suspect_files:
            # 선언(item_crud:false)이 실제 변경 파일과 모순 — 면제 무효화.
            print(
                "CRUD_DECLARATION_OVERRIDDEN: item_crud:false 선언이 실제 변경 파일과 "
                "모순 — 면제 무효화(fail-closed, 경로 기인)",
                file=sys.stderr,
            )
            item_id = str(item.get("id", "?"))
            for f in item_crud_suspect_files:
                print(f"  - {item_id}: CRUD 의심 파일 - {f}", file=sys.stderr)
            crud_items.append(item)
        else:
            exempted.append(item)

    if exempted:
        print("INSPECTION_ONLY_EXEMPT: 저장 경로가 없는 검증형 AC — CRUD 검사에서 제외한다")
        for item in exempted:
            item_id = str(item.get("id", "?"))
            title = _norm(item.get("title") or item.get("criterion") or "")[:70]
            print(f"  - {item_id}: 저장 요구 없음 → CRUD 검사 제외 | {title}")
        print("  ⚠️ 위 항목은 '저장을 안 태워서' 통과한 것이 아니라 '저장을 요구하지 않아서' 제외된 것이다.")
        print("     검수문에 저장/등록/INSERT/UPDATE/COUNT 변화 요구가 생기면 즉시 CRUD 로 되돌아온다.")

    if not crud_items:
        print("NO_CRUD_ITEMS: CRUD 실행 증거를 요구하는 검수 항목 없음 (통과)")
        return {"outcome": "no_crud", "exempted": exempted}

    # ★DB 무접촉 실측 면제★ (사이클145 — 사용자 승인, odev-5 구현)
    #   여기까지 왔다는 것은 위의 모든 판정이 "CRUD 항목이 있다"고 본 것이다.
    #   그 판정은 ★AC 본문의 자연어★ 로 이뤄진다(content 축). 그런데 자연어는
    #   "DB 저장 아님" 처럼 ★부정하는 문장★ 의 단어도 CRUD 로 읽는다.
    #   ⇒ 마지막으로 ★사실★ 을 한 번 묻는다: 이번에 바뀐 파일에 DB 코드가 있는가.
    #     없으면 태울 저장 자체가 존재하지 않으므로 evidence 를 요구할 근거가 없다.
    #
    #   ★이 분기는 기존 로직을 하나도 바꾸지 않는다★ — crud_items 계산, item_crud,
    #   crud_대상, B2(path/content) 경로는 전부 위에서 이미 끝났고 그대로다.
    #   여기서 하는 일은 "그 결론을 실측으로 뒤집을 수 있는가" 한 번 더 보는 것뿐이다.
    #   DB 코드가 1건이라도 있거나 확인이 안 되면 ★아래로 그냥 흘러가★ 종전대로 차단된다.
    db_clean, db_detail = scan_db_contact(
        file_assignment_path, exclude_test_fixtures=exclude_test_fixtures)
    return {"outcome": "crud", "crud_items": crud_items, "exempted": exempted,
            "db_clean": db_clean, "db_detail": db_detail, "invalid_reason": invalid_reason}


def main():
    parser = argparse.ArgumentParser(
        description="CRUD 검수 항목의 실행 증거를 검증해 PASS 마킹을 거부하는 게이트"
    )
    parser.add_argument("--uuid", help="PIPELINE_UUID — criteria/evidence 경로 자동 산출")
    parser.add_argument("--criteria", help="acceptance_criteria.json 경로")
    parser.add_argument("--evidence", help="evidence/make_ok 경로")
    parser.add_argument(
        "--final",
        action="store_true",
        help=(
            "최종 마킹(otest_done) 검사. evidence 부재를 통과시키지 않고 차단한다. "
            "make_ok 쓰기 시점의 부트스트랩 통과가 최종 판정까지 새어나가지 않게 하는 봉인."
        ),
    )
    parser.add_argument(
        "--emit-from-goal",
        action="store_true",
        help=(
            "goal 게이트(goal_autoscript_run.sh)를 실행해 evidence/make_ok(전 항목 PASS + CRUD 증거) "
            "또는 evidence/make_partial(미통과 목록)을 기록한다. rc 0=make_ok / 1=make_partial / 3=판정불가."
        ),
    )
    parser.add_argument("--goal", help="--emit-from-goal: goal.json 경로(기본 세션 goal.json)")
    parser.add_argument("--gate-cmd", help="--emit-from-goal: 게이트 명령 전체를 직접 지정(테스트·대체 실행부)")
    parser.add_argument("--gate-timeout", type=int, default=180,
                        help="--emit-from-goal: 항목당 auto_script timeout 초(기본 180)")
    parser.add_argument("--before-stage", help="--emit-from-goal: goal_autoscript_run.sh --before-stage 전달")
    parser.add_argument(
        "--ac-records",
        action="append",
        help=(
            "--emit-from-goal: AC 단위 레코드 JSON(list 또는 {\"records\": [...]}) — criteria_results 에 공식 병합한다. "
            "make_partial 수기 append 를 대체한다(c177). id 는 criteria 실존이어야 하며 위반 시 rc=2. "
            "게이트 판정 행과 같은 id 는 status 가 게이트 판정과 같을 때만 증거 필드를 결합한다(c195 — 판정은 게이트, 증거는 기록). "
            "반복 지정 가능(같은 id 는 mtime 이 늦은 파일이 이긴다)."
        ),
    )
    parser.add_argument(
        "--exclude-test-fixtures",
        action="store_true",
        help=(
            "DB 접촉 축(scan_db_contact)에서만 시험 픽스처 파일(tests/·fixtures/·test_*.py 등)의 매치를 "
            "DB_SCAN_TEST_FIXTURE_EXCLUDED 로 출력하고 판정에서 뺀다. 판독 실패·경로 축·증거·스냅샷 검사는 그대로다."
        ),
    )
    args = parser.parse_args()

    config_dir = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(
        os.path.expanduser("~"), ".claude"
    )

    criteria_path = args.criteria
    evidence_path = args.evidence
    if args.uuid:
        session_dir = os.path.join(config_dir, "session-env", args.uuid)
        if criteria_path is None:
            # 정본은 세션 루트(oplan 산출 위치)다. plans/ 하위는 구버전/우회 복사본 폴백이다.
            for candidate in (
                os.path.join(session_dir, "acceptance_criteria.json"),
                os.path.join(session_dir, "plans", "acceptance_criteria.json"),
            ):
                if os.path.isfile(candidate):
                    criteria_path = candidate
                    break
            else:
                criteria_path = os.path.join(session_dir, "acceptance_criteria.json")
        evidence_path = evidence_path or os.path.join(session_dir, "evidence", "make_ok")

    if not criteria_path or not evidence_path:
        print("INPUT_ERROR: --uuid 또는 --criteria/--evidence 를 지정하라.", file=sys.stderr)
        return 2

    # ★기준표 출처 검사★ (사이클195 AC-020, L-1342)
    #   c194 에서 판정기가 세션 루트의 c193 구판 기준표를 먼저 읽어 오분류했다. 세션 루트와 plans/ 에
    #   기준표가 둘 다 있으면 바이트 동일해야 판정한다. 다르면 어느 쪽이 정본인지 이 도구가 정할 수 없으므로
    #   경고하고 판정을 거부한다(fail-closed, rc=2 — 게이트가 돌지 않은 것이며 통과가 아니다).
    #   한쪽만 있으면 종전 동작 그대로다.
    conflict = criteria_source_conflict(criteria_path)
    if conflict:
        print(f"CRITERIA_SOURCE_CONFLICT: {conflict}", file=sys.stderr)
        print("  세션 루트와 plans/ 의 acceptance_criteria.json 을 같은 내용으로 맞춘 뒤 다시 실행하라 — 판정 거부.",
              file=sys.stderr)
        return 2

    if args.emit_from_goal:
        # 사이클172 C25: goal 게이트 → make_ok/make_partial 연결 모드. 세션 디렉터리 = evidence 의 부모의 부모.
        session_dir = os.path.dirname(os.path.dirname(os.path.abspath(evidence_path)))
        crit = criteria_path if criteria_path and os.path.isfile(criteria_path) else None
        return emit_from_goal(args, config_dir, crit, session_dir)

    # ★goal.json 폴백★ (사이클142 B3 — F-CRUD-1 이 goal.json 계약을 인식하게 한다)
    #   ⚠️ ★기존 경로를 건드리지 않는다★ — acceptance_criteria.json 이 ★있으면★
    #     이 블록은 통째로 건너뛰므로 종전 동작과 100% 동일하다.
    #   goal.json 방식 계약(oto/oroof, 구 oralph)은 acceptance_criteria.json 을 산출하지 않아
    #   아래 tier 차단에 걸려 면제 분기까지 도달하지 못했다. 그 공백만 메운다.
    #   ★면제를 주는 것이 아니라 번역이다★ — CRUD 판정은 기존 로직이 그대로 한다.
    goal_criteria_data = None
    if args.uuid and not os.path.isfile(criteria_path):
        goal_path = os.path.join(config_dir, "session-env", args.uuid, "goal.json")
        if os.path.isfile(goal_path):
            try:
                goal_criteria_data, goal_count = adapt_goal_to_criteria(goal_path)
            except (OSError, json.JSONDecodeError) as exc:
                # 폴백 실패는 조용히 넘기지 않는다 — 아래 tier 차단으로 정상 진행시키되
                # 왜 폴백이 안 됐는지는 반드시 남긴다(부재와 파싱실패는 다른 사건이다).
                print(
                    f"GOAL_FALLBACK_PARSE_FAILED: goal.json 파싱 실패 — {exc}",
                    file=sys.stderr,
                )
                goal_criteria_data = None
            else:
                if goal_criteria_data:
                    print(
                        f"GOAL_FALLBACK: acceptance_criteria.json 부재 — "
                        f"goal.json 의 acceptance {goal_count}건을 검수 기준으로 사용한다 "
                        f"({goal_path})"
                    )
                else:
                    print(
                        "GOAL_FALLBACK_EMPTY: goal.json 은 있으나 acceptance 항목이 없다 — 폴백 불가",
                        file=sys.stderr,
                    )

    if not os.path.isfile(criteria_path) and goal_criteria_data is None:
        # ★"기준이 없으면 통과"는 "검증하지 않았으면 합격"과 같다 (vacuous truth).★
        # 사이클31 이 정확히 이 구멍으로 뚫렸다 — 게이트를 만들었는데 입력이 없어 무력화됐다.
        # 그래서 tier 로 갈라 판정한다. 근거는 oplan_normal/SKILL.md Step_8:
        #   "acceptance_criteria.json 생성 (o3~o5 필수)" — o1/o2 는 애초에 산출 대상이 아니다.
        #   ⇒ o3~o5 에서 파일이 없는 것은 oplan 이 필수 산출물을 빠뜨린 것이므로 차단해야 하고,
        #     o1/o2 에서 없는 것은 정상이므로 통과시켜야 한다 (기존 파이프라인을 세우지 않는 선).
        tier = ""
        if args.uuid:
            tier_path = os.path.join(config_dir, "session-env", args.uuid, "classification")
            try:
                with open(tier_path, "r", encoding="utf-8") as fp:
                    tier = fp.read().strip().upper()
            except OSError:
                tier = ""

        if tier in ("O3", "O4", "O5"):
            print(
                "MISSING_ACCEPTANCE_CRITERIA: "
                f"tier={tier} 는 acceptance_criteria.json 이 필수인데 부재 — PASS 마킹 거부",
                file=sys.stderr,
            )
            print(f"  경로: {criteria_path}", file=sys.stderr)
            print(
                "  기준이 없으면 통과가 아니라 미검증이다. oplan Step_8 산출물을 먼저 생성하라.",
                file=sys.stderr,
            )
            return 1

        # o1/o2 또는 tier 미상 — criteria 산출 대상이 아니므로 통과시킨다.
        print(
            f"NO_CRITERIA: {criteria_path} 부재 (tier={tier or 'unknown'}) — "
            "criteria 산출 대상 tier 아님 (통과)"
        )
        return 0

    if goal_criteria_data is not None:
        # goal.json 폴백 경로 — 이미 메모리에 criteria 모양으로 들고 있다.
        # load_criteria() 와 같은 규칙으로 편다(dict 의 criteria 버킷).
        items = []
        for entry in goal_criteria_data.get("criteria", []):
            if isinstance(entry, dict):
                entry = dict(entry)
                entry.setdefault("_bucket", "criteria")
                items.append(entry)
    else:
        try:
            items = load_criteria(criteria_path)
        except (OSError, json.JSONDecodeError) as exc:
            print(f"INPUT_ERROR: acceptance_criteria.json 파싱 실패 — {exc}", file=sys.stderr)
            return 2

    # ★비-CRUD 작업 선언 면제★ (L-465 재발방지 — F-CRUD-1 v2)
    #   crud_대상=false 선언 + file_assignment.json 재대조로 무효화 안 되면 전체 면제한다.
    if goal_criteria_data is not None:
        # goal.json 폴백 — crud_대상 필드가 없으므로 is_non_crud_declared() 는
        # "none"(면제 아님)을 돌려준다. ★공짜 면제를 주지 않는다는 뜻이다.★
        criteria_raw_data = goal_criteria_data
    else:
        try:
            with open(criteria_path, "r", encoding="utf-8") as fp:
                criteria_raw_data = json.load(fp)
        except (OSError, json.JSONDecodeError):
            criteria_raw_data = None

    if args.uuid:
        file_assignment_path = os.path.join(
            config_dir, "session-env", args.uuid, "file_assignment.json"
        )
    else:
        file_assignment_path = os.path.join(
            os.path.dirname(criteria_path), "file_assignment.json"
        )

    _cr = _derive_crud_items(items, criteria_raw_data, file_assignment_path,
                             exclude_test_fixtures=args.exclude_test_fixtures)
    if _cr["outcome"] in ("exempt", "content_cleared", "no_crud"):
        return 0
    if _cr["outcome"] == "conflict":
        return 1
    crud_items = _cr["crud_items"]
    db_clean, db_detail = _cr["db_clean"], _cr["db_detail"]
    if db_clean:
        # ★사이클172 C26 rev4 — 무접촉 면제 전에 item_crud:true 항목은 스냅샷 선행 검사를 먼저 거친다★
        #   변경 파일에 DB 코드가 없어도 앱 UI→GW 경유 쓰기는 실업무 행을 바꾼다(L-1200 의 실제 경로).
        #   면제는 item_crud:false(애초에 crud_items 아님) 또는 live_rows:false 명시 항목에만 남긴다.
        #   make_ok 부재 + 비 --final(최초 쓰기 부트스트랩)은 종전대로 통과 — --final 에서는 검사한다.
        declared = [i for i in crud_items if i.get("item_crud") is True]
        if declared and (os.path.isfile(evidence_path) or args.final):
            ej, er = (load_evidence(evidence_path) if os.path.isfile(evidence_path) else (None, ""))
            if _main_snapshot_fail(declared, ej, er, criteria_path, evidence_path, require_all=True):
                print("  (DB 무접촉 면제는 item_crud:true 항목의 스냅샷 선행 검사를 대신하지 않는다 — C26 rev4)",
                      file=sys.stderr)
                return 1
        print(
            "NON_CRUD_EXEMPT_DB_UNTOUCHED: 변경 파일 전수 실측 결과 DB 접속/DML 0건 — "
            "CRUD 게이트 면제"
        )
        print(f"  검사 대상: {db_detail['total']}개 파일 (전수 판독 성공)")
        if db_detail.get("deleted"):
            print(f"  삭제 확정: {len(db_detail['deleted'])}개 파일 (부재+git 실측 — DELETED_CONFIRMED 참조)")
        print(
            "  검사 패턴: mysql/pymysql/psycopg/sqlite3/MySqlConnector/SqlConnection/"
            "mariadb/cspms/dqpms, INSERT INTO·UPDATE SET·DELETE FROM·"
            "CREATE|ALTER|DROP|TRUNCATE TABLE·SELECT FROM"
        )
        for f in db_detail["files"]:
            print(f"    - {f}")
        print(
            f"  면제된 CRUD 판정 항목 {len(crud_items)}건: "
            + ", ".join(str(i.get("id", "?")) for i in crud_items)
        )
        print(
            "  ⚠️ 이 면제는 '검수문에서 CRUD 단어를 피해서' 가 아니라 "
            "'변경 파일에 DB 코드가 실제로 없어서' 주어진 것이다."
        )
        print(
            "     DB 코드가 1건이라도 생기거나 파일을 못 읽으면 즉시 차단으로 되돌아온다."
        )
        return 0

    # 면제 불가 — 왜 불가인지 남긴다(조용히 차단하지 않는다).
    _db_reason = db_detail.get("reason")
    if _db_reason == "db_found":
        print(
            f"DB_CONTACT_DETECTED: 변경 파일 {db_detail['total']}개 중 DB 접속/DML 발견 "
            "— 무접촉 면제 불가(종전 판정 유지)"
        )
        for f, m in db_detail["hits"]:
            print(f"  - {f}: {m}")
        if db_detail.get("fixture_only"):
            # 정보 줄 — rc·판정 무변경. 분류기(crud_fail_triage.py)가 RECHECK 로 읽는다.
            print(f"DB_HITS_TEST_FIXTURE_ONLY: {len(db_detail['hits'])}")
    elif _db_reason == "unreadable":
        print(
            "DB_SCAN_UNVERIFIABLE: 변경 파일 일부를 판독하지 못해 무접촉 면제 불가 "
            "(fail-closed — 안 본 파일은 무해가 아니다)"
        )
        for f, e in db_detail["unreadable"]:
            print(f"  - {f}: {e}")
    elif _db_reason == "no_assignment":
        print(
            "DB_SCAN_UNVERIFIABLE: file_assignment.json 을 읽지 못해 무접촉 면제 불가 "
            f"(fail-closed) — {db_detail.get('error', '')}"
        )
    elif _db_reason == "no_files":
        print(
            "DB_SCAN_UNVERIFIABLE: file_assignment.json 에 변경 파일 목록이 비어 "
            "무접촉 면제 불가 (fail-closed — 대조 대상이 없으면 근거도 없다)"
        )
        if db_detail.get("deleted"):
            print(f"  삭제 확정 {len(db_detail['deleted'])}개를 뺀 뒤 판독한 파일이 0개다.")

    if not os.path.isfile(evidence_path):
        # 🔴 ★부트스트랩 교착 해소★ (otest-c31 신고, 2026-08-24 실측)
        #    종전에는 여기서 return 1 했다. 그런데 write_guard.sh F-CRUD-1 이
        #    make_ok "쓰기"를 가로채 이 스크립트를 돌리므로, 최초 생성 시점에는
        #    ★항상★ 파일이 부재다 ⇒ 첫 쓰기가 100% 차단되고,
        #    막혀서 파일을 못 만들고, 파일이 없어서 또 막히는 교착이 생겼다.
        #    ("make_ok 이 없어서 막고, 막혀서 make_ok 을 못 만든다")
        #
        #    ⇒ 파일 부재는 "아직 쓰지 않은 상태"이지 "저장을 안 태운 상태"가 아니다.
        #      둘을 구분하지 못한 것이 결함이었다. 부재는 통과시키고,
        #      ★내용이 있는데 증거가 불충분할 때★ 차단한다.
        #
        #    ⚠️ 이때 "최초 1회 쓰기가 무검증 통과"하는 구멍이 생기지만 봉인돼 있다:
        #      otest_done 은 ★항상 make_ok 이후★ 에 쓰이고, 그 시점엔 make_ok 이
        #      실존하므로 내용 검사가 반드시 돈다. 즉 최종 PASS 마킹은 빠져나갈 수 없다.
        #      (게이트를 무르게 한 것이 아니라, 검사 시점을 옳은 곳으로 옮긴 것이다.)
        if args.final:
            # ★사이클172 C25 — PARTIAL 은 PARTIAL 로 기록할 수 있어야 한다★
            #   make_ok 대신 make_partial(--emit-from-goal 산출)이 미통과를 명시했으면, 그 미통과
            #   CRUD 항목을 "통과"가 아니라 "PARTIAL 로 기록됨"으로 인정한다. PASS 로 기록된 CRUD
            #   항목은 여전히 write_log+상태변화 증거가 필요하다(FAIL→PASS 경로 없음).
            ack_ev_map = _item_evidence_map(criteria_path) if criteria_path and os.path.isfile(criteria_path) else {}
            ack_ok, ack_lines, ack_passed = _acknowledge_partial(evidence_path, crud_items, ack_ev_map)
            if ack_ok and ack_passed:
                # ★c177 결함2★ PARTIAL 인정 경로도 PASS 로 인정된 CRUD 항목은 스냅샷 선행 검사를 거친다.
                #   종전엔 여기서 바로 return 0 해 make_ok·emit 경로에 있는 검사(L-1200, C26)를 건너뛰었다.
                #   strict: 빈 스냅샷(크기 0·rows=[])과 옛 스냅샷(criteria created_at / pipeline 시작 이전)도 막는다.
                #   live_rows:false 면제는 종전 규칙 그대로다.
                partial_path = os.path.join(os.path.dirname(evidence_path), "make_partial")
                pj, pr = load_evidence(partial_path)
                sess_dir = os.path.dirname(os.path.dirname(os.path.abspath(evidence_path)))
                fresh_after = _snapshot_fresh_bound(criteria_path, sess_dir)
                if fresh_after is None:
                    print("SNAPSHOT_FRESHNESS_UNCHECKED: 기준시각(criteria created_at / pipeline 시작시각) 없음 "
                          "— 옛 스냅샷 판정만 생략(존재·형식·빈 스냅샷·쓰기 선후 검사는 수행)")
                if _main_snapshot_fail(ack_passed, pj, pr, criteria_path, partial_path,
                                       strict=True, fresh_after=fresh_after):
                    print("  (PARTIAL 인정 경로도 PASS 로 기록된 CRUD 항목은 스냅샷 선행 검사를 거친다 — c177 결함2)",
                          file=sys.stderr)
                    for line in ack_lines:
                        print(line, file=sys.stderr)
                    return 1
            if ack_ok:
                print(
                    f"PARTIAL_ACKNOWLEDGED: make_ok 부재 + make_partial 이 미통과를 명시 — "
                    f"CRUD 항목 {len(crud_items)}건을 PARTIAL 로 기록 허용(통과 아님)"
                )
                for line in ack_lines:
                    print(line)
                print("  ⚠️ otest_done 내용은 'PARTIAL' 로 시작하고 미통과 id 를 나열하라. PASS 로 쓰지 마라.")
                return 0
            for line in ack_lines:
                print(line, file=sys.stderr)
            # 최종 마킹 시점에 evidence 가 아예 없다 = 검증을 하지 않은 것이다.
            # 부트스트랩 예외는 make_ok "쓰기" 시점에만 유효하며 여기까지 오면 안 된다.
            print(
                "MISSING_CRUD_EVIDENCE: 최종 마킹 시점에 evidence 부재 — PASS 마킹 거부",
                file=sys.stderr,
            )
            print(
                f"  대상 CRUD 항목 {len(crud_items)}건 / evidence={evidence_path}",
                file=sys.stderr,
            )
            print(
                "  make_ok 을 먼저 기록하라. 저장을 태우지 않았다면 그것은 미검증이지 통과가 아니다.",
                file=sys.stderr,
            )
            return 1
        print(
            f"EVIDENCE_NOT_YET_WRITTEN: {evidence_path} 미생성 — 최초 기록 허용 (통과). "
            f"CRUD 항목 {len(crud_items)}건은 otest_done 마킹 시점에 전수 검사된다."
        )
        return 0

    try:
        evidence_json, evidence_raw = load_evidence(evidence_path)
    except OSError as exc:
        print(f"INPUT_ERROR: evidence 읽기 실패 — {exc}", file=sys.stderr)
        return 2

    violations = []
    main_ev_map = _item_evidence_map(criteria_path) if criteria_path and os.path.isfile(criteria_path) else {}
    for item in crud_items:
        item_id = str(item.get("id") or item.get("ID") or item.get("name") or "").strip()
        label = item_id or _norm(item.get("criterion", ""))[:40]
        # c177 결함1: AC 행이 없으면 goal_id 정확 일치 행을 AC 단위 레코드로 본다(증거는 그 AC 자신의 파일)
        result = _resolve_result(evidence_json, evidence_raw, item, main_ev_map)

        has_log = has_write_log_evidence(result)
        has_delta = has_state_change_evidence(result)

        # ★둘 다★ 있어야 PASS 로 인정한다. 하나만으로는 저장을 태웠다고 볼 수 없다.
        if has_log and has_delta:
            continue

        missing = []
        if not has_log:
            missing.append("저장 경로 실행 로그")
        if not has_delta:
            missing.append(
                "DB 상태 변화 실측"
                "(COUNT 변화 / 행집합·값 변화 / 갱신시각 변화 중 하나)"
            )

        note = ""
        if is_guard_only(item, result):
            note = " [차단 확인만 존재 — 차단은 저장 검증이 아니다]"

        violations.append(f"  - {label}: 누락 = {', '.join(missing)}{note}")

    if violations:
        print("MISSING_CRUD_EVIDENCE: CRUD 실행 증거 불충분 — PASS 마킹 거부", file=sys.stderr)
        for line in violations:
            print(line, file=sys.stderr)
        print("", file=sys.stderr)
        print(
            "  '운영 데이터 보호'는 검증 면제 사유가 아니라 개발 DB 를 사용해야 할 사유다.",
            file=sys.stderr,
        )
        print(
            "  개발 DB 에서 실제로 저장을 태우고, 상태 변화를 실측해 evidence 에 기록하라.",
            file=sys.stderr,
        )
        print(
            "  ⚠️ COUNT 불변 = 미실행 이 아니다. 전건 DELETE→재INSERT(예: t_ProjectCategory)나 "
            "UPDATE 형 저장은 COUNT 가 그대로다.",
            file=sys.stderr,
        )
        print(
            "     그 경우 rowset_before/after(행 집합), value_before/after(컬럼 값), "
            "modified_before/after(갱신 시각) 중 하나로 기록하라.",
            file=sys.stderr,
        )
        return 1

    # 실업무 행 스냅샷 선행 검사 — 수기 make_ok(main/--final 경로)에도 적용 (사이클172 C26, 리드 결정 12:35)
    if _main_snapshot_fail(crud_items, evidence_json, evidence_raw, criteria_path, evidence_path):
        return 1

    print(f"CRUD_EVIDENCE_OK: CRUD 항목 {len(crud_items)}건 전부 실행 증거 확인")
    return 0


if __name__ == "__main__":
    sys.exit(main())
