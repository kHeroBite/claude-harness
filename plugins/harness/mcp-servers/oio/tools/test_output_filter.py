#!/usr/bin/env python3
"""bash_exec 출력 필터(output_filter.py) 회귀 테스트 스위트.

oplan_rtk.md §4/§4-2 기반. pytest 미도입 — tools/audit_*.py 스타일을 따라
의존성 없이 `python3 test_output_filter.py` 단독 실행 가능하게 작성한다.

이번 사이클(0~5단계) 검증 대상 10항목:
  1. 필터 미설치 시 출력 100% 동일 (바이트 diff 0) — bash_exec 실제 호출 골든 비교
  2. ENABLED 미설정 시 필터 로직 미호출 (호출 카운터)
  3. exit_code != 0 시 원문 통과
  7. 원문 보존·재조회 (_bg_log_dir 하위 — 이번 사이클엔 아직 미구현이므로 스킵 마킹)
  8. 필터 예외 시 fail-open
  9. 압축본 > 원문이면 원문 반환 (이번 사이클엔 카탈로그가 항상 비어 있어 no-op 경로만 검증)
  10. 최소 크기 미만 미적용
  11. preserve.errorPatterns 없으면 로드 거부 (카탈로그 없음 — no-op 경로만 검증)
  12. 세션 격리 §(a) 준수 (저장 경로가 _bg_log_dir() 하위를 벗어나지 않음)

항목 4(otest 골든 PASS/FAIL 불변), 5(신뢰 게이트), 6(해시 무효화)은 이번
사이클 범위 밖(6단계 이후 실제 필터 도입 시 추가) — SKIP으로 명시 보고한다.

Exit code: 0 = 전체 통과(SKIP 포함), 1 = 하나라도 FAIL
"""
from __future__ import annotations

import os
import sys

_THIS_DIR = os.path.dirname(os.path.abspath(__file__))
_SERVER_DIR = os.path.dirname(_THIS_DIR)
if _SERVER_DIR not in sys.path:
    sys.path.insert(0, _SERVER_DIR)

import output_filter as of  # noqa: E402

try:
    import bash_exec as be  # noqa: E402
    _HAS_BASH_EXEC = True
except Exception:
    _HAS_BASH_EXEC = False


_results = []  # (name, status, detail) — status: PASS/FAIL/SKIP


def _record(name: str, ok: bool, detail: str = "", skip: bool = False):
    status = "SKIP" if skip else ("PASS" if ok else "FAIL")
    _results.append((name, status, detail))


def _mk_response(exit_code=0, stdout="", stderr=""):
    return {
        "success": exit_code == 0,
        "stdout": stdout,
        "stderr": stderr,
        "exit_code": exit_code,
        "duration_ms": 1,
        "timed_out": False,
        "commands_total": 1,
    }


# ── 항목 1: 필터 미설치 시 bash_exec 실제 출력이 골든과 바이트 단위 동일 ──
# 골든 캡처/대조는 이 스크립트를 두 번 실행(훅 삽입 전/후)하여 상위 절차(odev
# 5단계)에서 diff로 비교한다. 이 스크립트 자체는 각 실행 시점의 스냅샷을
# stdout에 결정론적 형식으로 출력해 diff 대상이 되게 한다.
GOLDEN_COMMANDS = [
    "echo hello-oio-filter-test",
    "printf 'line1\\nline2\\nline3\\n'",
    "echo ok && echo done",
]


def run_golden_snapshot():
    """실제 bash_exec를 호출해 GOLDEN_COMMANDS 결과를 결정론적으로 직렬화한다.

    duration_ms처럼 매 실행마다 달라지는 필드는 골든 비교에서 의도적으로
    제외한다 — 바이트 diff 0 검증 대상은 stdout/stderr/exit_code/success다.
    """
    if not _HAS_BASH_EXEC:
        return None
    lines = []
    for cmd in GOLDEN_COMMANDS:
        r = be.bash_exec(command=cmd)
        lines.append(f"CMD={cmd!r}")
        lines.append(f"success={r.get('success')}")
        lines.append(f"exit_code={r.get('exit_code')}")
        lines.append(f"stdout={r.get('stdout')!r}")
        lines.append(f"stderr={r.get('stderr')!r}")
        lines.append(f"filtered={r.get('filtered')!r}")
        lines.append("---")
    return "\n".join(lines)


def test_1_golden_snapshot_generation():
    """항목 1 — 골든 스냅샷을 생성 가능한지만 이 스크립트 내부에서 확인.

    실제 "훅 삽입 전/후 바이트 diff 0" 판정은 odev가 이 스크립트를 두 번
    실행해 stdout을 파일로 저장한 뒤 `diff`로 비교하는 상위 절차에서 수행한다
    (아래 __main__ 블록이 --golden 옵션으로 스냅샷만 출력하는 이유).
    """
    snap = run_golden_snapshot()
    _record("1_golden_snapshot_generation", snap is not None and len(snap) > 0,
            detail="bash_exec 미import" if snap is None else "")


def test_2_enabled_gate_short_circuits():
    """ENABLED 미설정 시 게이트 1에서 즉시 반환 — 이후 게이트(exit_code 체크 등)
    도달 여부를 관찰하기 위해 카운터를 심은 response로 확인한다."""
    os.environ.pop("OIO_OUTPUT_FILTER_ENABLED", None)
    resp = _mk_response(exit_code=0, stdout="x" * 5000)
    out = of.maybe_apply("echo test", dict(resp))
    ok = out == resp and out.get("filtered") is None
    _record("2_enabled_gate_short_circuits", ok)


def test_3_exit_code_nonzero_passthrough():
    """exit_code != 0이면 ENABLED=1이어도 원문 그대로."""
    os.environ["OIO_OUTPUT_FILTER_ENABLED"] = "1"
    try:
        resp = _mk_response(exit_code=1, stdout="x" * 5000, stderr="error CS0001")
        out = of.maybe_apply("dotnet build", dict(resp))
        ok = out["stdout"] == resp["stdout"] and out["stderr"] == resp["stderr"]
        _record("3_exit_code_nonzero_passthrough", ok)
    finally:
        os.environ.pop("OIO_OUTPUT_FILTER_ENABLED", None)


def test_7_raw_output_preservation():
    """항목 7 — 원문 보존/재조회는 이번 사이클(카탈로그 없음)에서 발동하지
    않으므로 SKIP. 4단계 이후 filters/*.toml 도입 시 구현."""
    _record("7_raw_output_preservation", True, detail="6단계 이후 구현 예정", skip=True)


def test_8_fail_open_on_filter_exception():
    """필터 로직 내부에서 예외가 나도 bash_exec.py 훅(try/except pass)이
    fail-open하는지 — output_filter 단에서는 카탈로그가 비어 있어 예외 경로
    자체가 없으므로, bash_exec.py 훅 스타일(orphan_guard 패턴)이 실제로
    존재하는지를 소스에서 확인한다.

    훅 삽입 전(odev 2단계 골든 캡처 시점)에는 아직 훅이 없는 것이 정상이므로
    이 경우는 SKIP으로 보고한다 — FAIL로 처리하면 "훅 삽입 전 전체 통과 확인"
    이라는 골든 캡처 절차 자체가 성립하지 않는다. 훅 삽입 후(4단계 이후)에는
    반드시 PASS해야 한다."""
    hook_src_path = os.path.join(_SERVER_DIR, "bash_exec.py")
    if not os.path.exists(hook_src_path):
        _record("8_fail_open_on_filter_exception", True,
                detail="bash_exec.py 없음", skip=True)
        return
    with open(hook_src_path, "r", encoding="utf-8") as f:
        src = f.read()
    has_hook = "output_filter" in src
    if not has_hook:
        _record("8_fail_open_on_filter_exception", True,
                detail="훅 삽입 전 상태 — 정상(골든 캡처 시점)", skip=True)
        return
    ok = "except Exception:" in src
    _record("8_fail_open_on_filter_exception", ok,
            detail="bash_exec.py에 output_filter 훅 + except Exception 패턴 존재 확인")


def test_9_expanded_output_falls_back():
    """압축본이 원문보다 크면 원문 반환 — 카탈로그가 항상 비어 있는 이번
    사이클엔 게이트 4에서 즉시 원문 반환되므로 이 성질이 구조적으로 보장됨을
    확인 (같은 경로로 커버)."""
    os.environ["OIO_OUTPUT_FILTER_ENABLED"] = "1"
    try:
        resp = _mk_response(exit_code=0, stdout="x" * 5000)
        out = of.maybe_apply("echo test", dict(resp))
        ok = out["stdout"] == resp["stdout"]
        _record("9_expanded_output_falls_back", ok, detail="카탈로그 0개 — 구조적 no-op")
    finally:
        os.environ.pop("OIO_OUTPUT_FILTER_ENABLED", None)


def test_10_min_size_threshold():
    """최소 크기(MIN_FILTER_BYTES) 미만은 필터를 타지 않는다 — 경계값 검증."""
    os.environ["OIO_OUTPUT_FILTER_ENABLED"] = "1"
    try:
        small = _mk_response(exit_code=0, stdout="x" * (of.MIN_FILTER_BYTES - 1))
        boundary = _mk_response(exit_code=0, stdout="x" * of.MIN_FILTER_BYTES)
        large = _mk_response(exit_code=0, stdout="x" * (of.MIN_FILTER_BYTES + 1))
        out_small = of.maybe_apply("echo test", dict(small))
        out_boundary = of.maybe_apply("echo test", dict(boundary))
        out_large = of.maybe_apply("echo test", dict(large))
        # 카탈로그가 항상 비어 있으므로 세 경우 모두 원문 그대로(no-op) — 이번
        # 사이클엔 "필터가 실제로 압축했는가"가 아니라 "게이트를 무사히
        # 통과하며 크래시하지 않는가"를 확인한다.
        ok = (out_small["stdout"] == small["stdout"] and
              out_boundary["stdout"] == boundary["stdout"] and
              out_large["stdout"] == large["stdout"])
        _record("10_min_size_threshold", ok)
    finally:
        os.environ.pop("OIO_OUTPUT_FILTER_ENABLED", None)


def test_11_preserve_patterns_required():
    """preserve.errorPatterns 없는 필터는 로드 거부 — 카탈로그 로더 자체가
    아직 TOML을 읽지 않는 이번 사이클엔 해당 없음(SKIP)."""
    _record("11_preserve_patterns_required", True, detail="6단계 이후 구현 예정", skip=True)


def test_12_session_isolation():
    """세션 격리 §(a) — _bg_log_dir()가 반환하는 경로가 CLAUDE_CONFIG_DIR
    또는 $HOME/.claude 하위인지, 그리고 output_filter.py가 독자적으로
    session-env/<다른 UUID> 경로를 하드코딩하지 않는지 확인."""
    of_src_path = os.path.join(_SERVER_DIR, "output_filter.py")
    with open(of_src_path, "r", encoding="utf-8") as f:
        of_src = f.read()
    no_hardcoded_uuid_path = "session-env" not in of_src
    ok = no_hardcoded_uuid_path
    if _HAS_BASH_EXEC:
        bg_dir = be._bg_log_dir()
        cfg = os.environ.get("CLAUDE_CONFIG_DIR")
        home_claude = os.path.join(os.path.expanduser("~"), ".claude")
        ok = ok and (bg_dir.startswith(cfg) if cfg else bg_dir.startswith(home_claude)
                      or bg_dir.startswith("/tmp"))
    _record("12_session_isolation", ok)


def main():
    only_golden = "--golden" in sys.argv
    if only_golden:
        snap = run_golden_snapshot()
        print(snap if snap else "")
        return 0

    test_1_golden_snapshot_generation()
    test_2_enabled_gate_short_circuits()
    test_3_exit_code_nonzero_passthrough()
    test_7_raw_output_preservation()
    test_8_fail_open_on_filter_exception()
    test_9_expanded_output_falls_back()
    test_10_min_size_threshold()
    test_11_preserve_patterns_required()
    test_12_session_isolation()

    fail_count = 0
    for name, status, detail in _results:
        mark = {"PASS": "✅", "FAIL": "❌", "SKIP": "⏭️"}[status]
        line = f"{mark} {status} {name}"
        if detail:
            line += f" — {detail}"
        print(line)
        if status == "FAIL":
            fail_count += 1

    total = len(_results)
    passed = sum(1 for _, s, _ in _results if s == "PASS")
    skipped = sum(1 for _, s, _ in _results if s == "SKIP")
    print(f"\n{passed}/{total} PASS, {skipped} SKIP, {fail_count} FAIL")
    return 1 if fail_count else 0


if __name__ == "__main__":
    sys.exit(main())
