# --emit-from-goal 의 --before-stage 기본값(세션 state 기반)과 deferred 기록을 검증하는 단위 시험
"""사이클182 항목3(L-609) 시험.

임시 CLAUDE_CONFIG_DIR + hooks 심볼릭 링크(실제 goal_autoscript_run.sh 사용)로 세션을 만들고
verify_crud_executed.py --emit-from-goal 을 실행한다.
  - state=TEST/DEV/OK + 플래그 없음 → before_stage=odone 기본 적용 → make_ok + deferred 기록
  - state=DONE/부재 + 플래그 없음 → 전수 판정 → make_partial
  - 명시 --before-stage 는 state 와 무관하게 우선
  - --gate-cmd 경로는 기본값을 적용하지 않는다(종전 동작)
환경변수 VCE_SCRIPT 로 대상 스크립트를 바꿀 수 있다(수정 전 사본 대조용).
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.environ.get("VCE_SCRIPT") or os.path.join(HERE, "verify_crud_executed.py")
HOOKS = os.path.realpath(os.path.join(HERE, "..", "..", "..", "hooks"))
UUID = "c182unit-0001"


class EmitBeforeStageTest(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="c182_emit_")
        os.symlink(HOOKS, os.path.join(self.root, "hooks"))
        self.sd = os.path.join(self.root, "session-env", UUID)
        os.makedirs(os.path.join(self.sd, "evidence"))
        os.makedirs(os.path.join(self.sd, "plans"))
        goal = {"goal_id": "G-C182UNIT", "locked": True, "acceptance": [
            {"id": "A1", "auto_script": "true", "depends_on": []},
            {"id": "Z1", "auto_script": "false", "depends_on": [], "valid_after": "odone"},
        ]}
        with open(os.path.join(self.sd, "goal.json"), "w", encoding="utf-8") as fp:
            json.dump(goal, fp)

    def tearDown(self):
        shutil.rmtree(self.root, ignore_errors=True)

    def _state(self, value):
        path = os.path.join(self.sd, "state")
        if value is None:
            if os.path.exists(path):
                os.remove(path)
            return
        with open(path, "w", encoding="utf-8") as fp:
            fp.write(f"{value} {UUID}\n")

    def _run(self, *extra):
        cmd = [sys.executable, SCRIPT, "--uuid", UUID, "--emit-from-goal"] + list(extra)
        proc = subprocess.run(cmd, capture_output=True, text=True, cwd=self.root, timeout=90,
                              env=dict(os.environ, CLAUDE_CONFIG_DIR=self.root))
        return proc.returncode, proc.stdout + proc.stderr

    def _ev(self, name):
        path = os.path.join(self.sd, "evidence", name)
        if not os.path.isfile(path):
            return None
        with open(path, "r", encoding="utf-8") as fp:
            return json.load(fp)

    def test_test_state_defaults_odone_with_deferred(self):
        self._state("TEST")
        rc, out = self._run()
        self.assertEqual(rc, 0, out)
        self.assertIn("BEFORE_STAGE_DEFAULT: state=TEST", out)
        ok = self._ev("make_ok")
        self.assertIsNotNone(ok, out)
        self.assertEqual(ok.get("deferred"), ["Z1"])
        self.assertEqual(ok.get("before_stage"), "odone")

    def test_dev_state_defaults_odone(self):
        self._state("DEV")
        rc, out = self._run()
        self.assertEqual(rc, 0, out)
        self.assertIsNotNone(self._ev("make_ok"), out)

    def test_legacy_ok_state_defaults_odone(self):
        self._state("OK")
        rc, out = self._run()
        self.assertEqual(rc, 0, out)
        self.assertIn("BEFORE_STAGE_DEFAULT: state=OK", out)

    def test_done_state_full_judgement(self):
        self._state("DONE")
        rc, out = self._run()
        self.assertEqual(rc, 1, out)
        self.assertNotIn("BEFORE_STAGE_DEFAULT", out)
        part = self._ev("make_partial")
        self.assertIsNotNone(part, out)
        self.assertIn("Z1", [n["id"] for n in part["not_passed"]])
        self.assertNotIn("deferred", part)
        self.assertIsNone(self._ev("make_ok"))

    def test_missing_state_full_judgement(self):
        self._state(None)
        rc, out = self._run()
        self.assertEqual(rc, 1, out)
        self.assertNotIn("BEFORE_STAGE_DEFAULT", out)

    def test_explicit_flag_wins_over_done_state(self):
        self._state("DONE")
        rc, out = self._run("--before-stage", "odone")
        self.assertEqual(rc, 0, out)
        self.assertNotIn("BEFORE_STAGE_DEFAULT", out)
        self.assertIsNotNone(self._ev("make_ok"), out)

    def test_gate_cmd_path_unchanged(self):
        self._state("TEST")
        gate = os.path.join(self.root, "gate.sh")
        with open(gate, "w", encoding="utf-8") as fp:
            fp.write("printf 'A1\\tPASS\\tok\\nZ1\\tFAIL\\tno\\n'\nexit 1\n")
        rc, out = self._run("--gate-cmd", f"bash {gate}")
        self.assertEqual(rc, 1, out)
        self.assertNotIn("BEFORE_STAGE_DEFAULT", out)
        part = self._ev("make_partial")
        self.assertIsNotNone(part, out)
        self.assertNotIn("deferred", part)


if __name__ == "__main__":
    unittest.main(verbosity=2)
