#!/usr/bin/env python3
# F-CRUD-1 판정기(verify_crud_executed.py) FAIL 출력을 6종으로 분류만 하는 분류기 — 판정·통과 결정은 하지 않는다
"""
사용: python3 crud_fail_triage.py --rc N < 판정기출력(stdout+stderr)
출력: stdout 1줄  CLASS=<C> ACTION=<A> HINT=<한 줄 한국어>
종료: 항상 rc 0 (분류 실패 → CLASS=UNKNOWN)

CLASS / ACTION (우선순위 순):
  TEST_FIXTURE_ONLY     RECHECK          — `DB_HITS_TEST_FIXTURE_ONLY:` 줄 존재. 다른 FAIL 코드와 함께 있어도 먼저.
  DECLARATION_CONFLICT  REROUTE_PLAN     — `CRUD_DECLARATION_OVERRIDDEN:` 줄 존재
  EVIDENCE_MISSING      REROUTE_DEV      — `MISSING_CRUD_EVIDENCE:` / `MISSING_SNAPSHOT_EVIDENCE:` 줄 존재
  SCAN_UNVERIFIABLE     REROUTE_DEV      — `DB_SCAN_UNVERIFIABLE:` 줄만 있음(위 코드 없음)
  INPUT_ERROR           RETRY_AFTER_FIX  — rc 2 또는 `INPUT_ERROR:` 줄 존재
  UNKNOWN               REROUTE_DEV      — 그 밖

★이 분류기는 통과를 주지 않는다 (L-467 — 선언은 검증을 이길 수 없다)★
  RECHECK 는 "판정기를 --exclude-test-fixtures 로 한 번 더 돌려라"는 뜻일 뿐이다.
  통과 여부는 재판정한 판정기의 rc 만이 결정한다. 출력 문자열을 위조해 RECHECK 를 끌어내도
  재판정은 픽스처 경로 매치만 빼고 나머지 축(경로·증거·스냅샷)을 그대로 검사한다.
  코드 인식은 줄머리 고정(`^CODE:`)으로만 한다 — 판정기가 들여쓰기("  - 파일: 매치")로
  옮겨 적는 파일 내용·경로 안의 같은 문자열은 코드로 인식하지 않는다.
"""
import re
import sys

# (CLASS, ACTION, HINT) — HINT 는 개행 없는 한 줄이어야 한다.
_TABLE = {
    "TEST_FIXTURE_ONLY": (
        "RECHECK",
        "DB 흔적이 전부 시험 픽스처 파일에만 있다 — 판정기를 --exclude-test-fixtures 로 1회 재판정하고 그 결과를 다시 분류하라",
    ),
    "DECLARATION_CONFLICT": (
        "REROUTE_PLAN",
        "비-CRUD 선언이 실제 변경 파일 또는 AC 본문과 모순된다 — PLAN 역라우팅으로 AC 의 item_crud·문구와 file_assignment 를 정정하라",
    ),
    "EVIDENCE_MISSING": (
        "REROUTE_DEV",
        "CRUD 실행 증거 또는 스냅샷 선행 증거가 부족하다 — DEV 역라우팅으로 개발 DB 에서 저장을 실행하고 write_log·상태변화 증거를 보강하라",
    ),
    "SCAN_UNVERIFIABLE": (
        "REROUTE_DEV",
        "변경 파일을 판독하지 못해 DB 무접촉을 확인할 수 없다 — DEV 역라우팅으로 판독 실패 파일과 file_assignment 를 정정하라",
    ),
    "INPUT_ERROR": (
        "RETRY_AFTER_FIX",
        "판정기 입력 오류다 — criteria·evidence 경로와 JSON 형식을 확인한 뒤 다시 실행하라",
    ),
    "UNKNOWN": (
        "REROUTE_DEV",
        "알려진 FAIL 코드로 분류되지 않았다 — 판정기 출력 원문을 확인하고 DEV 역라우팅으로 원인을 고쳐라",
    ),
}


def _has(text, code):
    """판정기 코드가 줄머리(`^CODE:`)에 있는가. 들여쓴 인용 줄은 세지 않는다."""
    return re.search(r"^" + re.escape(code) + r":", text, re.MULTILINE) is not None


def classify(text, rc):
    """판정기 출력과 rc 로 CLASS 를 정한다. 판정(통과/차단)은 하지 않는다."""
    if re.search(r"^DB_HITS_TEST_FIXTURE_ONLY: *\d+", text, re.MULTILINE):
        return "TEST_FIXTURE_ONLY"
    if _has(text, "CRUD_DECLARATION_OVERRIDDEN"):
        return "DECLARATION_CONFLICT"
    if _has(text, "MISSING_CRUD_EVIDENCE") or _has(text, "MISSING_SNAPSHOT_EVIDENCE"):
        return "EVIDENCE_MISSING"
    if _has(text, "DB_SCAN_UNVERIFIABLE"):
        return "SCAN_UNVERIFIABLE"
    if rc == 2 or _has(text, "INPUT_ERROR"):
        return "INPUT_ERROR"
    return "UNKNOWN"


def _parse_rc(argv):
    """--rc N / --rc=N 을 읽는다. 없거나 숫자가 아니면 None."""
    for i, arg in enumerate(argv):
        value = None
        if arg == "--rc" and i + 1 < len(argv):
            value = argv[i + 1]
        elif arg.startswith("--rc="):
            value = arg[len("--rc="):]
        if value is not None:
            try:
                return int(value.strip())
            except ValueError:
                return None
    return None


def main(argv):
    cls = "UNKNOWN"
    try:
        rc = _parse_rc(argv)
        data = sys.stdin.buffer.read() if not sys.stdin.isatty() else b""
        text = data.decode("utf-8", errors="replace").replace("\r", "")
        cls = classify(text, rc)
    except Exception:  # 분류 실패는 UNKNOWN 으로 — 이 스크립트는 rc 로 실패를 알리지 않는다
        cls = "UNKNOWN"
    action, hint = _TABLE[cls]
    sys.stdout.write(f"CLASS={cls} ACTION={action} HINT={hint}\n")
    return 0


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except Exception:
        sys.stdout.write("CLASS=UNKNOWN ACTION={} HINT={}\n".format(*_TABLE["UNKNOWN"]))
    sys.exit(0)
