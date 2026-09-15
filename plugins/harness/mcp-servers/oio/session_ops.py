"""
세션 상태 파일 관리. 파이프라인 UUID 기반 세션 디렉토리 파일 원자적 쓰기.
상태 파일: state, reroute_count, classification 등.
"""
import os
import fcntl
import tempfile

SESSION_ENV_BASE = os.path.join(
    os.environ.get('CLAUDE_CONFIG_DIR') or os.path.expanduser('~/.claude'),
    'session-env'
)

# 홈 기준 base. CLAUDE_CONFIG_DIR가 설정된 격리 환경(/tmp/cc-*)에서는
# SESSION_ENV_BASE와 서로 다른 경로가 된다.
SESSION_ENV_HOME_BASE = os.path.join(os.path.expanduser('~/.claude'), 'session-env')


def _split_key_dir(session_dir: str, key: str) -> tuple[str, str]:
    """key에 '/'가 포함된 경우 하위 디렉토리를 보장 생성하고
    (실제 파일이 위치할 디렉토리, basename) 을 반환한다.

    예: key="evidence/ok_started" → session_dir/evidence 생성 후
        ("session_dir/evidence", "ok_started") 반환.
    key에 '/'가 없으면 (session_dir, key) 그대로 반환.
    """
    if "/" in key:
        sub_dir, base = key.rsplit("/", 1)
        target_dir = os.path.join(session_dir, sub_dir)
        os.makedirs(target_dir, exist_ok=True)
        return target_dir, base
    return session_dir, key


def _mirror_state_bases(uuid: str) -> list[str]:
    """세션 상태 파일을 기록해야 하는 세션 디렉토리 목록을 반환한다.

    배경: 읽는 쪽의 base 해석이 갈린다.
      ● oio / hook / 스킬: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env
      ● 일부 호출자(state_write에 전체 경로를 넘기는 쪽): $HOME/.claude/session-env 하드코딩
    CLAUDE_CONFIG_DIR가 /tmp/cc-* 로 설정된 격리 세션에서는 두 경로가 갈라져,
    한쪽에만 기록되면 다른 쪽 독자가 상태 파일을 못 찾는다. 실제로 statusline이
    '?'로 표시되고 stale 판정이 어긋나는 사고가 발생했다. 쓰기는 성공하므로
    호출자는 실패를 알 수 없다.

    조치: 두 base가 다르면 양쪽 모두에 기록해 어느 독자도 놓치지 않게 한다.

    사이클27 확대: 종전에는 key=="state" 일 때만 미러링했다. 그 결과 conv_id,
    classification, entry_tier, status, team_name, reroute_count 등 나머지 전 키가
    한쪽 base 에만 기록됐다. 특히 status 유실은 사용자의 ABORT/PAUSE 제동이 무시되는
    것을 뜻하고, team_name 유실은 세션 격리 불변식 §(b) 소유권 증명을 깨뜨린다.
    이제 전 키를 미러링한다.

    사이클47 경계 등가화: 진입부에 `security.validate_session_mirror_path()` 게이트를
    둔다. 종전에는 uuid 검증이 ★전혀 없어★ 36자 비-hex·`..` 탈출·대문자 UUID 가
    그대로 두 base 에 기록됐다. 셸판 `hooks/lib/session_mirror.sh` 는 이미 4종을
    방어하고 있었으므로 그 격차를 없앤다.

    ★fail-soft 유지★: 거부 시에도 리스트 [0](원본 base)은 그대로 반환한다.
      잘라내는 것은 `[1:]` 로 소비되는 ★미러 대상뿐★ 이며 원 쓰기는 영향이 0 이다.
      호출부 12곳이 전부 `[1:]` 또는 `len()` 으로만 쓰므로 시그니처 변경도 없다.
      ⇒ `bases_written` 이 2→1 로 떨어져 ★거부가 관측 가능★ 해진다.
    """
    try:
        from security import validate_session_mirror_path as _vsmp
    except Exception:                                # pragma: no cover
        _vsmp = None
    if _vsmp is not None and not _vsmp(uuid):
        return [os.path.join(SESSION_ENV_BASE, uuid)]

    bases = [os.path.join(SESSION_ENV_BASE, uuid)]
    if os.path.abspath(SESSION_ENV_BASE) != os.path.abspath(SESSION_ENV_HOME_BASE):
        bases.append(os.path.join(SESSION_ENV_HOME_BASE, uuid))
    return bases


def _mirror_write(session_dir: str, key: str, text: str) -> None:
    """보조 base에 원자적으로 기록한다. 실패는 무시한다 (fail-soft).

    주 base 기록이 이미 성공한 뒤 호출되므로, 미러 실패가 전체 결과를
    실패로 바꾸면 안 된다. 미러는 어디까지나 독자 호환을 위한 보강이다.
    """
    try:
        os.makedirs(session_dir, exist_ok=True)
        _key_dir, _key_base = _split_key_dir(session_dir, key)
        fd, tmp_path = tempfile.mkstemp(dir=_key_dir, prefix=f".{_key_base}.tmp.")
        try:
            with os.fdopen(fd, "w") as f:
                f.write(text)
            os.replace(tmp_path, os.path.join(_key_dir, _key_base))
        except Exception:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass
    except Exception:
        pass

# ── Fix 12: state 전이 유효성 검증 ─────────────────────────────────────────
# ok 파이프라인 허용 전이 맵 (force=False 일 때만 적용)
# 역행/복구 경로(TEST→DEV, DEV→PLAN 등)도 포함.
# 어떤 활성 상태에서든 EARLY_TERM 은 항상 허용.
_ALLOWED_TRANSITIONS: dict[str, set[str]] = {
    # L-431: stage 축에서 OK가 제거되고 진입은 PLAN + classification=OK로 표현된다.
    # value="OK" 호출은 아래에서 PLAN으로 선변환되므로 허용 목록도 PLAN이어야 한다.
    # (OK를 남겨둔 채 PLAN을 빠뜨려 IDLE→PLAN이 전면 거부되던 결함을 수정.)
    "IDLE":       {"PLAN", "OK"},
    "OK":         {"OK", "PLAN", "DEV", "IDLE"},  # OK 자기전이: phase_guard(IDLE→OK) 후 ok SKILL이 MCP로 재설정, DEV = o1 단축, IDLE = abort
    "PLAN":       {"PLAN", "DEV", "FINISH"},       # PLAN 자기전이: oplan 재spawn (역행 복귀 후), FINISH = L-216 조기종료·계획 단독(/oplan 등) 경로
    "DEV":        {"DEV", "TEST", "PLAN", "FINISH"},  # DEV 자기전이: Auto-Loop 다음 batch, PLAN = odev→oplan 역행, FINISH = o1(oplan/otest/odone 미경유) 및 L-216 조기종료 경로에서 ofinish Step 0.5 직행
    "TEST":       {"TEST", "DONE", "DEV", "PLAN", "FINISH"}, # TEST 자기전이: otest 재spawn, DEV/PLAN = 재시도 역행, FINISH = o2 경로(obr 후 TEST 상태에서 odone 없이 ofinish 직행)
    # PLAN 추가 배경(신규): auto(oto)/RALPH(oralph) 세션이 DONE 진입 시점에 goal.json/
    # oralph_active 잔여 acceptance 항목을 발견하면, 계획을 보완하기 위해 PLAN 재진입이
    # 필요하다. 이 전이는 done_gate hook + otest_verify 절차가 실패 항목이 있을 때만
    # 트리거하며 무조건 허용이 아니다 — 여기서는 "상태 축 전이 자체가 가능한가"만 연다.
    "DONE":       {"DONE", "FINISH", "TEST", "DEV", "PLAN"},  # DONE 자기전이: odone 재spawn, TEST = odone→otest 역행, DEV = Auto-Loop 다음 batch, PLAN = auto/RALPH 잔여 작업 보완 재계획
    "FINISH":     {"OK", "IDLE", "DEV", "PLAN"},   # OK = 새 /ok 호출(phase_guard), DEV/PLAN = ofinish Step 3 백업 Auto-Loop
    "EARLY_TERM": {"IDLE", "FINISH"},               # 조기종료 후 IDLE 복귀 또는 경량 ofinish → FINISH 경유
    "ERROR":      {"IDLE"},
}


def _validate_state_transition(current: str, next_state: str) -> tuple[bool, str]:
    """
    current → next_state 전이가 허용되는지 검증.

    반환: (ok: bool, reason: str)
    - EARLY_TERM 은 어떤 활성 상태에서든 항상 허용.
    - force=True 호출 경로는 이 함수를 건너뜀.
    """
    # EARLY_TERM 은 항상 허용 (조기 강제 종료 경로)
    if next_state == "EARLY_TERM":
        return True, ""

    allowed = _ALLOWED_TRANSITIONS.get(current)
    if allowed is None:
        return False, f"알 수 없는 현재 상태: {current!r}"
    if next_state not in allowed:
        return False, (
            f"허용되지 않은 전이: {current} → {next_state} "
            f"(허용 목록: {sorted(allowed)})"
        )
    return True, ""


def session_state(uuid: str, key: str, value: str, append: bool = False, force: bool = False) -> dict:
    """
    세션 상태 파일 쓰기.

    uuid:   파이프라인 UUID (36자 full UUID)
    key:    파일명 (state / reroute_count / classification / ...)
    value:  쓸 값.
            - "increment" 특수값: flock 기반 원자적 +1 처리 (reroute_count 전용)
            - state 키는 "{value} {uuid}" 형식으로 자동 변환
    append: True = 줄 추가, False = 덮어쓰기 (원자적 tmp→replace)
    force:  True = 상태 전이 유효성 검증 + CAS 건너뜀 (oresume/oclean 긴급 리셋 전용)
            False(기본) = _ALLOWED_TRANSITIONS 검증 + flock CAS
    """
    if not uuid or not key:
        return {"success": False, "error": "MISSING_PARAM", "message": "uuid와 key는 필수입니다"}

    session_dir = os.path.join(SESSION_ENV_BASE, uuid)
    os.makedirs(session_dir, exist_ok=True)
    _key_dir, _key_base = _split_key_dir(session_dir, key)
    file_path = os.path.join(_key_dir, _key_base)

    try:
        # ── increment 특수값: flock 기반 원자적 +1 ──────────────────
        if value == "increment":
            lock_path = file_path + ".lock"
            with open(lock_path, "w") as lock_f:
                fcntl.flock(lock_f, fcntl.LOCK_EX)
                try:
                    current = 0
                    if os.path.exists(file_path):
                        with open(file_path, "r") as f:
                            try:
                                current = int(f.read().strip())
                            except ValueError:
                                current = 0
                    new_val = current + 1
                    # 원자적 쓰기
                    fd, tmp_path = tempfile.mkstemp(
                        dir=_key_dir, prefix=f".{_key_base}.tmp."
                    )
                    try:
                        with os.fdopen(fd, "w") as f:
                            f.write(str(new_val) + "\n")
                        os.replace(tmp_path, file_path)
                    except Exception:
                        try:
                            os.unlink(tmp_path)
                        except OSError:
                            pass
                        raise
                    # 보조 base 미러 기록 (reroute_count 등 — 종전 완전 누락분).
                    # 증분 계산은 주 base 값을 정본으로 삼고 결과값만 미러에 복사한다.
                    for _mdir in _mirror_state_bases(uuid)[1:]:
                        _mirror_write(_mdir, key, str(new_val) + "\n")
                    return {
                        "success": True,
                        "key": key,
                        "value": str(new_val),
                        "mode": "increment",
                        "bases_written": len(_mirror_state_bases(uuid)),
                    }
                finally:
                    fcntl.flock(lock_f, fcntl.LOCK_UN)

        # ── state 키: CAS + 전이 유효성 검증 (Fix 12) ──────────────
        if key == "state" and not force:
            # ── L-431 Phase B 자동 마이그레이션 ──────────────────────
            # value="OK"는 stage 8축에서 제거됨. PLAN+classification=OK로 자동 변환.
            # state_machine.sh _smach_migrate_ok_to_plan과 동등 정책.
            ok_auto_migrated = False
            if value == "OK":
                value = "PLAN"
                ok_auto_migrated = True
                # classification 파일에 "OK" 기록 (best-effort, lock 밖 실행)
                try:
                    cls_path = os.path.join(session_dir, "classification")
                    fd_c, tmp_c = tempfile.mkstemp(
                        dir=session_dir, prefix=".classification.tmp."
                    )
                    try:
                        with os.fdopen(fd_c, "w") as fc:
                            fc.write("OK\n")
                        os.replace(tmp_c, cls_path)
                    except Exception:
                        try:
                            os.unlink(tmp_c)
                        except OSError:
                            pass
                        raise
                except Exception:
                    pass  # classification 기록 실패는 fail-soft

            lock_path = file_path + ".lock"
            with open(lock_path, "w") as lock_f:
                fcntl.flock(lock_f, fcntl.LOCK_EX)
                try:
                    # 현재 상태 읽기 (lock 보호 하에서)
                    current_raw = ""
                    if os.path.exists(file_path):
                        with open(file_path, "r") as f:
                            current_raw = f.read().strip()
                    current_state = current_raw.split()[0] if current_raw else "IDLE"

                    # 잔존 OK 자동 마이그레이션 (현재 상태가 OK인 경우 PLAN으로 간주)
                    if current_state == "OK":
                        current_state = "PLAN"

                    # 전이 유효성 검증
                    ok, reason = _validate_state_transition(current_state, value)
                    if not ok:
                        return {
                            "success": False,
                            "error": "INVALID_TRANSITION",
                            "message": reason,
                            "current_state": current_state,
                            "requested": value,
                        }

                    # 원자적 쓰기: tmp → os.replace (lock 보호 하에서)
                    effective_value = f"{value} {uuid}"
                    fd, tmp_path = tempfile.mkstemp(
                        dir=_key_dir, prefix=f".{_key_base}.tmp."
                    )
                    try:
                        with os.fdopen(fd, "w") as f:
                            f.write(effective_value + "\n")
                        os.replace(tmp_path, file_path)
                    except Exception:
                        try:
                            os.unlink(tmp_path)
                        except OSError:
                            pass
                        raise
                    # 보조 base 미러 기록 (base 분기 환경에서 독자 호환)
                    for _mdir in _mirror_state_bases(uuid)[1:]:
                        _mirror_write(_mdir, key, effective_value + "\n")
                        if ok_auto_migrated:
                            _mirror_write(_mdir, "classification", "OK\n")

                    result = {
                        "success": True,
                        "key": key,
                        "value": effective_value,
                        "transition": f"{current_state} → {value}",
                        "bases_written": len(_mirror_state_bases(uuid)),
                    }
                    if ok_auto_migrated:
                        result["migrated"] = "OK→PLAN+classification=OK (L-431)"
                    return result
                finally:
                    fcntl.flock(lock_f, fcntl.LOCK_UN)

        # ── state 키 force 모드 또는 기타 키: "{value} {uuid}" 형식 자동 포함 ──
        effective_value = f"{value} {uuid}" if key == "state" else value

        # ── append 모드 ─────────────────────────────────────────────
        if append:
            # NTFS 경로(/mnt/c/ 등): tmp→replace 방식으로 원자성 보장
            # EXT4 경로(~/.claude/ 등): flock 기반 직접 append 유지
            if file_path.startswith("/mnt/") and len(file_path) > 6 and file_path[5].isalpha() and (len(file_path) == 6 or file_path[6] == "/"):
                # NTFS: 기존 내용 읽어서 tmp→replace
                existing = ""
                if os.path.exists(file_path):
                    with open(file_path, "r", encoding="utf-8", errors="replace") as f:
                        existing = f.read()
                fd, tmp_path = tempfile.mkstemp(dir=_key_dir, prefix=f".{_key_base}.tmp.")
                try:
                    with os.fdopen(fd, "w") as f:
                        f.write(existing + effective_value + "\n")
                    os.replace(tmp_path, file_path)
                except Exception:
                    try:
                        os.unlink(tmp_path)
                    except OSError:
                        pass
                    raise
            else:
                # EXT4: flock 기반 append
                lock_path = file_path + ".lock"
                with open(lock_path, "w") as lock_f:
                    fcntl.flock(lock_f, fcntl.LOCK_EX)
                    try:
                        with open(file_path, "a") as f:
                            f.write(effective_value + "\n")
                    finally:
                        fcntl.flock(lock_f, fcntl.LOCK_UN)
            # 보조 base 미러 기록 (종전 완전 누락분).
            # append 는 누적 파일이므로 추가된 한 줄이 아니라 주 base 의 전체 내용을
            # 복사해야 한다. 한 줄만 쓰면 미러가 마지막 줄만 갖게 되어 어긋난다.
            _mirror_dirs = _mirror_state_bases(uuid)[1:]
            if _mirror_dirs:
                try:
                    with open(file_path, "r", encoding="utf-8", errors="replace") as f:
                        _full = f.read()
                    for _mdir in _mirror_dirs:
                        _mirror_write(_mdir, key, _full)
                except Exception:
                    pass  # 미러 실패는 fail-soft (주 base 기록은 이미 성공)
            return {
                "success": True,
                "key": key,
                "value": effective_value,
                "mode": "append",
                "bases_written": len(_mirror_state_bases(uuid)),
            }

        # ── 원자적 쓰기: tmp → os.replace ───────────────────────────
        fd, tmp_path = tempfile.mkstemp(dir=_key_dir, prefix=f".{_key_base}.tmp.")
        try:
            with os.fdopen(fd, "w") as f:
                f.write(effective_value + "\n")
            os.replace(tmp_path, file_path)
        except Exception:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass
            raise

        # 전 키를 보조 base에도 미러 기록한다 (state force 모드 포함).
        # 종전 key=="state" 가드를 제거했다 — conv_id/classification/entry_tier/
        # status/team_name 등이 한쪽 base 에만 기록되어 읽는 쪽이 옛 값을 보던
        # 결함을 없앤다.
        for _mdir in _mirror_state_bases(uuid)[1:]:
            _mirror_write(_mdir, key, effective_value + "\n")

        return {
            "success": True,
            "key": key,
            "value": effective_value,
            "bases_written": len(_mirror_state_bases(uuid)),
        }

    except Exception as e:
        return {"success": False, "error": "SESSION_STATE_ERROR", "message": str(e)}
