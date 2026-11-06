# 사이클196 사례 1·5·8 재현 시험 — 사이클 사본 판정기(구판)와 단일 판정기 ac_gate.py 를 같은 상황에 돌려 차이를 확인한다
"""
실행: python3 test_ac_gate_repro.py [-v]
구판 대조: OLD_GATE=<사이클 사본 판정기 경로> 를 주면 구판 재현 케이스(test_old_*)도 돈다(없으면 skip).
  구판은 기록 루트(ROOTS)·증거 기준(BASES)이 코드 상수라 모듈 속성을 임시 경로로 바꿔 돌린다.
"""
import hashlib
import importlib.util
import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import ac_gate  # noqa: E402

OLD = os.environ.get("OLD_GATE")


def _md5(b):
    return hashlib.md5(b).hexdigest()


class Repro(unittest.TestCase):
    def setUp(self):
        self.td = tempfile.TemporaryDirectory()
        t = self.td.name
        self.sd = os.path.join(t, "sess")
        self.cyc = os.path.join(t, "Project", "_tmp_cX")
        self.root = os.path.join(self.cyc, "otest")
        self.sib = os.path.join(t, "Project", "App", "_tmp_cX", "otest", "otest-m-1")
        for d in (os.path.join(self.sd, "plans"), os.path.join(self.root, "otest-1"), self.sib):
            os.makedirs(d)
        self.art = os.path.join(t, "server.bin")
        open(self.art, "wb").write(b"build-1")
        self.crit = {
            "created_at": "2000-01-01T00:00:00+09:00",
            "record_contract": {"root": self.root, "build_sources": {"server": self.art}},
            "criteria": [
                {"id": "AC-001", "batch": 1, "build_axes": ["server"]},
                {"id": "AC-002", "batch": 1},
                {"id": "AC-003", "batch": 1, "na_allowed": True},
            ],
        }
        self._write_crit()

    def tearDown(self):
        self.td.cleanup()

    def _write_crit(self):
        for p in (os.path.join(self.sd, "plans", "acceptance_criteria.json"), os.path.join(self.sd, "acceptance_criteria.json")):
            json.dump(self.crit, open(p, "w"), ensure_ascii=False)

    def _rec(self, path, rows, build=None):
        json.dump({"batch": 1, "build": build or {}, "records": rows}, open(path, "w"), ensure_ascii=False)

    def new(self, ac):
        return ac_gate.judge(ac_gate.Contract(self.sd), ac)

    def old(self, ac):
        spec = importlib.util.spec_from_file_location("old_gate", OLD)
        m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(m)
        m.ROOTS = [self.cyc]
        m.BASES = [self.cyc]
        os.environ["GOAL_SESSION_DIR"] = self.sd
        try:
            out, err = io.StringIO(), io.StringIO()
            with redirect_stdout(out), redirect_stderr(err):
                rc = m.main(["item", ac])
            return rc, out.getvalue() + err.getvalue()
        finally:
            os.environ.pop("GOAL_SESSION_DIR", None)

    # ── 사례 1: 현재 판 ──
    def _case1_setup(self):
        # 리드가 손으로 쓴 current_build.json 은 build-1 에서 멈춰 있다. 그 뒤 재빌드(build-2)가 일어났다.
        json.dump({"server": _md5(b"build-1")}, open(os.path.join(self.sd, "current_build.json"), "w"))
        open(self.art, "wb").write(b"build-2")
        self._rec(os.path.join(self.root, "otest-1", "ac_records_b1.json"),
                  [{"id": "AC-001", "status": "PASS", "evidence": "x"}], build={"server": _md5(b"build-1")})

    def test_new_case1_stale_build_record_rejected(self):
        self._case1_setup()
        rc, msg = self.new("AC-001")
        self.assertEqual(rc, 1, msg)
        self.assertIn("현재 판 아님", msg) if "현재 판 아님" in msg else self.assertIn("FAIL", msg)

    def test_new_case1_current_build_record_accepted_without_state_file(self):
        self._case1_setup()
        os.remove(os.path.join(self.sd, "current_build.json"))
        self._rec(os.path.join(self.root, "otest-1", "ac_records_b1.json"),
                  [{"id": "AC-001", "status": "PASS", "evidence": "x"}], build={"server": _md5(b"build-2")})
        rc, msg = self.new("AC-001")
        self.assertEqual(rc, 0, msg)

    @unittest.skipUnless(OLD, "OLD_GATE 미지정")
    def test_old_case1_stale_state_file_accepts_old_build(self):
        self._case1_setup()
        rc, out = self.old("AC-001")
        self.assertEqual(rc, 0, out)  # 구판: 산출물이 바뀌었는데 옛 판 기록을 PASS 로 받는다(상태 파일이 거짓)

    # ── 사례 5: 규약 밖 위치 · 조건부 표기 ──
    def test_new_case5_sibling_record_undetermined_with_path(self):
        self._rec(os.path.join(self.sib, "ac_records_b1.json"), [{"id": "AC-002", "status": "PASS", "evidence": "x"}])
        with self.assertRaises(ac_gate.Undetermined) as cm:
            self.new("AC-002")
        self.assertIn(self.sib, str(cm.exception))

    @unittest.skipUnless(OLD, "OLD_GATE 미지정")
    def test_old_case5_sibling_record_silently_missing(self):
        self._rec(os.path.join(self.sib, "ac_records_b1.json"), [{"id": "AC-002", "status": "PASS", "evidence": "x"}])
        rc, out = self.old("AC-002")
        self.assertEqual(rc, 1, out)
        self.assertIn("기록 없음", out)  # 구판: 위치가 틀렸다는 신호 없이 "기록 없음"
        self.assertNotIn(self.sib, out)

    def test_new_case5_conditional_pass_rejected(self):
        self._rec(os.path.join(self.root, "otest-1", "ac_records_b1.json"),
                  [{"id": "AC-002", "status": "PASS(조건부)", "evidence": "x"}])
        rc, msg = self.new("AC-002")
        self.assertEqual(rc, 1, msg)
        self.assertIn("형식 위반", msg)

    @unittest.skipUnless(OLD, "OLD_GATE 미지정")
    def test_old_case5_conditional_pass_read_as_pass(self):
        self._rec(os.path.join(self.root, "otest-1", "ac_records_b1.json"),
                  [{"id": "AC-002", "status": "PASS(조건부)", "evidence": "x"}])
        rc, out = self.old("AC-002")
        self.assertEqual(rc, 0, out)  # 구판: 'PASS(조건부)' 를 PASS 로 읽는다

    def test_new_case5_na_with_basis_distinct(self):
        self._rec(os.path.join(self.root, "otest-1", "ac_records_b1.json"),
                  [{"id": "AC-003", "status": "NA", "na_basis": "같은 시각 원문 실행 차집합 0, 캐시 시차", "evidence": "x"}])
        rc, msg = self.new("AC-003")
        self.assertEqual(rc, 0, msg)
        self.assertTrue(msg.startswith("PASS(N/A)"), msg)

    # ── 사례 8: 사이클 고유값이 코드가 아니라 계약에서 온다 — 같은 판정기가 다른 사이클 루트를 그대로 읽는다 ──
    def test_new_case8_same_gate_other_cycle(self):
        other = os.path.join(self.td.name, "Project", "_tmp_cY", "otest")
        os.makedirs(os.path.join(other, "otest-1"))
        self.crit["record_contract"]["root"] = other
        self._write_crit()
        self._rec(os.path.join(other, "otest-1", "ac_records_b1.json"), [{"id": "AC-002", "status": "PASS", "evidence": "x"}])
        rc, msg = self.new("AC-002")
        self.assertEqual(rc, 0, msg)

    @unittest.skipUnless(OLD, "OLD_GATE 미지정")
    def test_old_case8_root_is_code_constant(self):
        spec = importlib.util.spec_from_file_location("old_gate", OLD)
        m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(m)
        self.assertTrue(all("_tmp_c" in r for r in m.ROOTS))  # 구판: 기록 루트가 사이클 번호 박힌 코드 상수


if __name__ == "__main__":
    unittest.main()
