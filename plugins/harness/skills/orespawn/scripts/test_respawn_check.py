# respawn_check.py 의 순수 판정 함수 단위 시험과 실제 세션 dry 실행 1회
"""사용법: python3 -B test_respawn_check.py [--uuid <PIPELINE_UUID>]
--uuid 를 주거나 PIPELINE_UUID 환경변수가 있으면 마지막에 그 세션으로 dry 실행 1회(표 출력)를 한다."""
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import respawn_check as rc  # noqa: E402

PASS = FAIL = 0
RSS_REASON = 'rss>2000MB(트리 합계, MCP 자식 포함)'


def check(label, cond):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"PASS {label}")
    else:
        FAIL += 1
        print(f"FAIL {label}")


def m(name, cpu=1.0, rss=100.0, age=10.0, active=True, ok=True, pid=1):
    return {'name': name, 'pid': pid, 'cpu': cpu, 'rss_mb': rss, 'age_min': age, 'is_active': active, 'ok': ok}


def one(member, **kw):
    return rc.judge([member], **kw)[0]


def unit():
    # RSS 경계: 같음은 KEEP, 초과는 RESPAWN
    check('기본 rss 기준 2000', rc.DEFAULT_RSS_MB == 2000)
    check('갓 뜬 팀원 1GB KEEP', one(m('a', rss=1096))['verdict'] == 'KEEP')
    check('rss 같음 KEEP', one(m('a', rss=2000))['verdict'] == 'KEEP')
    r = one(m('a', rss=2000.1))
    check('rss 초과 RESPAWN', r['verdict'] == 'RESPAWN' and r['reasons'] == [RSS_REASON])
    # 실행 시간 경계
    check('age 같음 KEEP', one(m('a', age=90))['verdict'] == 'KEEP')
    check('age 초과 RESPAWN', one(m('a', age=90.5))['verdict'] == 'RESPAWN')
    # 유휴 CPU 경계
    check('유휴 cpu 같음 KEEP', one(m('a', cpu=30, active=False))['verdict'] == 'KEEP')
    r = one(m('a', cpu=31, active=False))
    check('유휴 cpu 초과 RESPAWN', r['verdict'] == 'RESPAWN' and r['reasons'] == ['idle_cpu>30%'])
    # 바쁨이면 CPU 가 높아도 유휴 규칙 미적용
    r = one(m('a', cpu=300, active=True))
    check('바쁨 고CPU KEEP', r['verdict'] == 'KEEP' and r['busy'] is True)
    check('isActive 모름 고CPU KEEP', one(m('a', cpu=300, active=None))['verdict'] == 'KEEP')
    check('유휴 busy=False', one(m('a', active=False))['busy'] is False)
    # 사유 복수
    r = one(m('a', rss=2500, age=200, cpu=50, active=False))
    check('사유 3개 동시', r['reasons'] == [RSS_REASON, 'age>90분', 'idle_cpu>30%'])
    # 임계값 옵션 반영
    check('rss 임계값 옵션', one(m('a', rss=2500), rss_mb=3000)['verdict'] == 'KEEP')
    check('rss 임계값 옵션 사유', one(m('a', rss=900), rss_mb=600)['reasons'] == ['rss>600MB(트리 합계, MCP 자식 포함)'])
    # UNKNOWN
    check('측정 실패 UNKNOWN', one(m('a', ok=False))['verdict'] == 'UNKNOWN')
    check('rss None UNKNOWN', one(m('a', rss=None))['verdict'] == 'UNKNOWN')
    # load 후보: 같음이면 미선정, 초과면 CPU 최대 1명
    ms = [m('a', cpu=5), m('b', cpu=80), m('c', cpu=20)]
    out = rc.judge(ms, load1=50)
    check('load 같음 후보 없음', all(r['verdict'] == 'KEEP' for r in out))
    out = rc.judge(ms, load1=50.1)
    check('load 초과 CPU 최대 1명', [r['name'] for r in out if r['verdict'] == 'RESPAWN'] == ['b'])
    check('load 사유 표시', [r for r in out if r['name'] == 'b'][0]['reasons'] == ['load'])
    # load 후보는 UNKNOWN 제외
    out = rc.judge([m('a', cpu=5), m('x', cpu=999, ok=False)], load1=99)
    check('load 후보 UNKNOWN 제외', out[0]['verdict'] == 'RESPAWN' and out[1]['verdict'] == 'UNKNOWN')
    # 이미 RESPAWN 인 팀원이 최대 CPU 면 사유만 추가
    out = rc.judge([m('a', cpu=90, rss=2500), m('b', cpu=1)], load1=99)
    check('load 사유 병합', out[0]['reasons'] == [RSS_REASON, 'load'] and out[1]['verdict'] == 'KEEP')
    # 전원 UNKNOWN + 고부하면 대상 없음
    out = rc.judge([m('a', ok=False)], load1=99)
    check('전원 UNKNOWN 고부하 대상 없음', out[0]['verdict'] == 'UNKNOWN')
    # 입력 불변
    src = m('a', rss=900)
    rc.judge([src])
    check('입력 불변', 'verdict' not in src)


def dry(uuid):
    script = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'respawn_check.py')
    p = subprocess.run([sys.executable, '-B', script, '--uuid', uuid], capture_output=True, text=True, timeout=60)
    print('--- dry 실행 (실제 세션, 읽기 전용) ---')
    print(p.stdout.rstrip())
    if p.stderr.strip():
        print(p.stderr.rstrip())
    print(f'rc={p.returncode}')
    check('dry 실행 rc 는 0 또는 10', p.returncode in (0, 10))


if __name__ == '__main__':
    unit()
    uuid = os.environ.get('PIPELINE_UUID')
    if '--uuid' in sys.argv:
        uuid = sys.argv[sys.argv.index('--uuid') + 1]
    if uuid:
        dry(uuid)
    print(f'PASS={PASS} FAIL={FAIL}')
    sys.exit(1 if FAIL else 0)
