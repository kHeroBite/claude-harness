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
    try:
        with open(file_assignment_path, "r", encoding="utf-8") as fp:
            assignment = json.load(fp)
    except (OSError, json.JSONDecodeError) as exc:
        return None, str(exc)

    all_files = []
    agents = assignment.get("agents", {}) if isinstance(assignment, dict) else {}
    if isinstance(agents, dict):
        for agent_info in agents.values():
            if isinstance(agent_info, dict):
                files = agent_info.get("files", [])
                if isinstance(files, list):
                    all_files.extend(str(f) for f in files)

    suspects = [f for f in all_files if CRUD_SUSPECT_PATTERN.search(f)]
    return suspects, None


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

    if suspects:
        print(
            "CRUD_DECLARATION_OVERRIDDEN: crud_대상=false 선언이 실제 변경 파일과 모순 — "
            "면제 무효화(fail-closed, 경로 기인)",
            file=sys.stderr,
        )
        for f in suspects:
            print(f"  - CRUD 의심 파일: {f}", file=sys.stderr)
        return False, "path"

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
       일부 테이블의 저장은 ★전건 DELETE → 전건 재INSERT★ 구조라
       (저장 루틴에서 DELETE 후 foreach INSERT 하는 패턴),
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

    if not os.path.isfile(criteria_path):
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

    try:
        items = load_criteria(criteria_path)
    except (OSError, json.JSONDecodeError) as exc:
        print(f"INPUT_ERROR: acceptance_criteria.json 파싱 실패 — {exc}", file=sys.stderr)
        return 2

    # ★비-CRUD 작업 선언 면제★ (L-465 재발방지 — F-CRUD-1 v2)
    #   crud_대상=false 선언 + file_assignment.json 재대조로 무효화 안 되면 전체 면제한다.
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

    exempt, invalid_reason = is_non_crud_declared(criteria_raw_data, file_assignment_path)
    if exempt:
        reason = str(criteria_raw_data.get("crud_미해당_사유", "")).strip()
        print(f"NON_CRUD_EXEMPT: 비-CRUD 작업 선언으로 면제 — 사유: {reason}")
        return 0

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
        return 1

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

        if item_crud_declared_false and item_crud_suspect_files:
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
        return 0

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
    for item in crud_items:
        item_id = str(item.get("id") or item.get("ID") or item.get("name") or "").strip()
        label = item_id or _norm(item.get("criterion", ""))[:40]
        result = find_result(evidence_json, evidence_raw, item_id)

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

    print(f"CRUD_EVIDENCE_OK: CRUD 항목 {len(crud_items)}건 전부 실행 증거 확인")
    return 0


if __name__ == "__main__":
    sys.exit(main())
