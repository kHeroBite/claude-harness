#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Claude Code 커스텀 Statusline v4
표시: 프로젝트명 | Git | 모델+버전 | 파이프라인 | 세션 | 주간 | 컨텍스트 | 토큰델타 | 경과시간 | 소진속도 | GPT비용 | 계정
"""
import sys, json, io, os, time, subprocess, glob

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

STATE_FILE = os.path.expanduser('~/.claude/.statusline_state.json')

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

def fmt_remaining(resets_at, thresholds=None):
    """resets_at(unix epoch) → -3日13時 형식. thresholds: (h1,h2,h3) 색상 경계."""
    if not resets_at:
        return None
    diff = resets_at - time.time()
    if diff <= 0:
        return f"{C_RED}만료{C_RESET}"
    h = int(diff // 3600)
    m = int((diff % 3600) // 60)
    if h >= 24:
        d, rh = h // 24, h % 24
        s = f"-{d}日{rh}時"
    else:
        s = f"-{h}時{m}分"
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
    """잔량 기반 5단계 색상: 회색→녹→노랑→주황→핑크."""
    if remaining > 75:
        return C_DIM
    elif remaining > 50:
        return C_GREEN
    elif remaining > 25:
        return C_YELLOW
    elif remaining >= 10:
        return C_ORANGE
    else:
        return C_PINK

def dot_bar(remaining_pct):
    """도트 바: 채움(•)은 5단계 고유색, 빈(◦)은 회색."""
    if remaining_pct is None:
        return f"{C_GREEN}••••{C_RESET}"
    p = float(remaining_pct)
    if p > 75:
        return f"{C_GREEN}••••{C_RESET}"
    elif p > 50:
        return f"{C_GREEN}•••{C_DIM}◦{C_RESET}"
    elif p > 25:
        return f"{C_YELLOW}••{C_DIM}◦◦{C_RESET}"
    elif p >= 10:
        return f"{C_ORANGE}•{C_DIM}◦◦◦{C_RESET}"
    else:
        return f"{C_PINK}◦◦◦◦{C_RESET}"

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

# ── 파이프라인 상태 ───────────────────────────────────

def get_pipeline_info(session_id=None):
    """session-env/{UUID}에서 파이프라인 상태 + 진입 티어 읽기."""
    base_dir = os.path.expanduser('~/.claude/session-env')

    def _read_state(env_dir):
        """특정 env_dir에서 state, tier를 읽는다."""
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
            if cls in ('O1','O2','O3','O4','O5'):
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
        return tier, state

    # session_id 기반으로만 조회 (새 세션은 항상 IDLE)
    if session_id:
        env_dir = os.path.join(base_dir, session_id)
        if os.path.isdir(env_dir):
            tier, state = _read_state(env_dir)
            return tier, state

    return None, "IDLE"

def color_pipeline_display(tier, state):
    """파이프라인 상태 표시."""
    state_colors = {
        'IDLE': C_WHITE, 'OK': C_ORANGE, 'PLAN': C_BLUE,
        'DEV': C_GREEN, 'TEST': C_GOLD, 'DONE': C_PURPLE,
        'FINISH': C_SKY, 'OA': C_PINK,
    }
    tier_colors = {
        'O1': C_WHITE, 'O2': C_GREEN, 'O3': C_YELLOW,
        'O4': C_ORANGE, 'O5': C_PINK, 'OK': C_CYAN,
    }
    sc = state_colors.get(state, C_WHITE)
    if state == "IDLE":
        return f"{C_WHITE}IDLE{C_RESET}"
    if tier:
        tc = tier_colors.get(tier, C_WHITE)
        if tier == "OK" and state == "OK":
            # /ok 진입 직후 — tier 미확정: OK:O
            return f"{C_CYAN}OK{C_RESET}{C_DIM}:{C_RESET}{C_ORANGE}O{C_RESET}"
        elif tier == "OK":
            # /ok 진입했지만 classification 아직 미확정인 상태에서 state가 변경됨
            return f"{C_CYAN}OK{C_RESET}{C_DIM}:{C_RESET}{sc}{state}{C_RESET}"
        else:
            # O1~O5 확정: O4:DEV 형식
            return f"{tc}{tier}{C_RESET}{C_DIM}:{C_RESET}{sc}{state}{C_RESET}"
    return f"{sc}{state}{C_RESET}"

# ── 소진 속도 ─────────────────────────────────────────

def calc_burn_rate(current_pct, resets_at, label, prev_state, window_hours):
    """소진 속도 계산. window_hours: 5 또는 168(7일)."""
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
    # 만료 시점 예상 사용률
    projected = used + burn_rate * time_left_h
    if projected >= 100:
        proj_str = f"{C_PINK}⛔ {projected:.0f}%{C_RESET}"
    elif projected >= 90:
        proj_str = f"{C_ORANGE}⚠ {projected:.0f}%{C_RESET}"
    elif projected >= 80:
        proj_str = f"{C_YELLOW}⚡ {projected:.0f}%{C_RESET}"
    else:
        proj_str = f"{C_DIM}{projected:.0f}%{C_RESET}"
    return f", {c}{burn_rate:.1f}%/h{C_RESET}:{proj_str}"

# ── MCP 서버 상태 ─────────────────────────────────────

MCP_CACHE_FILE = os.path.expanduser('~/.claude/.mcp_status_cache')
MCP_CACHE_TTL = 10  # 초

def get_mcp_status(project_dir=None):
    """MCP 서버 상태 확인 (10초 캐시)."""
    # 캐시 확인
    try:
        if os.path.exists(MCP_CACHE_FILE):
            mtime = os.path.getmtime(MCP_CACHE_FILE)
            if time.time() - mtime < MCP_CACHE_TTL:
                with open(MCP_CACHE_FILE, 'r') as f:
                    return json.load(f)
    except:
        pass
    # .mcp.json에서 서버 목록 읽기 (우선순위: ~/.claude > ~ > cwd > CLAUDE_PROJECT_DIR)
    _candidates = [
        os.path.expanduser('~/.claude/.mcp.json'),
        os.path.expanduser('~/.mcp.json'),
    ]
    # stdin JSON의 project_dir 우선
    if project_dir:
        _candidates.append(os.path.join(project_dir, '.mcp.json'))
    _proj = os.environ.get('CLAUDE_PROJECT_DIR', '')
    if _proj:
        _candidates.append(os.path.join(_proj, '.mcp.json'))
    try:
        _cwd = os.getcwd()
        _candidates.append(os.path.join(_cwd, '.mcp.json'))
    except:
        pass
    mcp_path = next((p for p in _candidates if os.path.exists(p)), None)
    servers = {}
    if mcp_path:
        try:
            with open(mcp_path, 'r') as f:
                cfg = json.load(f)
            for name, conf in cfg.get('mcpServers', {}).items():
                cmd = conf.get('command', '')
                args = ' '.join(conf.get('args', []))
                search = f"{cmd} {args}".strip()
                try:
                    result = subprocess.run(
                        ['pgrep', '-f', search[:60]],
                        capture_output=True, text=True, timeout=2,
                        stdin=subprocess.DEVNULL
                    )
                    servers[name] = result.returncode == 0
                except:
                    servers[name] = False
        except:
            pass
    # plugin 방식 MCP 서버 감지 (settings.json의 plugins 항목)
    try:
        settings_path = os.path.expanduser('~/.claude/settings.json')
        if os.path.exists(settings_path):
            with open(settings_path, 'r') as f:
                settings = json.load(f)
            # MCP 기능을 제공하는 plugin만 포함 (serena 등)
            MCP_PLUGINS = {'serena'}
            for plugin_key, enabled in settings.get('enabledPlugins', {}).items():
                if enabled:
                    plugin_name = plugin_key.split('@')[0]
                    if plugin_name in MCP_PLUGINS:
                        display_name = f"p:{plugin_name}"
                        # plugin은 Claude Code 내부 관리 — 항상 alive
                        servers[display_name] = True
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
        os.path.expanduser('~/.claude/openai_cost.txt'),
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

def get_account_email(_session_id=None):
    creds_path = os.path.expanduser('~/.claude/.credentials.json')
    try:
        cache = os.path.expanduser('~/.claude/.account_email_cache')
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
project_name = os.path.basename(project_dir) if project_dir else 'Unknown'



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

# 소진 속도 (먼저 계산)
burn_5h = calc_burn_rate(five_h_pct, five_h_resets, '5h', prev_state, 5)
burn_7d = calc_burn_rate(seven_d_pct, seven_d_resets, '7d', prev_state, 168)

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

# 파이프라인
session_id = data.get('session_id', '')
pipeline_tier, pipeline_state = get_pipeline_info(session_id)
pipeline_str = color_pipeline_display(pipeline_tier, pipeline_state)

# 상태 저장
save_state(prev_state)

# ── 출력 (Powerline 스타일) ───────────────────────────

parts = []

# 프로젝트
parts.append(f"🏠 {C_CYAN}{project_name}{C_RESET}")

# 모델 + 버전
ver_str = f" {C_DIM}v{version}{C_RESET}" if version else ""
parts.append(f"🤖 {model_name}{ver_str}")

# 파이프라인
parts.append(pipeline_str)

# 세션 + 주간
parts.append(session_str)
if weekly_str:
    parts.append(weekly_str)

# 컨텍스트
parts.append(context_str)

# 세션 경과 시간
if duration_str:
    parts.append(f"🏃 {C_DIM}{duration_str}{C_RESET}")



# MCP 서버 상태
mcp_servers = get_mcp_status(project_dir)
if mcp_servers:
    total = len(mcp_servers)
    alive = sum(1 for v in mcp_servers.values() if v)
    dead = total - alive
    if dead == 0:
        parts.append(f"{C_DIM}MCP {alive}/{total}{C_RESET}")
    elif alive == 0:
        parts.append(f"{C_RED}MCP 0/{total} ✗{dead}{C_RESET}")
    else:
        down = [n for n, v in mcp_servers.items() if not v]
        parts.append(f"{C_ORANGE}MCP {alive}/{total} ✗{dead}({','.join(down)}){C_RESET}")

# GPT 비용
if openai_cost is not None:
    if openai_cost > 1.0:
        parts.append(f"✨ {C_YELLOW}${openai_cost:.2f}{C_RESET}")
    else:
        parts.append(f"✨ {C_DIM}${openai_cost:.2f}{C_RESET}")

# 계정
if account_email:
    parts.append(f"👤 {C_DIM}{account_email}{C_RESET}")

# 2줄 출력
sep = f" {C_DIM}|{C_RESET} "

# 1줄: 프로젝트 | 모델+버전 | 파이프라인 | 컨텍스트 | 경과시간 | MCP | GPT | 계정
# 2줄: 세션(+소진) | 주간(+소진)
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

print(sep.join(line1_final))
if line2:
    print(sep.join(line2))

# ── 3줄: 실행 중인 데몬 (있을 때만 출력) ─────────────
def get_running_daemons():
    """PID 파일을 동적 glob으로 탐색 → 살아있는 데몬 목록 반환.
    하드코딩 목록 없음 — 새 데몬이 PID 파일만 추가하면 자동 표시."""
    pid_patterns = [
        os.path.expanduser('~/.claude/session-env/*/*.pid'),
        '/tmp/*.pid',
    ]
    found = {}
    for pattern in pid_patterns:
        for pid_file in glob.glob(pattern):
            name = os.path.basename(pid_file).replace('.pid', '')
            if name in found:
                continue
            try:
                with open(pid_file, 'r') as f:
                    pid = int(f.read().strip())
                # /proc/{pid}/status 존재 여부로 생존 확인 (subprocess 금지)
                if os.path.exists(f'/proc/{pid}/status'):
                    found[name] = pid
                else:
                    # PID 파일은 있지만 프로세스 없음 → stale
                    pass
            except (ValueError, OSError):
                pass
    return found

daemons = get_running_daemons()
if daemons:
    daemon_parts = []
    for name in sorted(daemons.keys()):
        daemon_parts.append(f"{C_GREEN}●{C_RESET} {C_DIM}{name}{C_RESET}")
    print(f"🔧 {C_DIM}Daemons:{C_RESET} " + f"  ".join(daemon_parts))
