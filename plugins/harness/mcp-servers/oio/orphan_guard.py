# 고아 팀에이전트 잔존 시 agents/·panes/ 삭제를 거부하는 oio 서버측 가드 (H-1 우회로 봉쇄)
"""
배경
----
hooks/write_guard.sh 의 H-1 가드는 Claude Code 도구 호출 경로만 검사한다.
oio MCP 를 직접 호출하는 경로는 hook 을 우회하므로 agents/ 가 삭제될 수 있었다.
본 모듈이 그 마지막 우회로를 막는다.
증적: .claude/evidence/agent_orphan_cleanup_20260817.md

설계 원칙 (H-1 과 동일)
----------------------
1. 검사 로직 복붙 금지 — hooks/lib/orphan_scan.sh 를 subprocess 로 호출한다.
   NUL 함정(/proc/{pid}/cmdline 는 NUL 구분이라 grep 불가) 처리가 그 파일 한 곳에만 존재해야 한다.
2. ★ fail-open 최우선 — oio 는 모든 파일 작업의 관문이다.
   여기서 fail-closed 로 잘못 만들면 4개 프로젝트의 파일 입출력이 전면 마비된다.
   따라서 "확실히 잔존>0 이라고 판정된 경우"에만 거부하고, 그 외 모든 상황은 통과시킨다.
   - 스크립트 부재 / 실행 실패 / 타임아웃 / 비정수 출력 / 예외 → 전부 통과
3. 긴급 정지 스위치 공유 — hooks/lib/orphan_scan.sh 를 지우면
   H-1(write_guard) · H-2(SessionStart) · 본 가드가 **동시에** 무력화된다.
4. 타임아웃 필수 — oio 는 동기 호출 경로다. 2초 초과 시 통과시킨다.
5. 범위 최소화 — session-env/<uuid>/(agents|panes) 경로에만 발동한다.
   그 외 경로는 정규식 1회 검사 후 즉시 통과하므로 오버헤드가 사실상 없다.
"""
import os
import subprocess

# ★ 3차 보강 (2026-08-17) — 자체 정규식을 **완전히 제거**했다.
#
# 1차 구현은 여기에 파이썬 정규식을 두고 hook 은 bash 정규식을 따로 두었다.
# 그 결과 양쪽이 **동일한 결함을 공유**해 이중 방어가 성립하지 않았다(otest-1 실측).
#   B1 session-env/<uuid> 상위 통째 / B2 "./agents" / B4 "logs/../agents"
#   → 세 경로 모두 hook 과 oio 를 동시에 통과했다.
#
# 이제 경로 정규화·대상 판정·삭제성 판정을 전부 orphan_scan.sh 의
# `check-path` 서브커맨드에 위임한다. 판정 로직은 그 파일 한 곳에만 존재하므로
# 두 계층이 구조적으로 어긋날 수 없다.

# 검사 스크립트 위치 — 홈 경로가 표준이므로 이를 우선 사용하고,
# 플러그인 배포본에서는 플러그인 동봉 hooks 를 폴백으로 둔다.
# CLAUDE_PLUGIN_ROOT 는 플러그인 실행 시에만 설정되므로 부재 시 후보에서 빠진다.
# (부재해도 fail-open 설계상 통과되므로 동작에 영향이 없다.)
_SCAN_CANDIDATES = tuple(
    p for p in (
        os.path.expanduser("~/.claude/hooks/lib/orphan_scan.sh"),
        (
            os.path.join(
                os.environ["CLAUDE_PLUGIN_ROOT"], "hooks", "lib", "orphan_scan.sh"
            )
            if os.environ.get("CLAUDE_PLUGIN_ROOT")
            else None
        ),
    )
    if p
)

_TIMEOUT_SEC = 2.0


def _find_scan_script():
    """검사 스크립트 경로 반환. 없으면 None(→ 호출부가 통과시킨다)."""
    for p in _SCAN_CANDIDATES:
        try:
            if os.path.isfile(p) and os.access(p, os.R_OK):
                return p
        except Exception:
            continue
    return None


def _check_path(path: str, command: str = ""):
    """
    orphan_scan.sh check-path 에 판정을 위임한다.

    반환:
      ("BLOCK", uuid, count)  차단해야 함
      None                    통과 (대상 아님 / 잔존 0건 / 판정 불가)

    판정 불가한 모든 경우 None 을 돌려주며, 호출부는 이를 '통과'로 처리해야 한다(fail-open).
    """
    script = _find_scan_script()
    if not script:
        return None  # 긴급 정지 스위치가 당겨진 상태 → 통과

    try:
        proc = subprocess.run(
            ["bash", script, "check-path", str(path), str(command or "")],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=_TIMEOUT_SEC,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return None  # 타임아웃 → 통과 (파일 작업을 지연시키지 않는다)
    except Exception:
        return None  # 실행 실패 → 통과

    if proc.returncode != 0:
        return None

    out = (proc.stdout or b"").decode("utf-8", "replace").strip()
    if not out.startswith("BLOCK"):
        return None  # PASS / UNKNOWN / 빈 출력 → 전부 통과

    parts = out.split()
    if len(parts) < 3 or not parts[2].isdigit():
        return None  # 형식이 어긋나면 통과 (fail-open)

    return ("BLOCK", parts[1], int(parts[2]))


def check_orphan_block(path: str, command: str = ""):
    """
    삭제 대상 경로를 검사한다.
    - 거부해야 하면 oio 표준 에러 dict 를 반환한다.
    - 통과시켜야 하면 None 을 반환한다(정상 흐름 계속).

    ★ 이 함수는 어떤 경우에도 예외를 밖으로 던지지 않는다.
      최상위 try/except 로 감싸 예외 발생 시에도 None(통과)을 반환한다 — fail-open 보장.
    """
    try:
        if not path:
            return None

        verdict = _check_path(str(path), command)
        if verdict is None:
            return None  # 대상 아님 / 잔존 0건 / 판정 불가 → 전부 통과

        _, uuid, cnt = verdict

        # ★메시지를 잔존수로 분기한다★ — 사이클42 T3.
        #   종전에는 cnt 와 무관하게 "팀에이전트 N건이 아직 살아있는데" 를 썼다.
        #   그런데 최상위 경로 보호(orphan_scan.sh:284 __ALWAYS__)는 잔존수를 보지 않고
        #   cnt=0 으로 차단하므로 ★"0건이 아직 살아있는데"★ 라는 자기모순 문장이 나왔다.
        #   조사자가 이 문구를 원인으로 믿고 고아를 찾다가 오진한다(실제 발생).
        if cnt > 0:
            _msg = (
                f"팀에이전트 {cnt}건이 아직 살아있는데 세션 추적 근거"
                "(agents/panes 또는 session-env)를 삭제하려 합니다. "
                "지금 지우면 고아가 영구 미탐지됩니다. 먼저 종료를 완결하세요(oinit)."
            )
            _sug = "/oinit 로 팀에이전트 종료를 완결한 뒤 재시도하세요. "
        else:
            _msg = (
                "세션 추적 근거(session-env 등) 최상위 경로는 고아 유무와 무관하게 "
                "보호됩니다. 개별 세션은 session-env/<uuid> 단위로 정리하세요."
            )
            _sug = ""

        # ★읽기 명령이 막힌 경우의 안내★ — 사이클42 T3.
        #   보호 경로를 ★읽기만★ 하려는데 막히는 경우가 실재한다.
        #   본 가드는 bash_exec 의 ★명령 문자열 전체★ 를 원자적으로 판정하므로,
        #   읽기와 삭제가 한 호출에 섞이면 읽기 부분까지 통째로 차단된다(설계).
        #   종전 suggestion 은 "/oinit" 뿐이라 이 경우 ★틀린 안내★ 를 줬다 —
        #   안내가 없는 것보다 나쁘다. 막힌 그 순간 읽는 유일한 텍스트이므로 여기에 둔다.
        _sug += (
            "삭제 의도가 없었다면: 읽기 명령(ls/find/grep/cat)과 "
            "삭제·이동 명령(rm/mv/-delete)을 ★같은 bash_exec 호출에 섞지 마세요★ — "
            "한 호출은 통째로 판정되므로 읽기까지 차단됩니다. 읽기만 단독 호출하면 통과합니다. "
            "원인 확정: bash <hooks/lib>/orphan_scan.sh check-path <경로> '<명령>' "
            "(설치 환경의 hooks/lib 경로 — 표준: ~/.claude/hooks/lib, 플러그인: ${CLAUDE_PLUGIN_ROOT}/hooks/lib) "
            "⇒ PASS / BLOCK / UNKNOWN. "
            "긴급 시 hooks/lib/orphan_scan.sh 를 이동하면 본 가드가 무력화됩니다."
        )

        return {
            "success": False,
            "error": "ORPHAN_AGENTS_ALIVE",
            "message": _msg,
            "path": path,
            "orphan_count": cnt,
            "session_uuid": uuid,
            "suggestion": _sug,
        }
    except Exception:
        return None  # 어떤 예외도 파일 작업을 막지 않는다 — fail-open 최종 안전망
