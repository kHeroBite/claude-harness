#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Claude Code 커스텀 Statusline v4
표시: 프로젝트명 | Git | 모델+버전 | 파이프라인 | 세션 | 주간 | 컨텍스트 | 토큰델타 | 경과시간 | 소진속도 | GPT비용 | 계정
"""
import sys, json, io, os, re, time, subprocess

def _restore_parent_env():
    """팀에이전트 statusline 자식 프로세스에 CLAUDE_CONFIG_DIR/CLAUDE_PROFILE_NAME 등이
    누락되는 경우, /proc/$PPID/environ에서 부모 프로세스의 값을 복원한다.
    이미 현재 프로세스에 값이 있으면 손대지 않는다(우선순위 보존).
    실패해도 statusline은 절대 깨지지 않도록 try/except로 감쌈."""
    try:
        keys = ('CLAUDE_CONFIG_DIR', 'CLAUDE_PROFILE_NAME', 'CLAUDE_AS_UUID')
        if all(os.environ.get(k) for k in keys):
            return
        with open(f'/proc/{os.getppid()}/environ', 'rb') as f:
            raw = f.read()
        for entry in raw.split(b'\x00'):
            if not entry or b'=' not in entry:
                continue
            k, _, v = entry.partition(b'=')
            try:
                ks = k.decode('utf-8', errors='replace')
                vs = v.decode('utf-8', errors='replace')
            except Exception:
                continue
            if ks in keys and not os.environ.get(ks) and vs:
                os.environ[ks] = vs
    except Exception:
        pass  # statusline 절대 깨지면 안 됨

_restore_parent_env()

# === 진단 로그 (임시) — cas/cmon vs cc 진입 시 statusline.py 호출 추적 ===
try:
    import time as _time
    with open("/tmp/statusline_call.log", "a") as _f:
        _cwd = os.getcwd()
        _cd = os.environ.get("CLAUDE_CONFIG_DIR", "")
        _cf = os.environ.get("CLAUDE_PROFILE_NAME", "")
        _ppid = os.getppid()
        _f.write(f"[{_time.strftime('%H:%M:%S')}] pid={os.getpid()} ppid={_ppid} cwd={_cwd} cfg={_cd} prof={_cf}\n")
except Exception:
    pass


def claude_config_dir():
    """CLAUDE_CONFIG_DIR 환경변수 우선, 없으면 ~/.claude (multi-account 격리용)."""
    return os.environ.get('CLAUDE_CONFIG_DIR') or os.path.expanduser('~/.claude')

# UTF-8 입출력
if hasattr(sys.stdin, 'buffer'):
    sys.stdin = io.TextIOWrapper(sys.stdin.buffer, encoding='utf-8')
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')

# ── 색상 상수 ─────────────────────────────────────────

C_RESET = "\033[0m"
C_DIM   = "\033[90m"      # 어두운 회색
C_WHITE = "\033[97m"       # 밝은 흰색
C_CYAN  = "\033[96m"       # 시안
C_GREEN = "\033[38;2;0;255;127m"
C_YELLOW = "\033[93m"
C_ORANGE = "\033[38;2;255;165;0m"
C_RED   = "\033[38;2;255;105;180m"  # 핑크 (구 빨강 대체)
C_PINK  = "\033[38;2;255;105;180m"
C_BLUE  = "\033[38;2;100;149;237m"
C_GOLD  = "\033[38;2;255;215;0m"
C_PURPLE = "\033[38;2;138;43;226m"
C_SKY   = "\033[38;2;0;191;255m"



# ── 유틸 ──────────────────────────────────────────────

STATE_FILE = os.path.join(claude_config_dir(), '.statusline_state.json')
USAGE_CACHE_FILE = os.path.join(claude_config_dir(), '.usage_cache.json')
USAGE_CACHE_TTL = 300  # 5분

def profiles_root():
    """프로필 루트. CLAUDE_PROFILES_ROOT 환경변수 우선, 기본 ~/.claude-profiles."""
    return os.environ.get('CLAUDE_PROFILES_ROOT') or os.path.expanduser('~/.claude-profiles')


def load_state():
    try:
        with open(STATE_FILE, 'r') as f:
            return json.load(f)
    except:
        return {}

def save_state(state):
    try:
        with open(STATE_FILE, 'w') as f:
            json.dump(state, f)
    except:
        pass

def save_usage_cache(rate_limits, model_name, account_email):
    """5분 TTL 사용량 캐시. cc/ccc/cas monitor가 읽어서 즉시 표시."""
    try:
        if not rate_limits:
            return
        # mtime 기반 5분 TTL skip (keystroke 마다 IO 방지)
        # 단, 캐시 계정과 현재 계정이 둘 다 있고 서로 다르면(/login 전환) TTL 을 무시하고 즉시 다시 쓴다
        try:
            if time.time() - os.path.getmtime(USAGE_CACHE_FILE) < USAGE_CACHE_TTL:
                try:
                    with open(USAGE_CACHE_FILE, 'r') as f:
                        cached_email = (json.load(f).get('account_email') or '').strip().lower()
                except Exception:
                    cached_email = ''
                current_email = (account_email or '').strip().lower()
                if not (cached_email and current_email and cached_email != current_email):
                    return
        except FileNotFoundError:
            pass
        payload = {
            "timestamp": int(time.time()),
            "rate_limits": rate_limits,
            "model_name": model_name or "",
            "account_email": account_email or "",
        }
        tmp = USAGE_CACHE_FILE + ".tmp"
        with open(tmp, 'w') as f:
            json.dump(payload, f)
        os.replace(tmp, USAGE_CACHE_FILE)
        # PROFILE_DIR 동시 저장 (활성 세션 중에도 cas monitor에서 가시화)
        try:
            profile_name = os.environ.get('CLAUDE_PROFILE_NAME', '')
            if profile_name:
                profile_dir = os.path.join(profiles_root(), profile_name)
                # 세션 중 다른 계정으로 /login 하면 시작 프로필의 사용량 캐시를 덮어쓰지 않는다
                profile_email = read_profile_email(profile_dir).lower()
                session_email = (account_email or '').strip().lower()
                account_differs = bool(profile_email and session_email and profile_email != session_email)
                if os.path.isdir(profile_dir) and not account_differs:
                    profile_cache = os.path.join(profile_dir, '.usage_cache.json')
                    tmp_profile = profile_cache + '.tmp'
                    with open(tmp_profile, 'w') as f:
                        json.dump(payload, f)
                    os.chmod(tmp_profile, 0o600)
                    os.replace(tmp_profile, profile_cache)
        except Exception:
            pass  # silent — statusline 절대 깨지면 안 됨
    except Exception:
        pass  # statusline 표시는 절대 깨지지 않음

def fmt_remaining(resets_at, thresholds=None):
    """resets_at(unix epoch) → 3日13時 형식. thresholds: (h1,h2,h3) 색상 경계."""
    if not resets_at:
        return None
    diff = resets_at - time.time()
    if diff <= 0:
        return f"{C_RED}만료{C_RESET}"
    h = int(diff // 3600)
    m = int((diff % 3600) // 60)
    if h >= 24:
        d, rh = h // 24, h % 24
        s = f"{d}日{rh}時"
    else:
        s = f"{h}時{m}分"
    # 색상: thresholds = (녹/회색, 주황, 빨강) 시간 경계
    if thresholds:
        t1, t2, t3 = thresholds  # 예: (3,2,1) 또는 (48,24,12)
        if h >= t1:
            c = C_DIM
        elif h >= t2:
            c = C_YELLOW
        elif h >= t3:
            c = C_ORANGE
        else:
            c = C_PINK
    else:
        c = C_DIM
    return f"{c}{s}{C_RESET}"

def tier_color(remaining):
    """잔량 기반 4단계 색상: 회색→노랑→주황→핑크."""
    if remaining >= 70:
        return C_DIM
    elif remaining >= 50:
        return C_YELLOW
    elif remaining >= 30:
        return C_ORANGE
    else:
        return C_PINK

def dot_bar(remaining_pct):
    """도트 바: 채움(•)은 4단계 고유색, 빈(◦)은 회색."""
    if remaining_pct is None:
        return f"{C_GREEN}••••{C_RESET}"
    p = float(remaining_pct)
    if p >= 70:
        return f"{C_GREEN}••••{C_RESET}"
    elif p >= 50:
        return f"{C_YELLOW}•••{C_DIM}◦{C_RESET}"
    elif p >= 30:
        return f"{C_ORANGE}••{C_DIM}◦◦{C_RESET}"
    else:
        return f"{C_PINK}•{C_DIM}◦◦◦{C_RESET}"

def line_bar(remaining_pct):
    """라인 바: 채움(━)은 단계 색상, 빈(╌)은 회색. 10%↓은 전부 핑크. 10칸."""
    if remaining_pct is None:
        return f"{C_GREEN}{'━' * 10}{C_RESET}"
    p = float(remaining_pct)
    cc = tier_color(p)
    filled = max(0, min(10, int(p / 10)))
    empty = 10 - filled
    if p < 10:
        return f"{C_PINK}━{C_DIM}{'╌' * 9}{C_RESET}"
    return f"{cc}{'━' * filled}{C_DIM}{'╌' * empty}{C_RESET}"

def fmt_duration(ms):
    """밀리초 → 경과 시간 표시."""
    if not ms:
        return None
    s = ms // 1000
    if s < 60:
        return f"{s}초"
    m = s // 60
    if m < 60:
        return f"{m}분"
    h = m // 60
    rm = m % 60
    if h == 0:
        return f"{rm}분"
    elif rm == 0:
        return f"{h}시간"
    return f"{h}시{rm}분"

def fmt_tokens(n):
    """토큰 수 축약 표시."""
    if n is None:
        return "?"
    if n >= 1000000:
        return f"{n/1000000:.1f}M"
    elif n >= 1000:
        return f"{n/1000:.1f}k"
    return str(n)

# ── Git 정보 ──────────────────────────────────────────

def get_git_info(project_dir):
    """Git 브랜치 + dirty 상태."""
    if not project_dir:
        return None, False
    try:
        result = subprocess.run(
            ['git', 'branch', '--show-current'],
            capture_output=True, text=True, timeout=2,
            cwd=project_dir, stdin=subprocess.DEVNULL
        )
        branch = result.stdout.strip() or 'detached'
        result2 = subprocess.run(
            ['git', 'status', '--porcelain', '-uno'],
            capture_output=True, text=True, timeout=2,
            cwd=project_dir, stdin=subprocess.DEVNULL
        )
        dirty = bool(result2.stdout.strip())
        return branch, dirty
    except:
        return None, False

def get_origin_project_name(project_dir):
    """원본 checkout 기준 프로젝트명 (worktree 안에서도 같은 이름). 실패 시 경로 폴백(_project_path_fallback)."""
    if not project_dir:
        return 'Unknown'
    return _origin_project_git(project_dir)[0] or _project_path_fallback(project_dir)


def _project_path_fallback(project_dir):
    """git 판정 실패 시 경로만으로 고른 이름 — `<P>/.claude/worktrees/<이름>` 꼴이면 P, 아니면 폴더 이름."""
    parts = os.path.normpath(project_dir).split(os.sep)
    for i in range(2, len(parts) - 1):  # 첫 `.claude/worktrees` 기준(셸 `${dir%%/.claude/worktrees/*}` 와 동일)
        if parts[i] == 'worktrees' and parts[i - 1] == '.claude' and parts[i - 2]:
            return parts[i - 2]
    return os.path.basename(os.path.normpath(project_dir))


def _origin_project_git(project_dir):
    """(이름, 확정) — git 공통 디렉터리로 구한 원본 checkout 이름.
    확정=True: 성공했거나, git 저장소가 아님·git 없음·폴더 없음처럼 다시 해도 같은 결과(이름 '' 이면 경로 폴백이 정답).
    확정=False: timeout·그 밖 오류(NTFS 지연 등 일시 실패) — 호출자는 직전 저장값을 유지한다."""
    try:
        r = subprocess.run(
            ['git', 'rev-parse', '--path-format=absolute', '--git-common-dir'],
            capture_output=True, text=True, timeout=2,
            cwd=project_dir, stdin=subprocess.DEVNULL,
            env=dict(os.environ, LC_ALL='C', LANGUAGE='')  # 'not a git repository' 판정을 로캘과 무관하게
        )
        common = r.stdout.strip().rstrip('/')
        if r.returncode == 0 and common:
            base = os.path.basename(common)
            if base == '.git':
                name = os.path.basename(os.path.dirname(common))
            else:
                name = base[:-4] if base.endswith('.git') else base
            if name:
                return name, True
        if 'not a git repository' in (r.stderr or '').lower():
            return '', True
        return '', False
    except (FileNotFoundError, NotADirectoryError):
        return '', True
    except Exception:
        return '', False

# ── 파이프라인 상태 ───────────────────────────────────

def get_pipeline_info(session_id=None):
    """session-env/{UUID}에서 파이프라인 상태 + 진입 티어 읽기.

    base_dir 우선순위 (동기화 보장):
      1순위: ~/.claude/session-env/ (글로벌 — ok 스킬과 hook이 쓰는 단일 출처)
      2순위: $CLAUDE_CONFIG_DIR/session-env/ (격리 환경 폴백)
    cas 격리(CLAUDE_CONFIG_DIR=/tmp/cc-{UUID})에서 파일이 분리되는 케이스 방지.
    """
    home_base = os.path.expanduser('~/.claude/session-env')
    cfg_base = os.path.join(claude_config_dir(), 'session-env')
    # state 파일이 실제 존재하는 곳을 우선 채택 (디렉토리 존재만으로는 빈 껍데기 케이스 식별 불가).
    # 둘 다 있으면 mtime 최신 우선, 둘 다 없으면 home_base 폴백.
    if session_id:
        home_state = os.path.join(home_base, session_id, 'state')
        cfg_state  = os.path.join(cfg_base,  session_id, 'state')
        home_exists = os.path.isfile(home_state)
        cfg_exists  = os.path.isfile(cfg_state)
        if home_exists and cfg_exists:
            base_dir = home_base if os.path.getmtime(home_state) >= os.path.getmtime(cfg_state) else cfg_base
        elif cfg_exists:
            base_dir = cfg_base
        elif home_exists:
            base_dir = home_base
        else:
            base_dir = home_base
    else:
        base_dir = home_base

    def _read_state(env_dir):
        """특정 env_dir에서 entry_tier, state, tier, status를 읽는다."""
        state = "IDLE"
        try:
            with open(os.path.join(env_dir, 'state'), 'r') as f:
                line = f.read().strip()
            state = line.split()[0] if line else "IDLE"
        except:
            pass
        tier = None
        try:
            with open(os.path.join(env_dir, 'classification'), 'r') as f:
                cls = f.read().strip().upper()
            if cls in ('OK','O1','O2','O3','O4','O5'):
                tier = cls
        except:
            pass
        if tier is None and os.path.exists(os.path.join(env_dir, 'skill_direct')):
            try:
                with open(os.path.join(env_dir, 'skill_direct'), 'r') as f:
                    skill_name = f.read().strip().upper()
                if skill_name:
                    tier = skill_name
            except:
                pass
        status = None
        try:
            with open(os.path.join(env_dir, 'status'), 'r') as f:
                raw = f.read().strip()
            if raw and raw != 'NONE':
                status = raw
        except:
            pass
        # auto 파일(/oto 자율모드) 감지 — status 축(state_machine.sh)과는 별개인
        # 표시 전용 합류. 내용 첫 줄이 "ON"일 때만 AUTO 토큰을 status에 합류시킨다.
        # 알파벳 정렬 유지를 위해 토큰 목록에 AUTO를 추가한 뒤 재정렬한다.
        try:
            with open(os.path.join(env_dir, 'auto'), 'r') as f:
                auto_raw = f.readline().strip()
            if auto_raw == 'ON':
                tokens = [t for t in (status.upper().split('|') if status else []) if t]
                if 'AUTO' not in tokens:
                    tokens.append('AUTO')
                status = '|'.join(sorted(tokens))
        except:
            pass
        # entry_tier: ok 진입 흔적 (B안 별도 파일)
        entry_tier = None
        try:
            with open(os.path.join(env_dir, 'entry_tier'), 'r') as f:
                et = f.read().strip().upper()
            if et == 'OK':
                entry_tier = 'OK'
        except:
            pass  # 부재 시 None (NONE 폴백)
        return entry_tier, tier, state, status

    # session_id 기반으로만 조회 (새 세션은 항상 IDLE)
    if session_id:
        env_dir = os.path.join(base_dir, session_id)
        if os.path.isdir(env_dir):
            entry_tier, tier, state, status = _read_state(env_dir)
            return entry_tier, tier, state, status

    return None, None, "IDLE", None

def color_pipeline_display(entry_tier, tier, state, status=None, is_team_agent=False):
    """파이프라인 상태 표시.

    출력 형식 (§4.3):
      - status 부재/NONE : {tier_lower} {state_lower}           예) "o3 dev"
      - status 단일      : {tier_lower} {state_lower} {status_lower}  예) "o3 finish abort"
      - status 다중      : {tier_lower} {state_lower} {tokens_pipe}   예) "o3 dev pause|roof"
      - state=IDLE 단독  : "idle"
      - is_team_agent + IDLE : 빈 문자열 (팀에이전트 idle 표기 숨김)

    entry_tier 표시 매트릭스 (5케이스):
      - entry_tier=OK + tier=OK   → "ok"       (규칙 4 — ok:ok 금지)
      - entry_tier=OK + tier=O{N} → "ok:o{N}"  (규칙 2)
      - entry_tier=None + tier=O{N} → "o{N}"   (규칙 2 — 직접 진입)
      - entry_tier=None + tier=None → "?"       (폴백)
      - entry_tier=OK + tier=None → "ok"        (인스턴스 플랜)
    """
    state_colors = {
        'IDLE': C_WHITE, 'PLAN': C_BLUE,
        'DEV': C_GREEN, 'TEST': C_GOLD, 'DONE': C_PURPLE,
        'FINISH': C_SKY, 'OA': C_PINK,
    }
    state_icons = {
        'IDLE': '🧍', 'OK': '🚶', 'PLAN': '🤔',
        'DEV': '🏃', 'TEST': '🧪', 'DONE': '✅',
        'FINISH': '🧎', 'EARLY_TERM': '⏹️', 'ERROR': '❌',
        'OA': '🤸‍♀️',
    }
    tier_colors = {
        'O1': C_WHITE, 'O2': C_GREEN, 'O3': C_YELLOW,
        'O4': C_ORANGE, 'O5': C_PINK, 'OK': C_CYAN,
    }
    # status 토큰별 색상 매핑
    status_colors = {
        'ABORT': C_RED,
        'PAUSE': C_YELLOW,
        'ROOF': C_CYAN,
        'RALPH': C_CYAN,  # ROOF-COMPAT(deprecation window 1주기 — 구 RALPH/oralph_active 인식 제거 예정)
    }

    sc = state_colors.get(state, C_WHITE)
    icon = state_icons.get(state, '🏃‍♀️')

    # IDLE 단독 처리
    if state == "IDLE":
        # 팀에이전트(stdin JSON에 agent/agent_type 키 존재)는 idle 표기 숨김
        if is_team_agent:
            return ""
        return f"{icon} {C_WHITE}idle{C_RESET}"

    # tier/state 기본 문자열 (공백 구분, lowercase)
    tier_lower = tier.lower() if tier else None
    state_lower = state.lower()

    # status 문자열 구성
    status_str = None
    status_color = C_WHITE
    if status:
        tokens = status.upper().split('|')
        tokens = [t.strip() for t in tokens if t.strip()]
        # ROOF-COMPAT(deprecation window 1주기 — 구 RALPH/oralph_active 인식 제거 예정): RALPH→ROOF 정규화(중복 1회)
        tokens = list(dict.fromkeys('ROOF' if t == 'RALPH' else t for t in tokens))
        if tokens:
            status_lower = '|'.join(t.lower() for t in tokens)
            # 색상: 첫 번째 토큰 기준
            status_color = status_colors.get(tokens[0], C_WHITE)
            status_str = status_lower

    # entry_tier 5케이스 표시 매트릭스
    if entry_tier == 'OK' and tier == 'OK':
        # 규칙 4: ok:ok 금지 — "ok" 단독
        display_tier = 'ok'
        tc = tier_colors.get('OK', C_CYAN)
    elif entry_tier == 'OK' and tier is not None and tier.startswith('O') and len(tier) >= 2:
        # 규칙 2: ok:o{N}
        display_tier = f'ok:{tier.lower()}'
        tc = tier_colors.get(tier, C_CYAN)
    elif entry_tier is None and tier is not None and tier != 'OK':
        # 규칙 2: o{N} 단독 직접 진입
        display_tier = tier.lower()
        tc = tier_colors.get(tier, C_WHITE)
    elif entry_tier is None and tier == 'OK':
        # 모순(entry_tier 없이 classification=OK) — graceful 표시
        display_tier = 'ok'
        tc = tier_colors.get('OK', C_CYAN)
    elif entry_tier == 'OK' and tier is None:
        # 인스턴스 플랜 (odeep/oconsult/odebate — state 전이 없음)
        display_tier = 'ok'
        tc = tier_colors.get('OK', C_CYAN)
    else:
        # 폴백 (entry_tier=None + tier=None)
        display_tier = '?'
        tc = C_WHITE

    base = f"{icon} {tc}{display_tier}{C_RESET} {sc}{state_lower}{C_RESET}"
    if status_str:
        return f"{base} {status_color}{status_str}{C_RESET}"
    return base

# ── 소진 속도 ─────────────────────────────────────────

def calc_burn_rate(current_pct, resets_at, label, prev_state, window_hours):
    """소진 속도 계산. window_hours: 5 또는 168(7일)."""
    BURN_PROJECT_MIN_ELAPSED = 0.1
    if current_pct is None or not resets_at:
        return None
    now = time.time()
    used = float(current_pct)
    remaining = 100 - used
    time_left_h = (resets_at - now) / 3600
    if time_left_h <= 0:
        return None
    elapsed_h = window_hours - time_left_h
    if elapsed_h <= 0.01:
        return None
    burn_rate = used / elapsed_h
    if burn_rate <= 0:
        return None
    # 소진율 색상: 세션(5h)과 주간(168h) 분리
    if window_hours <= 10:
        # 세션 4단계: 회색→노랑→주황→핑크
        if burn_rate >= 40:
            c = C_PINK
        elif burn_rate >= 25:
            c = C_ORANGE
        elif burn_rate >= 15:
            c = C_YELLOW
        else:
            c = C_DIM
    else:
        # 주간 4단계: 회색→노랑→주황→핑크
        if burn_rate >= 2:
            c = C_PINK
        elif burn_rate >= 1:
            c = C_ORANGE
        elif burn_rate >= 0.5:
            c = C_YELLOW
        else:
            c = C_DIM
    # 창 초반(10% 미만 경과)은 표본이 적어 1% 만 써도 ⛔ 로 튄다 — 속도만 보이고 예상치는 내지 않는다
    if elapsed_h < window_hours * BURN_PROJECT_MIN_ELAPSED:
        return (f", {c}{burn_rate:.1f}%/h{C_RESET}", None)
    # 만료 시점 예상 사용률 (내부 계산) → 남은예상치 표시
    projected = used + burn_rate * time_left_h
    rem_proj = 100 - projected  # 남은예상치 (음수 허용)
    if rem_proj <= 0:
        proj_str = f"{C_PINK}⛔ {rem_proj:.0f}%{C_RESET}"
    elif rem_proj <= 10:
        proj_str = f"{C_ORANGE}⚠ {rem_proj:.0f}%{C_RESET}"
    elif rem_proj <= 20:
        proj_str = f"{C_YELLOW}⚡ {rem_proj:.0f}%{C_RESET}"
    else:
        proj_str = f"{C_WHITE}{rem_proj:.0f}%{C_RESET}"
    return (f", {c}{burn_rate:.1f}%/h{C_RESET}:{proj_str}", rem_proj)

# ── MCP 서버 상태 ─────────────────────────────────────

MCP_CACHE_FILE = os.path.join(claude_config_dir(), '.mcp_status_cache')
MCP_CACHE_TTL = 10  # 초
MCP_DISCONNECT_FILE = os.path.join(claude_config_dir(), '.mcp_disconnect')

def get_mcp_disconnected():
    """hook이 기록한 끊김 서버 목록 반환 (서버명 set)."""
    try:
        if os.path.exists(MCP_DISCONNECT_FILE):
            with open(MCP_DISCONNECT_FILE, 'r') as f:
                d = json.load(f)
            return set(d.keys())
    except:
        pass
    return set()

def _find_claude_pid():
    """현재 프로세스에서 부모 체인을 따라 올라가며 claude 본체 PID 반환.
    팀원 본체는 comm 이 버전 문자열(예: 2.1.318)이라 Name=='claude' 만 보면 못 찾는다(2026-11-05 실측) → _session_root_pid 판정을 쓴다."""
    return _session_root_pid('/proc', os.getpid())

# ── 세션 CPU·메모리 ───────────────────────────────────
# 이 statusline 을 띄운 세션(claude 본체 + 자식 트리)만 잰다. 팀원은 각자의 statusline 이 자기 트리를 잰다.
# 다른 세션 프로세스는 읽지 않는다(트리는 자기 본체의 children 파일로만 내려간다).

CPU_SAMPLE_MIN_GAP = 1.0  # 초. 이보다 짧은 간격이면 직전 계산값을 그대로 쓴다(잡음 방지)


def _session_root_pid(proc='/proc', start=None):
    """부모 체인을 따라 올라가 이 세션의 claude 본체 pid 를 찾는다.
    본체의 comm 은 'claude' 이거나 버전 문자열(exe 가 .../claude/versions/<버전>)이다. 못 찾으면 None."""
    pid = start if start is not None else os.getppid()
    for _ in range(12):
        try:
            with open(f'{proc}/{pid}/stat') as f:
                st = f.read()
            try:
                exe = os.readlink(f'{proc}/{pid}/exe')
            except OSError:
                exe = ''
            if st[st.find('(') + 1:st.rfind(')')] == 'claude' or '/claude/versions/' in exe:
                return pid
            pid = int(st[st.rfind(')') + 2:].split()[1])
            if pid <= 1:
                return None
        except Exception:
            return None
    return None


def _session_tree(root, proc='/proc', skip=()):
    """root 와 그 자손 pid 목록. 각 스레드의 children 파일로 내려간다(전체 /proc 스캔 없음)."""
    out, stack, seen = [], [root], set()
    while stack and len(out) < 2000:
        p = stack.pop()
        if p in seen:
            continue
        seen.add(p)
        if p not in skip:
            out.append(p)
        try:
            for t in os.listdir(f'{proc}/{p}/task'):
                try:
                    with open(f'{proc}/{p}/task/{t}/children') as f:
                        stack.extend(int(x) for x in f.read().split())
                except OSError:
                    pass
        except OSError:
            pass
    return out


def _tree_usage(pids, proc='/proc'):
    """(utime+stime+cutime+cstime 틱 합, VmRSS kB 합). 사라진 프로세스·커널 스레드(VmRSS 없음)는 건너뛴다."""
    ticks = rss_kb = 0
    for p in pids:
        try:
            with open(f'{proc}/{p}/stat') as f:
                st = f.read()
            v = st[st.rfind(')') + 2:].split()
            ticks += int(v[11]) + int(v[12]) + int(v[13]) + int(v[14])
        except Exception:
            continue
        try:
            with open(f'{proc}/{p}/status') as f:
                for line in f:
                    if line.startswith('VmRSS:'):
                        rss_kb += int(line.split()[1])
                        break
        except Exception:
            pass
    return ticks, rss_kb


_TEAM_NAME_RE = r'[A-Za-z0-9._-]{1,64}'
_SID_RE = r'[A-Za-z0-9_-]{1,80}'


def _teammate_ident(root, proc='/proc'):
    """본체 argv 의 --agent-id NAME@TEAM, --parent-session-id LEAD → (NAME, TEAM, LEAD). 팀원이 아니거나 형식이 틀리면 None.
    argv 는 런타임이 기동 때 정한 값이라 에이전트가 바꿀 수 없다."""
    try:
        with open(f'{proc}/{root}/cmdline', 'rb') as f:
            args = f.read().decode('utf-8', 'replace').split('\0')
        aid = args[args.index('--agent-id') + 1] if '--agent-id' in args else ''
        lead = args[args.index('--parent-session-id') + 1] if '--parent-session-id' in args else ''
        name, _, team = aid.partition('@')
        if (re.fullmatch(_TEAM_NAME_RE, name) and re.fullmatch(_TEAM_NAME_RE, team)
                and re.fullmatch(_SID_RE, lead)):
            return name, team, lead
    except Exception:
        pass
    return None


def _cpu_sample_path(session_id, ident=None):
    """직전 샘플 캐시 위치(자기 것만 쓴다).
    팀원: <설정 폴더>/statusline_cpu/<팀>/<이름>.json — 메인이 팀 config members 이름으로 찾아 합산한다.
    그 밖: 자기 세션 폴더(session-env/<자기 id>)가 있으면 그 안, 없으면 <설정 폴더>/statusline_cpu/<자기 id>.json."""
    base = claude_config_dir()
    if ident:
        return os.path.join(base, 'statusline_cpu', ident[1], f'{ident[0]}.json')
    d = os.path.join(base, 'session-env', session_id)
    if os.path.isdir(d):
        return os.path.join(d, 'cpu_sample.json')
    return os.path.join(base, 'statusline_cpu', f'{session_id}.json')


def session_cpu_mem(session_id, proc='/proc', now=None, start=None, clk_tck=None):
    """(CPU %(1코어=100), RSS MB). CPU 는 직전 샘플과의 틱 차분이라 첫 샘플이면 None. 실패하면 (None, None)."""
    try:
        if not session_id or not re.fullmatch(_SID_RE, session_id):
            return None, None
        root = _session_root_pid(proc, start)
        if not root:
            return None, None
        ticks, rss_kb = _tree_usage(_session_tree(root, proc, skip=(os.getpid(),)), proc)
        clk_tck = clk_tck or os.sysconf('SC_CLK_TCK')
        rss_mb = rss_kb / 1024.0
        now = time.time() if now is None else now
        ident = _teammate_ident(root, proc)
        path = _cpu_sample_path(session_id, ident)
        try:
            with open(path) as f:
                prev = json.load(f)
        except Exception:
            prev = {}
        pct = None
        if prev.get('pid') == root:
            gap = now - float(prev.get('t', 0))
            if 0 <= gap < CPU_SAMPLE_MIN_GAP:
                return prev.get('pct'), rss_mb
            if gap > 0:
                pct = max(0.0, (ticks - int(prev.get('ticks', 0))) / clk_tck / gap * 100.0)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = f'{path}.{os.getpid()}.tmp'
        rec = {'pid': root, 't': now, 'ticks': ticks, 'pct': pct, 'rss_mb': round(rss_mb, 1)}
        if ident:
            rec['lead'] = ident[2]
        with open(tmp, 'w') as f:
            json.dump(rec, f)
        os.replace(tmp, path)
        return pct, rss_mb
    except Exception:
        return None, None


TEAM_CPU_FRESH_SEC = 30  # 팀원 캐시가 이보다 오래되면 합산에서 뺀다(statusline 갱신 주기 5초 기준 여유)


def team_cpu_total(session_id, own_pct, own_mb, now=None):
    """메인 전용 팀 총합(메인 자신 + 팀원). /proc 를 훑지 않고 팀원 캐시 파일만 읽는다.
    범위: 자기 소유 팀 config(teams/<팀>/config.json, leadSessionId == 자기 id)의 members 이름에 해당하는
    statusline_cpu/<팀>/<이름>.json 중 lead == 자기 id 이고 TEAM_CPU_FRESH_SEC 이내인 것. 반환 (Σ%, ΣMB, 팀원 수), 팀원 0 이면 None."""
    try:
        if not session_id or not re.fullmatch(_SID_RE, session_id):
            return None
        base = claude_config_dir()
        team = ''
        try:
            with open(os.path.join(base, 'session-env', session_id, 'team_name')) as f:
                team = f.read().strip()
        except OSError:
            pass
        team = team or f'session-{session_id[:8]}'
        if not re.fullmatch(_TEAM_NAME_RE, team):
            return None
        with open(os.path.join(base, 'teams', team, 'config.json')) as f:
            conf = json.load(f)
        if conf.get('leadSessionId') != session_id:
            return None
        now = time.time() if now is None else now
        tot_pct, tot_mb, n = (own_pct or 0.0), (own_mb or 0.0), 0
        for m in conf.get('members') or []:
            m = m if isinstance(m, dict) else {}
            name = m.get('name') or ''
            if m.get('backendType') == 'in-process' or not re.fullmatch(_TEAM_NAME_RE, name):
                continue  # in-process 멤버(리더 자신 포함)는 메인 트리에 이미 들어 있다
            try:
                with open(os.path.join(base, 'statusline_cpu', team, f'{name}.json')) as f:
                    c = json.load(f)
            except Exception:
                continue
            if c.get('lead') != session_id or not (0 <= now - float(c.get('t', 0)) <= TEAM_CPU_FRESH_SEC):
                continue
            n += 1
            tot_pct += float(c.get('pct') or 0)
            tot_mb += float(c.get('rss_mb') or 0)
        return (tot_pct, tot_mb, n) if n else None
    except Exception:
        return None


def cpu_units():
    """CPU 표시 기준 코어 수(전체 논리 코어 합=100%). cgroup v2 cpu.max 쿼터·sched_getaffinity·os.cpu_count 중 최소."""
    cands = []
    try:
        cands.append(len(os.sched_getaffinity(0)))
    except Exception:
        pass
    try:
        cands.append(os.cpu_count() or 0)
    except Exception:
        pass
    try:
        with open('/sys/fs/cgroup/cpu.max') as f:
            q, per = f.read().split()[:2]
        if q != 'max' and float(per) > 0:
            cands.append(float(q) / float(per))
    except Exception:
        pass
    cands = [c for c in cands if c and c > 0]
    return max(1.0, min(cands)) if cands else 1.0


def _fmt_mem(mb):
    return f"{mb / 1024.0:.1f}G" if mb >= 1024 else f"{mb:.0f}M"


def fmt_cpu_mem(pct, rss_mb, total=None):
    """'⚙  12% 🧠 850M' 형식(⚙·⚠ 는 폭 판정이 1칸이라 공백 2칸)(메인은 팀 총합이 있으면 ' Σ48% 3.1G' 를 덧붙임). CPU 를 아직 모르면 '⚙ --', 메모리를 모르면 메모리 칸 생략."""
    if pct is None:
        cpu = f"{C_DIM}⚙  --{C_RESET}"
    else:
        c = C_PINK if pct >= 200 else (C_ORANGE if pct >= 100 else C_DIM)
        cpu = f"{c}⚙  {pct / cpu_units():.0f}%{C_RESET}"
    out = f"{cpu} {C_DIM}🧠 {_fmt_mem(rss_mb)}{C_RESET}" if rss_mb else cpu
    if total:
        tp, tm, _n = total
        c = C_PINK if tp >= 200 else (C_ORANGE if tp >= 100 else C_DIM)
        out += f" {c}Σ {tp / cpu_units():.0f}%{C_RESET} {C_DIM}{_fmt_mem(tm)}{C_RESET}"
    return out


def _get_all_children(pid, depth=0):
    """pid의 모든 자식 프로세스 PID 재귀 반환 (최대 5단계)."""
    if depth > 5:
        return []
    result = []
    try:
        r = subprocess.run(['pgrep', '-P', str(pid)], capture_output=True, text=True, timeout=2)
        children = [int(p) for p in r.stdout.strip().split() if p.strip().isdigit()]
        result.extend(children)
        for c in children:
            result.extend(_get_all_children(c, depth + 1))
    except:
        pass
    return result

def _get_cmdline(pid):
    """프로세스의 cmdline 반환 (null → space 변환)."""
    try:
        with open(f'/proc/{pid}/cmdline', 'rb') as f:
            return f.read().replace(b'\x00', b' ').decode('utf-8', errors='replace').strip()
    except:
        return ''

def _make_search_patterns(name, conf):
    """서버 설정에서 자식 프로세스 매칭용 패턴 목록 반환."""
    cmd = conf.get('command', '')
    args = conf.get('args', [])
    patterns = []

    # args에서 파일명(마지막 경로) 추출
    for a in args:
        basename = a.replace('\\', '/').split('/')[-1]
        if basename and '.' in basename and len(basename) > 3:
            patterns.append(basename)

    # npx/node 또는 cmd.exe /c npx: 패키지명 추출
    if cmd in ('npx', 'node') or (cmd == 'cmd.exe' and 'npx' in args):
        for a in args:
            if not a or a.startswith('-') or a in ('/c', 'npx', 'node', 'cmd.exe'):
                continue
            pkg = a.split('@latest')[0]
            if pkg.startswith('@'):
                parts = pkg.lstrip('@').split('/')
                token = parts[-1] if len(parts) > 1 else parts[0]
            else:
                token = pkg.split('@')[0]
            if token and len(token) > 2:
                patterns.append(token)
                break

    # fallback: cmd 자체의 basename
    if not patterns and cmd:
        patterns.append(cmd.replace('\\', '/').split('/')[-1])

    return patterns

def get_mcp_status(project_dir=None):
    """MCP 서버 상태 확인 (10초 캐시 + Claude PID 기반 현재 세션 필터링)."""
    disconnected = get_mcp_disconnected()

    # 캐시 확인 (끊김 파일은 캐시 내에서도 즉시 반영)
    try:
        if os.path.exists(MCP_CACHE_FILE):
            mtime = os.path.getmtime(MCP_CACHE_FILE)
            if time.time() - mtime < MCP_CACHE_TTL:
                with open(MCP_CACHE_FILE, 'r') as f:
                    cached = json.load(f)
                if disconnected:
                    for sname in list(cached.keys()):
                        short = sname.lstrip('p:')
                        if short in disconnected or sname in disconnected:
                            cached[sname] = False
                return cached
    except:
        pass

    # .mcp.json 로드
    _candidates = [
        os.path.join(claude_config_dir(), '.mcp.json'),
        os.path.expanduser('~/.mcp.json'),
    ]
    if project_dir:
        _candidates.append(os.path.join(project_dir, '.mcp.json'))
    _proj = os.environ.get('CLAUDE_PROJECT_DIR', '')
    if _proj:
        _candidates.append(os.path.join(_proj, '.mcp.json'))
    try:
        _candidates.append(os.path.join(os.getcwd(), '.mcp.json'))
    except:
        pass
    mcp_path = next((p for p in _candidates if os.path.exists(p)), None)

    servers = {}
    if mcp_path:
        try:
            with open(mcp_path, 'r') as f:
                cfg = json.load(f)

            # 현재 세션 Claude PID → 자식 프로세스 목록 + cmdline
            claude_pid = _find_claude_pid()
            child_cmdlines = []
            if claude_pid:
                child_pids = _get_all_children(claude_pid)
                child_cmdlines = [(p, _get_cmdline(p)) for p in child_pids]

            for name, conf in cfg.get('mcpServers', {}).items():
                patterns = _make_search_patterns(name, conf)
                alive = False

                if child_cmdlines and patterns:
                    # 현재 세션 자식 프로세스 중 패턴 매칭
                    for _pid, cmdline in child_cmdlines:
                        if any(p.lower() in cmdline.lower() for p in patterns):
                            alive = True
                            break
                elif patterns:
                    # claude PID 탐색 실패 시 pgrep fallback (부정확)
                    try:
                        r = subprocess.run(['pgrep', '-f', patterns[0]],
                                           capture_output=True, text=True, timeout=2,
                                           stdin=subprocess.DEVNULL)
                        alive = r.returncode == 0
                    except:
                        alive = False

                # hook이 끊김 기록한 경우 dead 처리
                if name in disconnected:
                    alive = False

                servers[name] = alive
        except:
            pass

    # plugin 방식 MCP (serena 등) — Claude Code 내부 관리, 항상 alive
    try:
        settings_path = os.path.join(claude_config_dir(), 'settings.json')
        if os.path.exists(settings_path):
            with open(settings_path, 'r') as f:
                settings = json.load(f)
            MCP_PLUGINS = {'serena'}
            for plugin_key, enabled in settings.get('enabledPlugins', {}).items():
                if enabled:
                    plugin_name = plugin_key.split('@')[0]
                    if plugin_name in MCP_PLUGINS:
                        servers[f"p:{plugin_name}"] = True
    except:
        pass

    # 캐시 저장
    try:
        with open(MCP_CACHE_FILE, 'w') as f:
            json.dump(servers, f)
    except:
        pass
    return servers

# ── ChatGPT 비용 ──────────────────────────────────────

def get_openai_cost():
    cost = os.environ.get('OPENAI_COST_USD')
    if cost:
        try:
            return float(cost)
        except:
            pass
    for p in [
        os.path.join(claude_config_dir(), 'openai_cost.txt'),
        '/tmp/openai_cost.txt',
    ]:
        if os.path.exists(p):
            try:
                with open(p, 'r') as f:
                    return float(f.read().strip())
            except:
                pass
    return None

# ── 계정 ──────────────────────────────────────────────

_EMAIL_NICK_CACHE = {'mtime': 0, 'map': {}}

def read_profile_email(profile_dir):
    """프로필의 실제 계정 이메일. 로그인 때 Claude Code 가 쓰는 .claude.json 이 정본이고
    .account_email_cache 는 낡을 수 있어 폴백으로만 쓴다. 모르면 빈 문자열."""
    try:
        with open(os.path.join(profile_dir, '.claude.json'), 'r') as f:
            email = ((json.load(f).get('oauthAccount') or {}).get('emailAddress') or '').strip()
        if email:
            return email
    except Exception:
        pass
    try:
        with open(os.path.join(profile_dir, '.account_email_cache'), 'r') as f:
            return (json.load(f).get('email') or '').strip()
    except Exception:
        return ''

def account_notice(account_email):
    """현재 계정은 /login 으로 언제든 바뀔 수 있으므로 경고하지 않는다. 시험·호출부 호환을 위해 항상 빈 문자열."""
    return ''

def email_to_nick(email):
    """~/.claude-profiles/<nick>/ 사전 스캔으로 email→nick 역매핑.
    팀에이전트에서 CLAUDE_PROFILE_NAME 환경변수가 누락되어도 닉네임을 복원하기 위함.
    프로필 디렉토리 mtime 기반 in-process 캐시(statusline 호출당 1회만 디스크 스캔)."""
    if not email:
        return ''
    try:
        base = profiles_root()
        if not os.path.isdir(base):
            return ''
        mt = os.path.getmtime(base)
        if mt != _EMAIL_NICK_CACHE['mtime']:
            mp = {}
            for nick in os.listdir(base):
                d = os.path.join(base, nick)
                if not os.path.isdir(d):
                    continue
                em = read_profile_email(d).lower()
                if em:
                    # 같은 이메일로 로그인한 프로필이 여럿일 수 있다(예: cs·know 동일 계정).
                    # 마지막 항목이 덮어쓰지 않도록 후보 전부를 보관한다.
                    mp.setdefault(em, []).append(nick)
            _EMAIL_NICK_CACHE['map'] = {k: sorted(v) for k, v in mp.items()}
            _EMAIL_NICK_CACHE['mtime'] = mt
        return list(_EMAIL_NICK_CACHE['map'].get(email.strip().lower(), []))
    except Exception:
        return []

def resolve_profile_name(account_email, is_team_agent=False):
    """statusline + 타이틀바 공통 프로필 라벨 결정 로직.
    라벨은 세션의 현재 계정(/login 으로 언제든 바뀔 수 있음) 기준이다. 이메일은 호출부가 따로 붙인다.
      1. 시작 프로필(CLAUDE_PROFILE_NAME)의 계정이 현재 계정과 같거나 어느 쪽이든 모르면 시작 프로필 이름 하나('/' 묶음 없음)
         다르면 현재 이메일 후보가 1개일 때 그 닉, 0·복수면 빈 문자열(이메일만 표시). 프로필 매핑은 바꾸지 않는다.
      2. 팀원은 환경에 시작 프로필이 전달되지 않으므로 메인이 남긴 .display_profile 을 쓴다('?'·빈 값 무시)
      3. 시작 프로필을 모를 때는 이메일 후보가 1개면 그 닉, 복수·0개면 빈 문자열(이메일만 표시)
    메인은 2번을 쓰지 않는다. .display_profile 을 쓰는 쪽이 메인이라 읽으면 낡은 값이 스스로 유지된다.
    빈 문자열 반환 가능 (호출자가 이메일만 또는 '?' 로 표시).
    """
    env_profile = os.environ.get('CLAUDE_PROFILE_NAME', '').strip()
    if env_profile:
        session_email = (account_email or '').strip().lower()
        profile_email = read_profile_email(os.path.join(profiles_root(), env_profile)).lower()
        if not session_email or not profile_email or profile_email == session_email:
            return env_profile
        nicks = email_to_nick(account_email)
        return nicks[0] if len(nicks) == 1 else ''
    if is_team_agent:
        try:
            with open(os.path.join(claude_config_dir(), '.display_profile'), 'r') as f:
                label = f.read().strip()
            if label and label != '?':
                return label
        except OSError:
            pass
    nicks = email_to_nick(account_email) if account_email else []
    if len(nicks) == 1:
        return nicks[0]
    return ''

def account_label(account_email, color=False, is_team_agent=False):
    """statusline 계정 표시(👤 제외). 닉+이메일 → 'know(a@x)', 닉만 → 'know(?)', 이메일만 → 'a@x', 둘 다 모름 → '?'."""
    nick = resolve_profile_name(account_email, is_team_agent)
    if color:
        if nick:
            return f"{C_WHITE}{nick}{C_RESET}{C_DIM}({account_email or '?'}){C_RESET}"
        return f"{C_DIM}{account_email or '?'}{C_RESET}"
    return f"{nick}({account_email or '?'})" if nick else (account_email or '?')

def get_account_email(_session_id=None):
    creds_path = os.path.join(claude_config_dir(), '.credentials.json')
    try:
        cache = os.path.join(claude_config_dir(), '.account_email_cache')
        creds_mtime = os.path.getmtime(creds_path)
        if os.path.exists(cache):
            try:
                with open(cache, 'r') as f:
                    cached = json.loads(f.read())
                if cached.get('creds_mtime') == creds_mtime and cached.get('email'):
                    return cached['email']
            except:
                pass
        result = subprocess.run(
            ['claude', 'auth', 'status'],
            capture_output=True, text=True, timeout=15,
            stdin=subprocess.DEVNULL
        )
        info = json.loads(result.stdout)
        email = info.get('email', '')
        if email:
            with open(cache, 'w') as f:
                json.dump({'creds_mtime': creds_mtime, 'email': email}, f)
        return email or None
    except:
        pass
    return None

# ── stdin JSON ────────────────────────────────────────

def load_stdin_json():
    try:
        content = sys.stdin.read()
        if content.startswith('\ufeff'):
            content = content[1:]
        return json.loads(content)
    except:
        return {}

data = load_stdin_json()
prev_state = load_state()

# ── 필드 추출 ─────────────────────────────────────────

model_name = data.get('model', {}).get('display_name', 'Unknown')
version = data.get('version', '')

workspace = data.get('workspace', {})
project_dir = workspace.get('project_dir') or workspace.get('current_dir') or data.get('cwd', '')
# 프로젝트명 — git 판정이 확정(성공 또는 '저장소 아님')일 때만 display_project 에 저장한다.
# 일시 실패·timeout(NTFS worktree 에서 실측)이면 직전 저장값을 유지해 제목이 `pd-18` ↔ `Pd` 로 번갈지 않게 한다(2026-11-06).
_project_git, _project_name_ok = _origin_project_git(project_dir) if project_dir else ('', False)
project_name = _project_git
if not project_name and project_dir and _project_name_ok:
    # git 저장소가 아님(확정) — 경로 폴백이 안정적인 정답이므로 표시·저장한다
    project_name = _project_path_fallback(project_dir)
if not project_name and project_dir:
    try:
        _sid0 = data.get('session_id', '')
        if _sid0 and re.fullmatch(r'[A-Za-z0-9_-]+', _sid0):
            with open(os.path.join(claude_config_dir(), 'session-env', _sid0, 'display_project'), encoding='utf-8') as _pf:
                project_name = _pf.read().strip()
    except Exception:
        project_name = ''
if not project_name:
    project_name = _project_path_fallback(project_dir) if project_dir else 'Unknown'



# 컨텍스트
ctx = data.get('context_window', {})
ctx_remaining_pct = ctx.get('remaining_percentage')
total_input = ctx.get('total_input_tokens')
total_output = ctx.get('total_output_tokens')



# 컨텍스트 표시
AUTO_COMPACT_THRESHOLD = 20
if ctx_remaining_pct is not None:
    remaining = float(ctx_remaining_pct)
    cc = tier_color(remaining)
    bar = dot_bar(remaining)
    if remaining <= AUTO_COMPACT_THRESHOLD:
        context_str = f"💭 {bar} {cc}{remaining:.0f}%⚠{C_RESET}"
    else:
        context_str = f"💭 {bar} {cc}{remaining:.0f}%{C_RESET}"
else:
    context_str = f"💭 {C_DIM}◦◦◦◦ n/a{C_RESET}"

# Rate Limits
rate_limits = data.get('rate_limits', {})
five_h = rate_limits.get('five_hour', {})
five_h_pct = five_h.get('used_percentage')
five_h_resets = five_h.get('resets_at')

def fmt_rate_limit(pct_used, resets_at, label, burn_str, time_thresholds=None):
    if pct_used is None:
        return f"{C_DIM}•••• {label} n/a{C_RESET}"
    remaining = 100 - float(pct_used)
    rem = fmt_remaining(resets_at, time_thresholds)
    rem_suffix = f" ({rem})" if rem else ""
    c = tier_color(remaining)
    bar = line_bar(remaining)
    burn_suffix = f" {burn_str}" if burn_str else ""
    return f"{label} {bar} {c}{remaining:.0f}%{C_RESET}{rem_suffix}{burn_suffix}"

seven_d = rate_limits.get('seven_day', {})
seven_d_pct = seven_d.get('used_percentage')
seven_d_resets = seven_d.get('resets_at')

# 소진 속도 (먼저 계산) — 튜플 (burn_str, rem_proj) 반환
_burn_5h_result = calc_burn_rate(five_h_pct, five_h_resets, '5h', prev_state, 5)
_burn_7d_result = calc_burn_rate(seven_d_pct, seven_d_resets, '7d', prev_state, 168)
burn_5h, _rem_proj_5h = _burn_5h_result if _burn_5h_result else (None, None)
burn_7d, _rem_proj_7d = _burn_7d_result if _burn_7d_result else (None, None)
# rem_proj: 주간 우선, 없으면 세션 값 사용
_rem_proj_val = _rem_proj_7d if _rem_proj_7d is not None else _rem_proj_5h

# 세션/주간에 소진속도 합침
# 세션: 3h↑회색, 2h↑녹, 1h↑주황, 1h↓빨강
session_str = fmt_rate_limit(five_h_pct, five_h_resets, "⏱ ", burn_5h, (3, 2, 1))
# 주간: 48h↑회색, 24h↑녹, 12h↑주황, 12h↓빨강
weekly_str = fmt_rate_limit(seven_d_pct, seven_d_resets, "🕐", burn_7d, (48, 24, 12)) if seven_d_pct is not None else None



# 세션 경과 시간
cost_data = data.get('cost', {})
duration_ms = cost_data.get('total_duration_ms')
duration_str = fmt_duration(duration_ms)

# GPT 비용
openai_cost = get_openai_cost()

# 계정
account_email = get_account_email(data.get('session_id', ''))

# 사용량 캐시 저장 (5분 TTL — cc/ccc/cas monitor가 읽음)
save_usage_cache(rate_limits, model_name, account_email)

# 파이프라인
session_id = data.get('session_id', '')
pipeline_entry_tier, pipeline_tier, pipeline_state, pipeline_status = get_pipeline_info(session_id)
# 팀에이전트 식별: stdin JSON에 agent/agent_type 키 존재 여부 (PIPELINE_UUID env는 미전파됨)
is_team_agent = bool(data.get('agent') or data.get('agent_type'))
pipeline_str = color_pipeline_display(pipeline_entry_tier, pipeline_tier, pipeline_state, pipeline_status, is_team_agent)

# 컨텍스트 사용률 기록 (UserPromptSubmit_ctx_notify.sh 가 읽음) — 메인 세션만, 모든 예외 삼킴
def write_ctx_used_pct(session_id, ctx, is_team_agent):
    try:
        if is_team_agent or not session_id:
            return
        pct = ctx.get('used_percentage')
        if pct is None:
            rem = ctx.get('remaining_percentage')
            if rem is None:
                return
            pct = 100 - float(rem)
        pct = int(round(float(pct)))
        sdir = os.path.join(claude_config_dir(), 'session-env', str(session_id))
        if not os.path.isdir(sdir):
            return
        path = os.path.join(sdir, 'ctx_used_pct')
        now = int(time.time())
        try:
            with open(path, 'r') as f:
                old_ts, old_pct = f.read().strip().split('|')
            if int(old_pct) == pct and now - int(old_ts) < 5:
                return
        except Exception:
            pass
        tmp = path + '.tmp.' + str(os.getpid())
        with open(tmp, 'w') as f:
            f.write('%d|%d\n' % (now, pct))
        os.replace(tmp, path)
    except Exception:
        pass

write_ctx_used_pct(session_id, ctx, is_team_agent)

# 상태 저장
save_state(prev_state)

# ── 세션 롤 배지 ────────────────────────────────────
def get_session_role(session_id):
    """세션 롤 값('<id>[:영역][#에이전트명]')을 돌려준다. all·미지정·정의 밖 id·예외는 빈 문자열(배지 생략)."""
    try:
        if not session_id:
            return ''
        # 1순위: role_lib 의 경로 계산(read_role_raw)을 import 로 공유한다(subprocess 금지). 실패하면 아래 인라인 폴백.
        _home = os.environ.get('ROLE_HOME_BASE', '').strip() or os.path.expanduser('~/.claude')
        _libdirs = [os.environ.get('ROLE_LIB_DIR', '').strip()]
        for b in (claude_config_dir(), _home):
            _libdirs.append(os.path.join(b, 'hooks', 'lib'))
        for d in _libdirs:
            if d and os.path.isfile(os.path.join(d, 'role_lib.py')):
                try:
                    import importlib.util as _ilu
                    _spec = _ilu.spec_from_file_location('role_lib_shared', os.path.join(d, 'role_lib.py'))
                    _mod = _ilu.module_from_spec(_spec)
                    _spec.loader.exec_module(_mod)
                    _val = _mod.read_role_raw(session_id)
                    if not _val or _val.split(':', 1)[0].split('#', 1)[0] == 'all':
                        return ''
                    return _val
                except Exception:
                    break
        bases = []
        for b in (claude_config_dir(), _home):
            if b not in bases:
                bases.append(b)
        best = None
        for b in bases:
            p = os.path.join(b, 'session-env', session_id, 'role')
            if os.path.isfile(p):
                m = os.path.getmtime(p)
                if best is None or m > best[0]:
                    best = (m, p)
        if best is None:
            return ''
        with open(best[1], encoding='utf-8') as f:
            value = f.readline().strip()
        rid = value.replace('#', ':').split(':', 1)[0].strip().lower()
        defs_path = os.environ.get('ROLE_DEFS', '').strip()
        if not defs_path:
            for b in bases:
                cand = os.path.join(b, 'hooks', 'lib', 'role_defs.json')
                if os.path.isfile(cand):
                    defs_path = cand
                    break
        if not defs_path:
            return ''
        with open(defs_path, encoding='utf-8') as f:
            ids = [r.get('id') for r in json.load(f).get('roles', [])]
        if rid not in ids or rid == 'all':
            return ''
        if '#' in value and value.split('#', 1)[1].isdigit():
            value = value.split('#', 1)[0]  # 옛 자동 번호(#1)는 표시에서 뺀다
        return value
    except Exception:
        return ''


# ── 에이전트명 ──────────────────────────────────────
def clean_display_name(raw):
    """표시 이름을 제목·tmux 형식 문자열에 안전한 값으로 정리한다. 공백은 '-', 허용 밖 문자가 있으면 빈 문자열."""
    name = '-'.join(str(raw or '').split())
    return name if re.fullmatch(r'[0-9A-Za-z가-힣._-]{1,40}', name) else ''


def get_session_display_name(session_id):
    """메인 세션 표시 이름(자기 claude pid 의 등록부 name). 같은 sessionId 파일이 pid 별로 여럿일 수 있어 pid 로만 찾고 sessionId 로 확인한다."""
    try:
        pid = _find_claude_pid()
        if not pid or not session_id:
            return ''
        with open(os.path.join(claude_config_dir(), 'sessions', f'{pid}.json'), encoding='utf-8') as f:
            reg = json.load(f)
        return clean_display_name(reg.get('name')) if reg.get('sessionId') == session_id else ''
    except Exception:
        return ''


def get_teammate_name(stdin_data):
    """팀원 이름. 부모 프로세스 인자 --agent-name 이 1순위, 없으면 stdin agent.name.
    인자 없는 claude(comm=claude)를 만나면 거기서 멈춘다. 그 위는 이 세션을 띄운 다른 에이전트이므로 이름을 가져오면 안 된다."""
    try:
        pid = os.getpid()
        for _ in range(12):
            with open(f'/proc/{pid}/cmdline', 'rb') as f:
                args = f.read().decode('utf-8', 'replace').split('\0')
            if '--agent-name' in args:
                name = clean_display_name(args[args.index('--agent-name') + 1])
                if name:
                    return name
                break
            with open(f'/proc/{pid}/stat') as f:
                stat = f.read()
            if stat[stat.find('(') + 1:stat.rfind(')')] == 'claude':
                break
            pid = int(stat[stat.rfind(')') + 2:].split()[1])
            if pid <= 1:
                break
    except Exception:
        pass
    try:
        return clean_display_name((stdin_data.get('agent') or {}).get('name'))
    except Exception:
        return ''


def save_title_field(session_id, filename, name):
    """hook 제목(set_terminal_title.sh)이 읽을 값(표시 이름·프로젝트명)을 자기 세션 폴더에 남긴다. 변경 시에만 쓰고 값이 없으면 지운다."""
    try:
        d = os.path.join(claude_config_dir(), 'session-env', session_id)
        if not session_id or not os.path.isdir(d):
            return
        p = os.path.join(d, filename)
        try:
            with open(p, encoding='utf-8') as f:
                old = f.read()
        except OSError:
            old = None
        if not name:
            if old is not None:
                os.remove(p)
        elif old != name:
            with open(p, 'w', encoding='utf-8') as f:
                f.write(name)
    except Exception:
        pass


# ── Windows Terminal 타이틀바 갱신 ──────────────────
# 포맷: "{호스트이모지}{프로젝트} [🎭롤] {state이모지} [{아이콘}{남은%}] 👤 {ID}" (값이 없는 칸은 생략, tier·단계 텍스트 없음)
# 아이콘=리셋 시점 예상잔량 기준, 숫자=현재 남은 주간%
# 예시: "🖥️AI 🤔 56% 👤 common" / 롤 지정 시 "🖥️AI 🎭back 🏃 ⚡35% 👤 rio", /oagent 이름 지정 시 "🖥️AI 🎭back#철수 🧍 ⚡35% 👤 rio" (👤 는 계정명 바로 앞)
# 바깥 창 제목 맨 앞에는 tmux set-titles-string 이 메인 pane 작업 중일 때 스피너(◜◝◞◟)+공백을 넣는다.
# tmux rename-window 경유 — tmux가 #W 변경 감지해 OSC 2 자동 송출
def _save_usage_badge(badge):
    """hook 제목(set_terminal_title.sh)이 같은 사용량 표기를 쓰도록 세션 설정 폴더에 남긴다. 값이 없으면 지운다."""
    path = os.path.join(claude_config_dir(), '.weekly_remaining_cache')
    try:
        if not badge:
            if os.path.exists(path):
                os.remove(path)
            return
        try:
            with open(path, 'r', encoding='utf-8') as f:
                if f.read() == badge:
                    return
        except (OSError, UnicodeDecodeError):
            pass
        tmp = f"{path}.{os.getpid()}"
        with open(tmp, 'w', encoding='utf-8') as f:
            f.write(badge)
        os.replace(tmp, path)
    except Exception:
        pass


_HOST_FALLBACK = ('linux', '\U0001F5C4️')  # host_label.py 를 못 읽을 때만 쓰는 값(🗄️)


def load_host_label():
    """(host_tag, host_emoji) — 판정·이모지 규칙은 hooks/lib/host_label.py 한 곳에만 있다. 못 읽으면 _HOST_FALLBACK."""
    try:
        here = os.path.dirname(os.path.realpath(__file__))
        _home = os.environ.get('ROLE_HOME_BASE', '').strip() or os.path.expanduser('~/.claude')
        cands = [os.environ.get('HOST_LABEL_LIB_DIR', '').strip(),
                 os.path.join(here, 'hooks', 'lib'),                  # 배포본: plugins/harness/statusline.py
                 os.path.join(here, '..', '.claude', 'hooks', 'lib'),  # 저장소: script/statusline.py
                 os.path.join(claude_config_dir(), 'hooks', 'lib'),
                 os.path.join(_home, 'hooks', 'lib')]
        for d in cands:
            p = os.path.join(d, 'host_label.py') if d else ''
            if p and os.path.isfile(p):
                import importlib.util as _ilu
                _spec = _ilu.spec_from_file_location('host_label_shared', p)
                _mod = _ilu.module_from_spec(_spec)
                _spec.loader.exec_module(_mod)
                tag = _mod.host_tag()
                return tag, _mod.host_emoji(tag)
    except Exception:
        pass
    return _HOST_FALLBACK


def _update_terminal_title(project, state, rem_proj_pct,
                            account_email=None, entry_tier=None, tier=None, status=None,
                            is_team_agent=False, rem_now_pct=None, role='', host_emoji=''):
    """tmux 안: rename-window. 단계 칸은 state 이모지 하나만 쓴다(tier·단계·status 텍스트 없음, 2026-11-07).
    entry_tier·tier·status 인자는 호출부 호환을 위해 남긴다.

    rem_proj_pct: 리셋 시점 예상잔량 (100-projected). 아이콘 판정 전용 ≤0→⛔ / ≤10→⚠ / ≤20→⚡ / else→없음
    rem_now_pct: 현재 남은 주간 % (100-used, 주간 없으면 5h). 표시 숫자용. None이면 rem_proj_pct 숫자 사용
    """
    # 팀에이전트는 메인 타이틀바를 건드리지 않음 (idle 회귀 방지)
    if is_team_agent:
        return
    try:
        state_emojis = {
            'IDLE': '🧍', 'OK': '🚶', 'PLAN': '🤔', 'DEV': '🏃',
            'TEST': '🧪', 'DONE': '✅', 'FINISH': '🧎',
            'EARLY_TERM': '⏹️', 'ERROR': '❌',
        }
        profile_id = resolve_profile_name(account_email) or '?'
        # hook 쪽 제목(set_terminal_title.sh)이 같은 판정값을 쓰도록 세션 설정 폴더에 남긴다(변경 시에만 쓰기)
        try:
            _label_path = os.path.join(claude_config_dir(), '.display_profile')
            try:
                with open(_label_path, 'r') as _lf:
                    _label_old = _lf.read()
            except OSError:
                _label_old = None
            if _label_old != profile_id:
                with open(_label_path, 'w') as _lf:
                    _lf.write(profile_id)
        except Exception:
            pass
        state_upper = (state or 'IDLE').upper()
        if state_upper not in state_emojis:
            state_upper = 'IDLE'
        emoji = state_emojis[state_upper]
        if rem_proj_pct is not None:
            v = rem_proj_pct
            n = rem_now_pct if rem_now_pct is not None else v
            # 타이틀 배지는 무공백 — set_terminal_title.sh 가 캐시를 공백 제거해 쓰므로 두 경로 제목을 바이트 단위로 맞춘다(5초 번갈음 방지)
            if v <= 0:
                rem_badge = f"⛔{n:.0f}%"
            elif v <= 10:
                rem_badge = f"⚠{n:.0f}%"
            elif v <= 20:
                rem_badge = f"⚡{n:.0f}%"
            else:
                rem_badge = f"{n:.0f}%"
        elif rem_now_pct is not None:
            # 창 초반이라 예상치가 없어도 현재 남은 % 는 그대로 보여 준다(아이콘 없음)
            rem_badge = f"{rem_now_pct:.0f}%"
        else:
            rem_badge = ""
        _save_usage_badge(rem_badge)
        id_part = f"👤 {profile_id}"  # 👤 는 계정명 바로 앞. 남은 용량은 에이전트명 뒤·단계 앞(2026-11-04 사용자 요청)
        badge_part = f" {rem_badge}" if rem_badge else ""

        # 순서: 호스트 이모지+프로젝트 → 에이전트명(🎭롤) → state 이모지 → 남은 용량 → 👤 계정명(2026-11-07 사용자 요청). 값이 없으면 빈 문자열이라 공백이 겹치지 않는다.
        # tier·단계 텍스트(ok:o5 plan 등)는 타이틀에서 뺀다(2026-11-07 사용자 요청). 하단 statusline 본문의 파이프라인 표시는 그대로다.
        # 이모지와 프로젝트 사이는 공백 없음(🖥️AI) — wt_title_watch.project_of() 가 첫 공백 토큰을 프로젝트 키로 쓴다.
        # 세션 표시 이름(AI-8c 류)은 타이틀에 넣지 않는다(2026-11-06 사용자 지시). /oagent 이름은 🎭롤#이름 으로 남는다.
        role_part = f" 🎭{role}" if role else ""  # 무공백 — set_terminal_title.sh 의 ROLE_PART 와 동일
        title = f"{host_emoji}{project}{role_part} {emoji}{badge_part} {id_part}"
        # tmux 안: rename-window(내부 #W) + DCS passthrough(외부 WT 탭)
        # cas가 tmux 자동 spawn하므로 사용자 화면은 항상 tmux 안 보장.
        # 대상 없는 tmux 명령은 가장 최근 세션에 적용돼 다른 세션 제목을 바꾼다. 자기 pane 을 모르면 쓰지 않는다.
        pane = os.environ.get('TMUX_PANE') or ''
        if os.environ.get('TMUX') and re.fullmatch(r'%\d+', pane):
            # rename-window 이름은 tmux 형식 문자열로 확장된다(#S·#W·#h 등). 에이전트명(front#이름)의 '#' 은 '##' 로 이스케이프한다.
            subprocess.run(
                ['tmux', 'rename-window', '-t', pane, title.replace('#', '##')],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                timeout=1
            )
            # 외부 송출 문자열은 tmux 가 계산한 창 제목(set-titles-string — 메인 pane 작업 중 프로젝트명 앞 스피너 포함)과 같게 맞춘다.
            # 다르게 보내면 5초마다 스피너 없는 제목으로 덮어써 깜빡인다. 실패 시 title 그대로.
            outer_title = title
            try:
                r = subprocess.run(
                    ['tmux', 'display-message', '-p', '-t', pane, '#{T:set-titles-string}'],
                    capture_output=True, text=True, timeout=1
                )
                if r.returncode == 0 and r.stdout.strip():
                    outer_title = r.stdout.rstrip('\n')
            except Exception:
                pass
            try:
                # OSC 0(icon+title) + OSC 2(title) 양쪽 DCS passthrough 송출 — WT cold-start 대응.
                sys.stdout.write(f"\x1bPtmux;\x1b\x1b]0;{outer_title}\x07\x1b\\")
                sys.stdout.write(f"\x1bPtmux;\x1b\x1b]2;{outer_title}\x07\x1b\\")
                sys.stdout.flush()
            except Exception:
                pass
    except Exception:
        pass

# 현재 남은 % (주간 우선, 없으면 5h) — 타이틀 숫자용
try:
    _used_now = seven_d_pct if seven_d_pct is not None else five_h_pct
    _rem_now_val = (100 - float(_used_now)) if _used_now is not None else None
except Exception:
    _rem_now_val = None

session_role = '' if is_team_agent else get_session_role(session_id)
# 에이전트명: 팀원은 자기 이름, 메인은 /oagent 이름(role 의 #뒤)이 있으면 그것, 없으면 세션 표시 이름. 못 읽으면 칸 생략.
_oagent_name = session_role.split('#', 1)[1] if '#' in session_role else ''
_display_name = ''
if is_team_agent:
    agent_name = get_teammate_name(data)
else:
    _display_name = get_session_display_name(session_id)
    save_title_field(session_id, 'display_name', _display_name)
    if _project_name_ok:  # 폴백 이름은 저장하지 않는다(직전 성공값 보존)
        save_title_field(session_id, 'display_project', project_name)
    agent_name = _oagent_name or _display_name
_host_tag, _host_emoji = load_host_label()
_host_color = C_CYAN if _host_tag == 'wsl' else C_YELLOW
_update_terminal_title(project_name, pipeline_state, _rem_proj_val, account_email,
                        entry_tier=pipeline_entry_tier, tier=pipeline_tier, status=pipeline_status,
                        is_team_agent=is_team_agent, rem_now_pct=_rem_now_val,
                        role=session_role, host_emoji=_host_emoji)

# ── 출력 (Powerline 스타일) ───────────────────────────

parts = []

# 프로젝트 — 맨 앞 호스트 이모지 + 공백 1 (색: wsl 청록, linux 노랑). 에이전트명은 다중 세션 구분용으로 유지
parts.append(f"{_host_color}{_host_emoji + ' ' if _host_emoji else ''}{project_name}{' ' + agent_name if agent_name else ''}{C_RESET}")
if session_role:
    parts.append(f"🎭 {C_GOLD}{session_role}{C_RESET}")

# 파이프라인 (팀에이전트 IDLE은 빈 문자열 반환 → 추가하지 않음)
if pipeline_str:
    parts.append(pipeline_str)

# 모델
parts.append(f"🤖 {model_name}")

# 주간 + 세션 (주간 먼저)
if weekly_str:
    parts.append(weekly_str)
parts.append(session_str)

# 컨텍스트
parts.append(context_str)

# 세션 경과 시간
if duration_str:
    parts.append(f"🚴‍♂️ {C_DIM}{duration_str}{C_RESET}")



# MCP 서버 상태
mcp_servers = get_mcp_status(project_dir)
if mcp_servers:
    total = len(mcp_servers)
    alive = sum(1 for v in mcp_servers.values() if v)
    dead = total - alive
    if dead == 0:
        parts.append(f"{C_DIM}MCP 🔌{C_RESET}")
    elif alive == 0:
        down = [n for n, v in mcp_servers.items() if not v]
        parts.append(f"{C_RED}MCP ⚡ {','.join(down)}{C_RESET}")
    else:
        down = [n for n, v in mcp_servers.items() if not v]
        parts.append(f"{C_ORANGE}MCP ⚡ {','.join(down)}{C_RESET}")

# 리더 RSS 경고 — 임계(기본 1500MB, env CC_LEADER_RSS_WARN_MB) 이상일 때만 표시, 실패 시 생략
try:
    _rss_warn_mb = float(os.environ.get('CC_LEADER_RSS_WARN_MB') or 1500)
    _leader_pid = _find_claude_pid()
    if _leader_pid:
        with open(f'/proc/{_leader_pid}/status') as _f:
            _rss_kb = next((int(l.split()[1]) for l in _f if l.startswith('VmRSS:')), 0)
        if _rss_kb / 1024.0 >= _rss_warn_mb:
            parts.append(f"{C_ORANGE}⚠️ RSS {_rss_kb / 1048576.0:.1f}G 재시작 권장(/exit→ccc){C_RESET}")
except Exception:
    pass

# WT 탭 제목 고정 감시 — 60초마다 단발 점검 기동, 고정 감지 시 경고(실패 시 생략)
_wt_warn_line = ''
if not is_team_agent:
    try:
        sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
        import wt_title_watch as _wtw
        _wtw.trigger()
        _wt_warn = _wtw.format_warning()
        if _wt_warn:
            # 1줄 끝에 붙이면 좁은 pane 에서 잘려 안 보인다(2026-11-06 실측) → 별도 줄로 맨 위에 출력한다
            _wt_warn_line = f"{C_ORANGE}{_wt_warn}{C_RESET}"
    except Exception:
        pass

# GPT 비용
if openai_cost is not None:
    if openai_cost > 1.0:
        parts.append(f"✨ {C_YELLOW}${openai_cost:.2f}{C_RESET}")
    else:
        parts.append(f"✨ {C_DIM}${openai_cost:.2f}{C_RESET}")

# 계정 — 프로파일명(이메일) 형식: 프로파일명만 흰색, 나머지는 DIM
parts.append(f"👤 {account_label(account_email, color=True, is_team_agent=is_team_agent)}")
_acct_notice = account_notice(account_email)
if _acct_notice:
    parts.append(f"{C_YELLOW}{_acct_notice}{C_RESET}")

# 2줄 출력
sep = f" {C_DIM}|{C_RESET} "

# 1줄: 프로젝트 | 모델+버전 | 파이프라인 | 컨텍스트 | 경과시간 | MCP | GPT | 계정
# 2줄: CPU·메모리 | 주간(+소진) | 세션(+소진)
line1 = []
line2 = []

# 세션/주간/GPT를 line2로, 나머지를 line1으로
line1_final = []
openai_part = None
for p in parts:
    if p is session_str or p is weekly_str:
        line2.append(p)
    elif openai_cost is not None and "✨" in p:
        openai_part = p
    else:
        line1_final.append(p)
if openai_part:
    line2.append(openai_part)
# 2줄 맨 앞: 이 세션(팀원은 자기 프로세스)의 CPU·메모리
_cpu_pct, _rss_mb = session_cpu_mem(session_id)
line2.insert(0, fmt_cpu_mem(_cpu_pct, _rss_mb,
                            None if is_team_agent else team_cpu_total(session_id, _cpu_pct, _rss_mb)))

if _wt_warn_line:
    print(_wt_warn_line)
print(sep.join(line1_final))
if line2:
    print(sep.join(line2))
