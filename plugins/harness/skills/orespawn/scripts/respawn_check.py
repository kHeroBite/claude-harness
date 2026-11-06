# 팀원별 CPU·메모리·실행 시간·부하를 읽기 전용으로 재고 리스폰(교대) 대상을 판정하는 점검 스크립트
"""orespawn 점검 스크립트.

사용법:
  python3 respawn_check.py --uuid <PIPELINE_UUID> [--team <팀명>] [--json]
                           [--rss-mb 2000] [--cpu-idle 30] [--age-min 90] [--load 50] [--interval 1.0]

판정:
  RESPAWN  RSS(팀원 본체 + MCP 자식 등 프로세스 트리 합계) > --rss-mb, 실행 분 > --age-min, 유휴(isActive=false)인데 CPU% > --cpu-idle 중 하나라도 해당.
           1분 load > --load 이면 측정된 팀원 중 CPU 최대 1명을 사유 'load' 로 추가한다.
  KEEP     위 조건에 해당하지 않음.
  UNKNOWN  측정 실패(프로세스 미발견 등). 교대하지 않는다.
종료 코드: RESPAWN 대상 있음 10, 없음 0, 오류 2.

하는 일은 /proc 읽기뿐이다. 프로세스를 죽이거나 파일을 쓰지 않는다.
측정 함수(_session_tree·_tree_usage·_teammate_ident)는 statusline.py 의 것을 ast 로 골라 실행해 재사용한다
(statusline.py 는 import 하면 본문이 실행되므로 함수 정의만 꺼낸다).
"""
import argparse
import ast
import json
import os
import re
import shlex
import subprocess
import sys
import time

# ── 판정 기본 임계값 ─────────────────────────────────
DEFAULT_RSS_MB = 2000  # 트리 합계(본체 + MCP 자식) 기준. 갓 뜬 팀원도 약 1GB 라 600 은 전원 오탐(2026-11-05 실측)
DEFAULT_CPU_IDLE = 30
DEFAULT_AGE_MIN = 90
DEFAULT_LOAD = 50

RC_NONE, RC_TARGET, RC_ERROR = 0, 10, 2

_UUID_RE = r'[A-Za-z0-9_-]{1,80}'
_NAME_RE = r'[A-Za-z0-9._-]{1,64}'

# statusline.py 에서 가져올 이름
_REUSE_FUNCS = ('_session_tree', '_tree_usage', '_teammate_ident')
_REUSE_CONSTS = ('_TEAM_NAME_RE', '_SID_RE')


# ── 순수 판정 함수 (시험 대상) ───────────────────────
def judge(members, rss_mb=DEFAULT_RSS_MB, cpu_idle=DEFAULT_CPU_IDLE,
          age_min=DEFAULT_AGE_MIN, load_limit=DEFAULT_LOAD, load1=None):
    """측정값 목록을 받아 판정 결과 목록을 돌려준다. 입력은 바꾸지 않는다.

    members 원소: {name, pid, cpu, rss_mb, age_min, is_active, ok}
      ok=False 이거나 rss_mb·age_min 이 None 이면 UNKNOWN.
      is_active: True(바쁨) / False(유휴) / None(모름 — 유휴 CPU 규칙을 적용하지 않음).
    반환 원소: 입력 필드 + verdict(RESPAWN|KEEP|UNKNOWN), reasons(list), busy(bool)
    """
    out = []
    for m in members:
        r = dict(m)
        r['reasons'] = []
        r['busy'] = m.get('is_active') is True
        if not m.get('ok') or m.get('rss_mb') is None or m.get('age_min') is None:
            r['verdict'] = 'UNKNOWN'
            out.append(r)
            continue
        if m['rss_mb'] > rss_mb:
            r['reasons'].append(f"rss>{rss_mb:g}MB(트리 합계, MCP 자식 포함)")
        if m['age_min'] > age_min:
            r['reasons'].append(f"age>{age_min}분")
        cpu = m.get('cpu')
        if m.get('is_active') is False and cpu is not None and cpu > cpu_idle:
            r['reasons'].append(f"idle_cpu>{cpu_idle}%")
        r['verdict'] = 'RESPAWN' if r['reasons'] else 'KEEP'
        out.append(r)
    # load 규칙: 측정된 팀원 중 CPU 최대 1명
    if load1 is not None and load1 > load_limit:
        cands = [r for r in out if r['verdict'] != 'UNKNOWN' and r.get('cpu') is not None]
        if cands:
            top = max(cands, key=lambda r: r['cpu'])
            top['reasons'].append('load')
            top['verdict'] = 'RESPAWN'
    return out


# ── statusline 측정 함수 재사용 ──────────────────────
def find_statusline():
    """statusline.py 경로를 찾는다. 순서: 환경변수 → 저장소 상대 → settings.json statusLine → $HOME 얕은 find."""
    env = os.environ.get('RESPAWN_STATUSLINE')
    if env and os.path.isfile(env):
        return env
    here = os.path.dirname(os.path.abspath(__file__))
    # <저장소>/.claude/skills/orespawn/scripts → <저장소>/script/statusline.py
    cand = os.path.normpath(os.path.join(here, '..', '..', '..', '..', 'script', 'statusline.py'))
    if os.path.isfile(cand):
        return cand
    cfg = os.environ.get('CLAUDE_CONFIG_DIR') or os.path.expanduser('~/.claude')
    for sp in (os.path.join(cfg, 'settings.json'), os.path.expanduser('~/.claude/settings.json')):
        try:
            with open(sp) as f:
                cmd = (json.load(f).get('statusLine') or {}).get('command') or ''
            for tok in shlex.split(cmd):
                if tok.endswith('statusline.py') and os.path.isfile(tok):
                    return tok
        except Exception:
            pass
    try:
        r = subprocess.run(['find', os.path.expanduser('~'), '-maxdepth', '4', '-name', 'statusline.py',
                            '-not', '-path', '*/node_modules/*'],
                           capture_output=True, text=True, timeout=20)
        for line in r.stdout.splitlines():
            if line.strip():
                return line.strip()
    except Exception:
        pass
    return None


def load_measure_funcs(path):
    """statusline.py 에서 측정 함수·상수 정의만 골라 실행한 네임스페이스를 돌려준다. 실패하면 None."""
    try:
        with open(path, encoding='utf-8') as f:
            tree = ast.parse(f.read(), path)
        keep = []
        for node in tree.body:
            if isinstance(node, ast.FunctionDef) and node.name in _REUSE_FUNCS:
                keep.append(node)
            elif isinstance(node, ast.Assign) and any(
                    isinstance(t, ast.Name) and t.id in _REUSE_CONSTS for t in node.targets):
                keep.append(node)
        ns = {'os': os, 're': re, 'json': json, 'time': time}
        exec(compile(ast.Module(body=keep, type_ignores=[]), path, 'exec'), ns)
        if all(n in ns for n in _REUSE_FUNCS):
            return ns
    except Exception:
        pass
    return None


# ── 팀원 목록 ────────────────────────────────────────
def cfg_dir():
    return os.environ.get('CLAUDE_CONFIG_DIR') or os.path.expanduser('~/.claude')


def team_members(uuid, team):
    """자기 소유 팀의 팀원 목록 [(이름, isActive)] 를 돌려준다. 소유가 아니면 예외.
    config.json members(in-process 제외) ∪ 자기 session-env/<UUID>/agents/ 파일명."""
    base = cfg_dir()
    with open(os.path.join(base, 'teams', team, 'config.json')) as f:
        conf = json.load(f)
    if conf.get('leadSessionId') != uuid:
        raise PermissionError(f"팀 {team} 의 leadSessionId 가 {uuid} 와 다르다(다른 세션 팀은 대상이 아니다)")
    seen, out = set(), []
    for m in conf.get('members') or []:
        if not isinstance(m, dict):
            continue
        name = m.get('name') or ''
        if m.get('backendType') == 'in-process' or not re.fullmatch(_NAME_RE, name) or name in seen:
            continue
        act = m.get('isActive')
        if isinstance(act, str):
            act = {'true': True, 'false': False}.get(act.lower())
        seen.add(name)
        out.append((name, act if isinstance(act, bool) else None))
    adir = os.path.join(base, 'session-env', uuid, 'agents')
    try:
        for name in sorted(os.listdir(adir)):
            if re.fullmatch(_NAME_RE, name) and name not in seen and name != 'team-lead':
                seen.add(name)
                out.append((name, None))
    except OSError:
        pass
    return out


# ── 측정 ────────────────────────────────────────────
def find_member_pids(ns, uuid, team, names, proc='/proc'):
    """argv 의 --agent-id 이름@팀 과 --parent-session-id == uuid 가 맞는 본체 pid 를 찾는다.
    다른 세션 팀원은 parent-session-id 가 달라 걸러진다. {이름: pid}"""
    want = set(names)
    found = {}
    for d in os.listdir(proc):
        if not d.isdigit():
            continue
        pid = int(d)
        ident = ns['_teammate_ident'](pid, proc)
        if not ident:
            continue
        name, t, lead = ident
        if t == team and lead == uuid and name in want:
            # 같은 이름이 둘이면 더 늦게 뜬(큰 starttime) 쪽을 쓴다
            if name not in found or _starttime(found[name], proc) < _starttime(pid, proc):
                found[name] = pid
    return found


def _starttime(pid, proc='/proc'):
    try:
        with open(f'{proc}/{pid}/stat') as f:
            st = f.read()
        return int(st[st.rfind(')') + 2:].split()[19])
    except Exception:
        return -1


def measure(ns, pids, interval=1.0, proc='/proc'):
    """{이름: pid} → {이름: {pid, cpu, rss_mb, age_min, ok}}. CPU 는 interval 초 틱 차분(1코어=100)."""
    clk = os.sysconf('SC_CLK_TCK')
    try:
        with open(f'{proc}/uptime') as f:
            uptime = float(f.read().split()[0])
    except Exception:
        uptime = None
    t0, first = time.time(), {}
    for name, pid in pids.items():
        tree = ns['_session_tree'](pid, proc)
        first[name] = ns['_tree_usage'](tree, proc)[0]
    time.sleep(max(0.1, interval))
    gap = time.time() - t0
    out = {}
    for name, pid in pids.items():
        rec = {'pid': pid, 'cpu': None, 'rss_mb': None, 'age_min': None, 'ok': False}
        if not os.path.exists(f'{proc}/{pid}'):
            out[name] = rec
            continue
        ticks, rss_kb = ns['_tree_usage'](ns['_session_tree'](pid, proc), proc)
        st = _starttime(pid, proc)
        if rss_kb <= 0 or st < 0 or uptime is None:
            out[name] = rec
            continue
        rec['cpu'] = round(max(0.0, (ticks - first[name]) / clk / gap * 100.0), 1)
        rec['rss_mb'] = round(rss_kb / 1024.0, 1)
        rec['age_min'] = round((uptime - st / clk) / 60.0, 1)
        rec['ok'] = True
        out[name] = rec
    return out


# ── 출력 ────────────────────────────────────────────
def fmt_table(rows, load1, args):
    lines = [f"load1={load1:.2f} (기준 {args.load}) | 임계값 rss>{args.rss_mb:g}MB(트리 합계) age>{args.age_min}분 "
             f"idle_cpu>{args.cpu_idle}%",
             f"{'이름':<16} {'pid':>8} {'CPU%':>7} {'RSS_MB':>8} {'실행분':>7} {'isActive':>8} {'판정':<8} 사유"]
    for r in rows:
        def v(x):
            return '-' if x is None else str(x)
        lines.append(f"{r['name']:<16} {v(r.get('pid')):>8} {v(r.get('cpu')):>7} {v(r.get('rss_mb')):>8} "
                     f"{v(r.get('age_min')):>7} {v(r.get('is_active')):>8} {r['verdict']:<8} "
                     f"{','.join(r['reasons']) or '-'}")
    n = sum(1 for r in rows if r['verdict'] == 'RESPAWN')
    lines.append(f"RESPAWN 대상 {n}명" if n else "RESPAWN 대상 없음")
    return '\n'.join(lines)


def main(argv=None):
    ap = argparse.ArgumentParser(description='orespawn 팀원 리스폰 대상 점검(읽기 전용)')
    ap.add_argument('--uuid', required=True)
    ap.add_argument('--team')
    ap.add_argument('--json', action='store_true')
    ap.add_argument('--rss-mb', type=float, default=DEFAULT_RSS_MB)
    ap.add_argument('--cpu-idle', type=float, default=DEFAULT_CPU_IDLE)
    ap.add_argument('--age-min', type=float, default=DEFAULT_AGE_MIN)
    ap.add_argument('--load', type=float, default=DEFAULT_LOAD)
    ap.add_argument('--interval', type=float, default=1.0, help='CPU 샘플 간격(초)')
    args = ap.parse_args(argv)
    try:
        if not re.fullmatch(_UUID_RE, args.uuid):
            raise ValueError('uuid 형식 오류')
        team = args.team
        if not team:
            with open(os.path.join(cfg_dir(), 'session-env', args.uuid, 'team_name')) as f:
                team = f.read().strip()
        if not re.fullmatch(_NAME_RE, team or ''):
            raise ValueError(f'팀명 형식 오류: {team!r}')
        sl = find_statusline()
        ns = load_measure_funcs(sl) if sl else None
        if ns is None:
            raise RuntimeError(f'statusline 측정 함수를 불러오지 못했다: {sl}')
        members = team_members(args.uuid, team)
        pids = find_member_pids(ns, args.uuid, team, [n for n, _ in members])
        meas = measure(ns, pids, args.interval)
        rows_in = []
        for name, act in members:
            m = meas.get(name) or {'pid': None, 'cpu': None, 'rss_mb': None, 'age_min': None, 'ok': False}
            rows_in.append(dict(m, name=name, is_active=act))
        load1 = os.getloadavg()[0]
    except Exception as e:
        print(f'오류: {e}', file=sys.stderr)
        return RC_ERROR
    rows = judge(rows_in, args.rss_mb, args.cpu_idle, args.age_min, args.load, load1)
    if args.json:
        print(json.dumps({'team': team, 'load1': round(load1, 2), 'statusline': sl,
                          'thresholds': {'rss_mb': args.rss_mb, 'cpu_idle': args.cpu_idle,
                                         'age_min': args.age_min, 'load': args.load},
                          'members': rows}, ensure_ascii=False, indent=1))
    else:
        print(fmt_table(rows, load1, args))
    return RC_TARGET if any(r['verdict'] == 'RESPAWN' for r in rows) else RC_NONE


if __name__ == '__main__':
    sys.exit(main())
