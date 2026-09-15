"""세션 디렉토리(session-env) 파일을 두 base 에 미러링하는 공용 모듈.

── 왜 이 모듈이 있는가 (사이클40 실사고 — 2026-08-26) ─────────────────────
CLAUDE_CONFIG_DIR 가 설정된 격리 세션에서는 아래 두 경로가 동시에 실존한다.

    A) ${CLAUDE_CONFIG_DIR}/session-env/<uuid>/     (예: /tmp/cc-*/…)
    B) $HOME/.claude/session-env/<uuid>/

읽는 쪽의 base 해석이 갈리기 때문에(hook·스킬·oio 가 제각각) 어느 한쪽에만
기록되면 다른 쪽 독자가 상태 파일을 못 찾는다. session_ops.py 는 이 문제를
이미 알고 `_mirror_state_bases()` 로 ★전 키를 양쪽에 기록★ 하고 있었다.

그런데 file_ops.py 에는 그 미러링이 ★전혀 없었다★(grep 실측 0건).
⇒ 결과적으로 쓰기 경로에 따라 비대칭이 생겼다:

    mcp__oio__session_state → 양쪽  (state·status·auto·classification·entry_tier …)
    mcp__oio__file_write/edit → 한쪽 (goal.json·oralph_active …)

사이클40 실측 (mtime):
    auto       CCD 21:27:09  ← 21:23:55 차단 시점에는 CCD 쪽에 ★없었다★
    goal.json  CCD 15:29:41 / HOME ★부재★  (약 6시간 시차)

⇒ PreToolUse_oto_completion_guard.sh 의 "auto 가 있는 쪽을 정본으로" 폴백이
   HOME 을 골랐고, 거기엔 goal.json 도 oralph_active 도 없어 F-OTO-7b 가 발동했다.
   /oto(질문 없이 끝까지 완주)가 ★5시간 작업 후 종료 시점에★ 완주 실패로 끝났다.

본 모듈은 그 비대칭 자체를 없앤다. 증상(hook 오폴백)이 아니라 원인을 제거한다.

── ★이 모듈이 못 잡는 것★ (사이클40 A2 교훈 — 반드시 읽어라) ─────────────
 A. ★bash_exec 로 직접 쓰는 경우★ — 미러링되지 않는다.
    본 모듈은 oio 파일 도구 경로에만 붙는다. `echo > goal.json` 은 통과한다.
    ⇒ 보완: PreToolUse_session_path_guard.sh(F-PATH-1)가 다음 Skill 호출 때 검출한다.
 B. ★이미 갈려 있는 기존 상태★ — 고치지 않는다.
    본 모듈은 "앞으로의 쓰기"를 양쪽에 반영할 뿐, 과거에 생긴 갈림은 손대지 않는다.
    (임의 복구는 어느 쪽이 정본인지 모르는 채 덮어쓰는 것이라 더 위험하다.)
 C. ★타 세션 UUID 경로★ — ★막지 않는다★ (사이클41 정정 — 종전 설명은 틀렸다).
    미러는 원본 경로의 uuid·tail 을 그대로 쓰고 base 만 바꾸므로, 원본이 타 세션
    경로에 쓰였다면 미러도 그 세션의 반대 base 에 남는다. ★§(a) 강제 지점은
    원본 쓰기 경로★(write_guard.sh / security.validate_path)이며 본 모듈이 아니다.
    상세 근거는 mirror_targets() docstring 참조.
    ⚠️ 종전 구현은 여기서 환경변수로 자기 UUID 를 확인하려 했으나, 그 변수가
       서버 프로세스에 없어 ★미러링 전체가 영구 no-op★ 이었다(사이클41 실측).
 D. ★CLAUDE_CONFIG_DIR 미설정 환경★ — 두 base 가 동일해 미러 대상이 0개다.
    이 경우 본 모듈은 완전한 no-op 이며 오버헤드도 사실상 없다.
 E. ★디렉토리 단위 조작★(dir_delete 등) — 다루지 않는다. 파일 단위만 미러한다.
 F. ★미러 쪽이 원본과 다르게 수정된 경우★ — 마지막 쓰기가 이긴다.
    본 모듈은 병합하지 않고 원본을 그대로 복사한다(원본이 정본이라는 전제).

── 설계 결정 ──────────────────────────────────────────────────────────────
· ★범위 최소★: 경로에 "/session-env/<uuid>/" 가 없으면 즉시 반환한다.
  그 외 모든 파일 작업은 문자열 검사 1회 외에 오버헤드가 0 이다.
· ★fail-loud 채택★ (아래 §실패 정책): 미러 실패를 조용히 삼키지 않는다.
  session_ops.py 는 fail-soft 인데 본 모듈이 fail-loud 인 이유도 거기 적었다.
· ★원본 우선★: 원본 쓰기가 성공한 뒤에만 미러한다. 미러 실패가 원본을
  실패로 뒤바꾸지 않는다(결과 dict 에 경고만 실어 보낸다).
"""
import os
import shutil
import tempfile
import time as _time  # stale_module_warning() 의 시각 포맷/현재시각 전용 (사이클43)

# session_ops 와 동일한 base 해석을 쓴다 (단일 출처가 되도록 import 한다).
# import 실패 시에도 파일 작업이 죽지 않도록 자체 계산으로 폴백한다.
try:
    from session_ops import SESSION_ENV_BASE, SESSION_ENV_HOME_BASE
except Exception:  # pragma: no cover
    SESSION_ENV_BASE = os.path.join(
        os.environ.get('CLAUDE_CONFIG_DIR') or os.path.expanduser('~/.claude'),
        'session-env'
    )
    SESSION_ENV_HOME_BASE = os.path.join(os.path.expanduser('~/.claude'), 'session-env')

# 경계 검증은 security.py 의 공용 헬퍼에 위임한다 (사이클47 — 단일 출처).
# security.py 는 os·re 만 import 하는 최하위 계층이라 ★순환 import 가 없다★
# (session_mirror → session_ops 는 이미 존재하므로 그쪽으로는 위임할 수 없다).
# import 실패 시에도 파일 작업이 죽지 않도록 종전 길이 검사로 폴백한다
# (위 session_ops import 와 동일 양식).
try:
    from security import validate_session_mirror_path as _validate_mirror_path
except Exception:  # pragma: no cover
    def _validate_mirror_path(uuid: str, tail: str = "") -> bool:
        return bool(uuid) and len(uuid) == 36

_MARKER = os.sep + "session-env" + os.sep


def _split_session_path(path: str):
    """경로를 (base, uuid, 나머지) 로 분해한다. session-env 경로가 아니면 None.

    예: /tmp/cc-x/session-env/<uuid>/goal.json
        → ("/tmp/cc-x/session-env", "<uuid>", "goal.json")

    ★사이클47 — abspath 이전에 원문(raw)을 먼저 검증한다★:
      `os.path.abspath` 는 `..` 를 ★정규화해 없앤다★. 따라서 정규화된 문자열만
      검사하면 `<uuid>/../<타uuid>/state` 가 `<타uuid>/state` 로 바뀐 뒤 통과해
      ★탈출이 성립한다★. 원문 단계에서 `..` 를 거부해야 실제로 막힌다.
    """
    # (사이클47) 원문 단계 경계 검증 — abspath 가 `..` 를 지우기 ★전★ 에 판정한다.
    try:
        _raw = path.replace("\\", "/")
        _ridx = _raw.find("/session-env/")
        if _ridx >= 0:
            _rrest = _raw[_ridx + len("/session-env/"):]
            _rparts = _rrest.split("/", 1)
            if not _validate_mirror_path(
                _rparts[0], _rparts[1] if len(_rparts) > 1 else ""
            ):
                return None
    except Exception:
        return None

    try:
        norm = os.path.abspath(path)
    except Exception:
        return None
    idx = norm.find(_MARKER)
    if idx < 0:
        return None
    base = norm[: idx + len(_MARKER) - 1]          # ".../session-env"
    rest = norm[idx + len(_MARKER):]               # "<uuid>/…"
    if not rest:
        return None
    parts = rest.split(os.sep, 1)
    uuid = parts[0]
    tail = parts[1] if len(parts) > 1 else ""
    if not tail:
        return None                                 # 디렉토리 자체는 대상 아님(한계 E)
    # session-env 하위 첫 세그먼트는 36자 hex-hyphen UUID 여야 한다.
    # 종전에는 `len(uuid) != 36` 길이만 봤다 — 36자 비-hex·대문자가 통과했다.
    # 사이클47부터 security.validate_session_mirror_path() 에 위임한다(단일 출처).
    if not _validate_mirror_path(uuid, tail):
        return None
    return base, uuid, tail


def _self_uuid() -> str:
    """자기 세션 UUID — ★환경변수에 의존하지 않는다★ (사이클41 정정).

    ── ★왜 바뀌었나 (otest-c41 실측 — 이 함수가 영구 no-op 의 원인이었다)★ ──
    종전 구현은 `os.environ` 에서 PIPELINE_UUID / CLAUDE_SESSION_ID 를 읽었다.
    그런데 ★그 환경변수는 oio 서버 프로세스에 존재하지 않는다★.

      실측 (2026-08-26, 서버 10개 전수 /proc/<pid>/environ):
        CLAUDE_CONFIG_DIR  → ★전부 있음★
        HOME               → ★전부 있음★
        PIPELINE_UUID      → 🔴 ★0/10★
        CLAUDE_SESSION_ID  → 🔴 ★0/10★

    ⇒ _self_uuid() 가 ★항상 ""★ ⇒ mirror_targets() 가 fail-closed 로 [] 반환
    ⇒ 🔴 ★미러링이 단 한 번도 동작한 적이 없다 (영구 no-op)★.
      환경변수는 Claude Code 가 ★프롬프트 텍스트로★ 팀에이전트에 전달할 뿐,
      MCP 서버 프로세스의 environ 에는 주입되지 않는다. 따라서 ★서버를 재시작해도
      영원히 고쳐지지 않는다★ — 재시작으로 해결된다는 진단은 틀렸다.

    ★fail-closed 자체는 옳은 설계였다★. 문제는 "자기 것임을 증명할 수단"이
    애초에 도달하지 않아 ★안전이 아니라 무동작★ 이 됐다는 점이다.
    ⇒ 가드의 ★부재★ 가 가드의 ★통과★ 처럼 보이는 형태 (odev-c41-3 명명).

    ── 현재 구현: ★서버 프로세스의 부모 cmdline 에서 획득★ ──
    oio 서버는 자기를 띄운 claude 프로세스의 ★직계 자식★ 이다 (실측 10/10).
    팀에이전트의 claude 프로세스는 `--parent-session-id <uuid>` 를 갖는다.

    ⚠️ ★단 메인 세션의 claude 에는 그 인자가 없다★ (실측: `claude --continue`).
       따라서 이 경로는 ★팀에이전트에서만 성립★ 하며, 메인에서는 "" 를 반환한다.
       그래서 이것을 ★미러링의 필수 조건으로 삼지 않는다★ — mirror_targets()
       의 소유권 판정을 참조하라(경로 자체가 1순위 근거다).

    반환: 구하면 36자 UUID, 못 구하면 "".
    """
    # 1순위 — 환경변수 (미래에 주입될 가능성 + 테스트 하네스 주입 경로 보존)
    for key in ("PIPELINE_UUID", "CLAUDE_SESSION_ID"):
        v = os.environ.get(key)
        if v and len(v) == 36:
            return v

    # 2순위 — 부모 claude 프로세스의 --parent-session-id (팀에이전트 한정)
    try:
        ppid = os.getppid()
        with open(f"/proc/{ppid}/cmdline", "rb") as f:
            args = f.read().split(b"\0")
        for i, a in enumerate(args):
            if a == b"--parent-session-id" and i + 1 < len(args):
                v = args[i + 1].decode("utf-8", "replace")
                if len(v) == 36:
                    return v
    except Exception:
        pass

    return ""


def mirror_targets(path: str) -> list:
    """path 에 대응하는 ★미러 경로 목록★ 을 반환한다 (원본 제외).

    미러 대상이 아니면 빈 리스트. 아래 조건을 모두 만족해야 미러한다.
      1) 경로가 <base>/session-env/<36자 uuid>/<파일> 형태다
      2) 두 base(CCD / HOME)가 실제로 서로 다르다
      3) ★미러 대상이 원본과 ★같은 uuid·같은 tail★ 이다★ ← 세션 격리 §(a)

    ── ★세션 격리 §(a) 판정 근거 (사이클41 — 종전 env 게이트를 대체한다)★ ──
    종전에는 "환경변수의 자기 UUID == 경로의 UUID" 를 요구했다. 그 수단이
    서버 프로세스에 도달하지 않아 ★영구 no-op★ 이 됐다(_self_uuid docstring).

    ★현재 판정: 경로에 이미 들어 있는 UUID 를 그대로 쓴다.★
    이것이 §(a) 를 위반하지 않는 이유는 다음 세 가지다.

      ① ★미러는 새로운 쓰기 대상을 만들지 않는다★ — <uuid> 와 <tail> 을 원본에서
         그대로 가져오고 ★base 만 바꾼다★. 즉 "타 세션"이 아니라
         ★같은 세션의 다른 base★ 다. 교차 세션 경계를 넘지 않는다.
      ② ★원본 쓰기가 이미 그 UUID 경로에 일어난 뒤★ 에만 호출된다(apply() 는
         success=True 일 때만 미러한다). 원본이 §(a) 를 위반하는 쓰기였다면
         ★위반은 원본에서 이미 발생했고★ 미러가 새 위반을 만드는 것이 아니다.
         ⇒ §(a) 를 강제할 지점은 여기가 아니라 ★원본 쓰기 경로★ 다
           (write_guard.sh / security.validate_path 가 담당).
      ③ ★선례가 있다★ — session_ops.session_state(uuid, ...) 는 호출자가 준
         uuid 를 ★자기 것인지 검증하지 않고★ 그대로 양쪽 base 에 기록한다
         (_mirror_state_bases(uuid), 사이클27부터 전 키 미러). 본 모듈만
         더 엄격할 이유가 없고, 오히려 ★비대칭이 사이클40 사고의 원인★ 이었다.

    ⚠️ ★그래서 이 판정이 바꾸는 것과 바꾸지 않는 것★:
       바꾼다   — 미러가 ★실제로 동작한다★ (자기 세션 파일이 양쪽에 남는다).
       안 바꾼다 — ★타 세션 경로에 쓸 권한을 새로 주지 않는다★. 원본이 막히면
                  미러도 호출되지 않는다(apply 는 success 를 요구한다).
    """
    parsed = _split_session_path(path)
    if not parsed:
        return []
    _base, uuid, tail = parsed

    try:
        a = os.path.abspath(SESSION_ENV_BASE)
        b = os.path.abspath(SESSION_ENV_HOME_BASE)
    except Exception:
        return []
    if a == b:
        return []                                   # 한계 D — 미러 대상 없음

    try:
        src = os.path.abspath(path)
    except Exception:
        return []

    out = []
    for base in (a, b):
        cand = os.path.join(base, uuid, tail)
        if os.path.abspath(cand) != src:
            out.append(cand)
    return out


def stale_module_warning() -> str:
    """이 서버 프로세스가 ★구 코드★ 로 동작 중이면 경고 문자열을 반환한다 (사이클43).

    ── ★왜 이 함수가 있는가 (사이클43 실사고 — 2026-08-27)★ ──────────────────
    사이클41 은 file_ops.py 8~9개 쓰기 경로 전부에 미러링을 넣었다. ★소스는 옳았다.★
    그런데 사이클42 종료 시 `goal_G-C42-9F3D1C77_completed.json` 이 ★CFG 한쪽에만★
    생겼다. ofinish 는 셸 mv/cp 를 쓰지 않았고(oio file_copy 사용), file_copy 에는
    미러링이 붙어 있었다. ⇒ 코드에는 결함이 없었다.

    실측이 밝힌 진짜 원인 (mtime vs 프로세스 기동 시각):

        file_ops.py       수정 2026-08-26 21:52
        session_mirror.py 수정 2026-08-26 22:25
        ─────────────────────────────────────────
        oio 서버 PID 1532314  기동 14:31   ← 수정 ★이전★
        oio 서버 PID 1581544  기동 14:48   ← 수정 ★이전★ (사이클42 내내 현역)
        ─────────────────────────────────────────
        23:48  ofinish file_copy 실행 → 처리한 것은 1581544(구 코드)
               ⇒ ★미러링 코드가 그 프로세스 메모리에 존재하지 않았다★

    Python 은 import 시점에 모듈을 메모리에 적재한다(L-404). 따라서 ★.py 를 고쳐도
    이미 떠 있는 프로세스는 영원히 구 코드로 동작한다★ — 재시작 전까지.

    ⇒ ★"파일을 고쳤다"와 "그 코드가 실행된다"는 다른 명제다.★
      본 사이클 이전의 검증은 전부 ★신규 에이전트 = 신규 서버★ 에서 이뤄져
      항상 신 코드만 관측했다. 구 서버는 단 한 번도 검사되지 않았다.
      ⇒ 검증 수단이 문제를 구조적으로 은폐했다.

    ── 왜 hook(1순위)이 아니라 여기(2순위)인가 ──────────────────────────────
    hook 은 도구 호출의 인자·결과만 본다. "서버 프로세스가 구 코드인가"는 인자에도
    결과에도 나타나지 않는다 — 구 코드는 애초에 bases_written 필드를 만들지 않으므로
    ★부재로만 드러나고, 부재는 정상 케이스와 구별되지 않는다★.
    ⇒ hook 이 관측할 신호 자체가 없어 물리 차단이 불가능하다.
    ⇒ 서버가 ★자기 자신★ 을 진단하는 2순위 조치로 강제한다.

    ── ⚠️ 이 함수의 한계 (반드시 알 것) ───────────────────────────────────
    ★이 코드 역시 구 서버에는 적재되지 않는다.★ 즉 본 함수는 ★다음에 기동하는
    서버부터★ 유효하다. 이미 구 코드로 떠 있는 프로세스는 이 경고를 낼 수 없다.
    ⇒ 그래서 odev/SKILL.md 의 "서버 재적재 확인 게이트"(3순위)를 ★병행★ 해야 한다.
      한쪽만으로는 닫히지 않는다.

    판정: 이 모듈 파일의 mtime > 현재 프로세스 시작 시각 이면 구 코드다.
    반환: 구 코드면 경고 문자열, 정상이면 "" (빈 문자열).
    실패: 어떤 예외든 "" 반환 — ★fail-soft★. 진단 실패가 파일 작업을 막으면 안 된다.
    """
    try:
        src_mtime = os.path.getmtime(os.path.abspath(__file__))
    except Exception:
        return ""

    # 프로세스 시작 시각 = 부팅 시각 + /proc/self/stat 의 starttime(clock ticks).
    # psutil 의존을 피하려고 /proc 을 직접 읽는다(리눅스/WSL 전제).
    try:
        with open("/proc/uptime", "r") as f:
            uptime = float(f.read().split()[0])
        boot_time = _time.time() - uptime

        with open("/proc/self/stat", "rb") as f:
            stat_raw = f.read().decode("utf-8", "replace")
        # comm 필드에 공백/괄호가 있을 수 있으므로 마지막 ')' 뒤부터 자른다.
        after = stat_raw[stat_raw.rfind(")") + 2:].split()
        starttime_ticks = float(after[19])          # 22번째 필드(1-based) = starttime
        hz = os.sysconf("SC_CLK_TCK") or 100
        proc_start = boot_time + (starttime_ticks / hz)
    except Exception:
        return ""

    if src_mtime <= proc_start:
        return ""

    return (
        "oio 서버가 ★구 코드★ 로 동작 중입니다 — session_mirror.py 가 이 프로세스 "
        f"기동 이후에 수정됐습니다 (모듈 수정 {_time.strftime('%Y-%m-%d %H:%M:%S', _time.localtime(src_mtime))} "
        f"> 프로세스 기동 {_time.strftime('%Y-%m-%d %H:%M:%S', _time.localtime(proc_start))}). "
        "Python 은 import 시점에 모듈을 적재하므로 이 프로세스에는 수정이 반영되지 않았습니다(L-404). "
        "session-env 미러링이 동작하지 않아 CFG/HOME 경로가 갈릴 수 있습니다. "
        "★서버 재시작 전까지 유효하며, 재시작 판단은 사용자/메인이 합니다 — "
        "타 세션 소유 서버를 kill 하면 그 세션이 정지합니다(세션 격리 §(b) fail-closed).★"
    )


def _atomic_copy(src: str, dst: str) -> None:
    """원자적 복사 (tmp → os.replace). 부분 기록 상태가 보이지 않게 한다."""
    dstdir = os.path.dirname(dst)
    os.makedirs(dstdir, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=dstdir, prefix=".mirror.tmp.")
    os.close(fd)
    try:
        shutil.copyfile(src, tmp)
        os.replace(tmp, dst)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def mirror_write(path: str) -> list:
    """원본 쓰기 성공 후, 같은 내용을 다른 base 에 복사한다.

    반환: 실패한 (경로, 사유) 문자열 리스트. 성공 시 빈 리스트.

    §실패 정책 — ★fail-loud★:
      session_ops.py 의 `_mirror_write()` 는 fail-soft(예외 무시)다. 본 모듈은
      다르게 간다. 이유는 ★조용한 실패가 정확히 사이클40 의 사고 형태★ 이기
      때문이다 — 한쪽에만 기록되고 아무도 몰랐고, 5시간 뒤 종료 시점에야
      드러났다. 미러가 실패하면 그 순간 비대칭이 생긴 것이므로 호출자가
      결과 dict 에 실어 즉시 알려야 한다.
      단 ★원본 작업을 실패로 뒤바꾸지는 않는다★ — 원본은 이미 성공했고,
      그것을 되돌리면 더 큰 사고가 된다. 경고로 알리고 진행한다.
    """
    failures = []
    for dst in mirror_targets(path):
        try:
            if os.path.exists(path):
                _atomic_copy(path, dst)
        except Exception as e:
            failures.append(f"{dst}: {e}")
    return failures


def mirror_delete(path: str) -> list:
    """원본 삭제 성공 후, 다른 base 의 동일 파일도 삭제한다.

    삭제를 미러하지 않으면 ★지운 파일이 반대편에 되살아나 있는★ 상태가 된다.
    이것은 갈림 중에서도 특히 위험하다 — 이행 완료된 goal.json 이 반대편에
    남아 다음 사이클의 시드로 재사용될 수 있기 때문이다.
    반환 규약은 mirror_write 와 동일하다.
    """
    failures = []
    for dst in mirror_targets(path):
        try:
            if os.path.exists(dst):
                os.remove(dst)
        except Exception as e:
            failures.append(f"{dst}: {e}")
    return failures


def mirror_dir_delete(path: str, recursive: bool = False) -> list:
    """원본 디렉토리 삭제 성공 후, 다른 base 의 동일 디렉토리도 삭제한다.

    mirror_delete(파일)와 동일 규약을 디렉토리로 확장한 것뿐이다 — 신규 설계 없음.
    mirror_targets() 가 이미 강제하는 안전판(tail 빈 문자열 제외, `..` 탈출 거부,
    36자 UUID 검증)을 그대로 물려받는다.

    · dst 가 존재하지 않으면 스킵(에러 아님) — 반대편에 애초에 없을 수 있다.
    · dst 가 디렉토리가 아니면(타입 불일치) 스킵 — 강제 삭제하지 않는다.
    · recursive=False → os.rmdir(빈 디렉토리만, 원본과 동일 의미론).
    · recursive=True  → shutil.rmtree(원본이 이미 recursive 삭제에 성공한 뒤에만
      apply_dir 이 호출하므로, 여기서는 그 전제를 그대로 따른다).
    반환 규약은 mirror_write/mirror_delete 와 동일: 실패한 "dst: 사유" 문자열 리스트.
    """
    failures = []
    for dst in mirror_targets(path):
        try:
            if not os.path.exists(dst):
                continue
            if not os.path.isdir(dst):
                continue                            # 타입 불일치 — 강제 삭제 금지
            if recursive:
                shutil.rmtree(dst)
            else:
                os.rmdir(dst)
        except Exception as e:
            failures.append(f"{dst}: {e}")
    return failures


def apply(result: dict, path: str, deleted: bool = False) -> dict:
    """도구 결과 dict 에 미러링을 적용하고 경고를 병합해 돌려준다.

    · result 가 성공(success=True)일 때만 미러한다. 실패한 쓰기를 미러하면
      잘못된 상태를 전파하게 된다.
    · 미러 실패는 result["mirror_warning"] 으로 노출한다(fail-loud).
    · 미러가 수행된 경우 result["bases_written"] 을 채운다 —
      session_state 의 동명 필드와 의미를 맞춰 호출자가 동일하게 읽게 한다.
    """
    try:
        if not isinstance(result, dict) or not result.get("success"):
            return result

        # 구 코드 자가 진단 (사이클43) — ★미러 대상 유무보다 먼저★ 판정한다.
        # 이유: 구 코드로 동작 중이면 애초에 이 함수가 호출되지 않으므로 여기 도달했다는
        #       것 자체가 신 코드라는 뜻이지만, ★모듈이 다시 수정된 경우★(적재 이후 재수정)
        #       는 여기서만 잡을 수 있다. 대상 0개여도 경고는 실어 보낸다.
        _stale = stale_module_warning()
        if _stale:
            result["stale_module_warning"] = _stale

        targets = mirror_targets(path)
        if not targets:
            return result
        failures = mirror_delete(path) if deleted else mirror_write(path)
        result["bases_written"] = len(targets) + 1
        if failures:
            result["mirror_warning"] = (
                "session-env 미러링 일부 실패 — 두 경로가 갈렸을 수 있습니다: "
                + "; ".join(failures)
            )
    except Exception as e:
        # 미러링 자체의 버그가 파일 작업을 죽이면 안 된다(최종 안전망).
        try:
            result["mirror_warning"] = f"session-env 미러링 오류: {e}"
        except Exception:
            pass
    return result


def apply_dir(result: dict, path: str, recursive: bool = False, deleted: bool = True) -> dict:
    """dir_delete 전용 진입점 — apply() 의 디렉토리 버전 (A1, 사이클49).

    apply() 는 파일 전용 로직(mirror_write/mirror_delete)을 쓰므로 그대로 두고,
    디렉토리 삭제는 이 함수로 분리한다(Surgical — 기존 파일 경로 로직 불변).

    · result 가 성공(success=True)일 때만 미러한다 — 원본 삭제가 실패했으면
      (예: DIR_NOT_EMPTY) 미러를 시도하지 않고 원본 결과를 그대로 반환한다.
    · 미러 실패는 result["mirror_warning"] 으로 노출한다(fail-loud, apply()와 동일).
      단 미러 실패가 원본 삭제 결과(success)를 뒤집지는 않는다(fail-soft 원칙).
    · 미러가 수행된 경우 result["bases_written"] 을 채운다 — file_delete 와
      동일 형식이어야 이 필드 유무로 미러링 여부를 판별할 수 있다(L-473 개선안).
    """
    try:
        if not isinstance(result, dict) or not result.get("success"):
            return result

        # 구 코드 자가 진단 (사이클43) — apply()와 동일 이유로 여기도 붙인다.
        _stale = stale_module_warning()
        if _stale:
            result["stale_module_warning"] = _stale

        targets = mirror_targets(path)
        if not targets:
            return result
        failures = mirror_dir_delete(path, recursive) if deleted else []
        result["bases_written"] = len(targets) + 1
        if failures:
            result["mirror_warning"] = (
                "session-env 미러링 일부 실패 — 두 경로가 갈렸을 수 있습니다: "
                + "; ".join(failures)
            )
    except Exception as e:
        # 미러링 자체의 버그가 디렉토리 작업을 죽이면 안 된다(최종 안전망).
        try:
            result["mirror_warning"] = f"session-env 미러링 오류: {e}"
        except Exception:
            pass
    return result
