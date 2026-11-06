# F-CRUD-1 판정기(verify_crud_executed.py)의 git 호출 캐시가 호출 수만 줄이고 판정은 바꾸지 않는지 확인하는 시험
"""사이클181 항목 B 시험.

임시 바깥 저장소 + 중첩 저장소에 파일 15개(3 디렉터리)를 만들고,
_GIT_CACHE_ENABLED=False(무캐시)와 True(캐시)로 같은 판정을 돌려
  (1) scan_db_contact 반환값·출력이 같고,
  (2) 파일별 _owning_root·_diff_db_hits_git 판정이 같으며,
  (3) git 호출 수가 cached*2 <= uncached 인지 본다.
마지막에 `GIT_CALLS cached=X uncached=Y` 1줄을 출력한다(c181_gate.sh run B1 이 읽는다).
"""
import contextlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "verify_crud_executed.py")
sys.path.insert(0, os.path.dirname(SCRIPT))
import verify_crud_executed as v  # noqa: E402
sys.path.pop(0)

_REAL_RUN = subprocess.run
_GIT = ["git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false",
        "-c", "core.autocrlf=false"]


def _git(cwd, *args):
    _REAL_RUN(_GIT + list(args), cwd=cwd, check=True, capture_output=True)


def _write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as fp:
        fp.write(text)


def _body(tag, n=30):
    return "".join(f"line_{tag}_{i} = {i}\n" for i in range(n))


class _Counter:
    """subprocess.run 을 감싸 git 호출 수를 센다."""

    def __init__(self):
        self.n = 0

    def __call__(self, cmd, *a, **kw):
        if isinstance(cmd, (list, tuple)) and cmd and cmd[0] == "git":
            self.n += 1
        return _REAL_RUN(cmd, *a, **kw)


class GitCacheTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="c181_gitcache_")
        cls.repo = os.path.join(cls.tmp, "outer")
        cls.sess = os.path.join(cls.tmp, "sess")
        os.makedirs(os.path.join(cls.sess, "evidence"))
        r = cls.repo
        os.makedirs(r)
        _git(r, "init", "-q")
        tracked = ["d1/a.py", "d1/b.py", "d1/c.py", "d1/h.py", "d1/i.py", "d1/[x].py",
                   "d2/Case.py", "d2/e.py", "d2/f.py", "d3/back\\slash.py", "d3/olddir/x.txt",
                   "d3/olddir/y.txt"]
        for rel in tracked:
            _write(os.path.join(r, rel), _body(rel.replace("/", "_")))
        _git(r, "add", "--", *tracked)
        _git(r, "commit", "-q", "-m", "base")
        # 중첩 저장소(바깥 인덱스에는 넣지 않는다 — gitlink 아님)
        cls.nested = os.path.join(r, "d3", "nested")
        os.makedirs(cls.nested)
        _git(cls.nested, "init", "-q")
        _write(os.path.join(cls.nested, "n1.py"), _body("n1"))
        _git(cls.nested, "add", "--", "n1.py")
        _git(cls.nested, "commit", "-q", "-m", "nbase")

        time.sleep(1.2)
        start = int(time.time())
        _write(os.path.join(cls.sess, "pipeline_start_time"), f"{start}\n")
        _write(os.path.join(cls.sess, "evidence", "ok_started"), f"{start}\n")
        time.sleep(1.1)

        def p(rel):
            return os.path.join(r, rel)
        # 변경: 무변경(a,h) / 비DB 변경(b,i,e) / DB 문자열 추가(c,f) / 특수문자 이름([x], back\slash)
        _write(p("d1/b.py"), _body("d1_b.py") + "extra = 1\n")
        _write(p("d1/i.py"), "head = 0\n" + _body("d1_i.py"))
        _write(p("d1/c.py"), _body("d1_c.py") + 'Q = "INSERT INTO t VALUES (1)"\n')
        _write(p("d1/[x].py"), _body("d1_[x].py") + "z = 2\n")
        _write(p("d2/e.py"), _body("d2_e.py")[:-10] + "\n")
        _write(p("d2/f.py"), _body("d2_f.py") + 'S = "SELECT a FROM b"\n')
        _write(p("d3/back\\slash.py"), _body("d3_back\\slash.py") + "w = 3\n")
        # 대소문자만 다른 untracked 파일(tracked 는 Case.py)
        _write(p("d2/case.py"), _body("lower"))
        # untracked 바깥 파일
        _write(p("d2/u.py"), _body("u"))
        # R4 디렉터리 rel: base·인덱스에서는 디렉터리(d3/olddir/*), 작업트리에서는 파일
        shutil.rmtree(p("d3/olddir"))
        _write(p("d3/olddir"), "now a file\n")
        # 중첩 저장소: 추적 파일 변경 + untracked 파일
        _write(os.path.join(cls.nested, "n1.py"), _body("n1") + "nn = 1\n")
        _write(os.path.join(cls.nested, "n2.py"), _body("n2"))

        cls.files = [p(x) for x in (
            "d1/a.py", "d1/b.py", "d1/c.py", "d1/h.py", "d1/i.py", "d1/[x].py",
            "d2/Case.py", "d2/case.py", "d2/e.py", "d2/f.py", "d2/u.py",
            "d3/back\\slash.py", "d3/olddir")]
        cls.files += [os.path.join(cls.nested, "n1.py"), os.path.join(cls.nested, "n2.py")]
        cls.fa = os.path.join(cls.sess, "file_assignment.json")
        with open(cls.fa, "w", encoding="utf-8") as fp:
            json.dump({"agents": {"odev-1": {"files": cls.files}}}, fp)
        cls.start = start

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def _run(self, enabled, fn):
        counter = _Counter()
        out = io.StringIO()
        old = getattr(v, "_GIT_CACHE_ENABLED", None)
        v._GIT_CACHE_ENABLED = enabled
        v._START_TRUST_CACHE.clear()
        try:
            with mock.patch("subprocess.run", counter), contextlib.redirect_stdout(out):
                result = fn()
        finally:
            v._GIT_CACHE_ENABLED = old
        return result, out.getvalue(), counter.n

    def _per_file(self):
        rows, base_cache = [], {}
        for path in self.files:
            own = v._owning_root(os.path.abspath(path), self.start, base_cache)
            if os.path.isfile(path):
                with open(path, "r", encoding="utf-8") as fp:
                    content = fp.read()
                diff = v._diff_db_hits_git(path, content, self.start, base_cache)
            else:
                diff = None
            rows.append((path, own, diff))
        return rows

    def test_1_scan_same_and_fewer_calls(self):
        scan = lambda: v.scan_db_contact(self.fa)  # noqa: E731
        res_u, out_u, n_u = self._run(False, scan)
        res_c, out_c, n_c = self._run(True, scan)
        self.assertEqual(res_u, res_c)
        self.assertEqual(out_u, out_c)
        # 픽스처가 의도대로 판정 축을 고루 밟는지(시험 자체의 유효성)
        clean, detail = res_c
        self.assertFalse(clean)
        self.assertEqual(detail.get("reason"), "unreadable")
        print(f"\nGIT_CALLS cached={n_c} uncached={n_u}")
        self.assertGreater(n_u, 0)
        self.assertLessEqual(n_c * 2, n_u)

    def test_2_per_file_judgement_same(self):
        rows_u, _, n_u = self._run(False, self._per_file)
        rows_c, _, n_c = self._run(True, self._per_file)
        self.assertEqual(rows_u, rows_c)
        print(f"\nPER_FILE_GIT_CALLS cached={n_c} uncached={n_u}")
        by = {os.path.relpath(p, self.repo): (own, diff) for p, own, diff in rows_c}
        self.assertEqual(by["d1/c.py"][1][0], "hit")
        self.assertEqual(by["d1/a.py"][1], ("clean", None))
        self.assertEqual(by["d2/u.py"][0][0], "full")
        self.assertEqual(by["d2/case.py"][0][0], "full")
        self.assertEqual(by["d2/Case.py"][0][0], "root")
        self.assertEqual(by["d1/[x].py"][0][0], "root")
        self.assertEqual(by["d3/back\\slash.py"][0][0], "root")
        n1 = by[os.path.join("d3", "nested", "n1.py")][0]
        self.assertEqual((n1[0], n1[1]), ("root", self.nested))
        self.assertEqual(by[os.path.join("d3", "nested", "n2.py")][0][0], "full")

    def test_3_directory_rel(self):
        """R4: rel 이 인덱스·base 에서 디렉터리인 경우 캐시·무캐시 판정이 같다."""
        path = os.path.join(self.repo, "d3", "olddir")

        def judge():
            base_cache = {}
            own = v._owning_root(path, self.start, base_cache)
            diff = v._diff_db_hits_git(path, "now a file\n", self.start, base_cache)
            return own, diff
        (own_u, diff_u), _, _ = self._run(False, judge)
        (own_c, diff_c), _, _ = self._run(True, judge)
        self.assertEqual((own_u, diff_u), (own_c, diff_c))
        self.assertEqual(own_c, ("root", self.repo, "d3/olddir"))
        self.assertEqual(diff_c[0], "unreadable")
        self.assertIn("blob 아님", diff_c[1])


if __name__ == "__main__":
    unittest.main(verbosity=1)
