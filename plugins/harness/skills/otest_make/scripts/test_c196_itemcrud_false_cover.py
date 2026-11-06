# 사이클196 사례 6 재현 시험 — item_crud:false 항목이 세션 전체 CRUD 의심 파일 때문에 무효화되던 비대칭(C25 미적용)과 적용 시점 플래그를 검사한다
"""
실행: python3 test_c196_itemcrud_false_cover.py [-v]
대상 스크립트 교체: VCE_SCRIPT_UNDER_TEST=<verify_crud_executed.py 사본> (수정 전 재현용)
"""
import json
import os
import subprocess
import sys
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import test_verify_crud_executed as base  # noqa: E402

SCRIPT = os.environ.get("VCE_SCRIPT_UNDER_TEST") or os.path.join(HERE, "verify_crud_executed.py")
SINCE = 1792724295

# c196 AC-003 과 같은 어휘 구성(저장 동사가 음성 시험 대상으로만 나오는 검증형 항목)
FALSE_ITEM = {
    "id": "AC-F", "item_crud": False, "category": "tool", "priority": "must",
    "description": "백업 도구가 PK 순 정규화 JSONL 과 매니페스트(COUNT·md5·시각)를 2곳에 남기고, 공용 DB 접속 모듈이 "
                   "SELECT/SHOW/DESCRIBE/WITH/EXPLAIN 외 문장을 실행 전 예외로 막는다",
    "method": "개발 대상 실행·2벌 md5 대조 + 셀프테스트 음성 케이스(INSERT·UPDATE·DELETE·DDL 각 1건 → 예외) + 직접 connect 0건 grep",
    "expected": "COUNT 일치·2벌 md5 동일·음성 4건 예외·직접 connect 0",
}
CRUD_ITEM = dict(base.C172FalsePositiveTest.CRUD_ITEM)
DB_SVC = base.C172FalsePositiveTest.DB_SVC
GOOD_EVID = [{"id": "AC-C", "status": "PASS", "write_log": "[PMS] 프로젝트 저장 완료",
              "count_before": 10, "count_after": 11, "live_rows": False}]


class ItemCrudFalseCoverTest(unittest.TestCase):
    setUp = base.VerifyCrudFallbackTest.setUp
    tearDown = base.VerifyCrudFallbackTest.tearDown
    write = staticmethod(base.VerifyCrudFallbackTest.write)
    set_start = base.VerifyCrudFallbackTest.set_start
    _criteria = base.C172FalsePositiveTest._criteria
    _assignment = base.C172FalsePositiveTest._assignment
    _make_ok = base.C172FalsePositiveTest._make_ok

    def run_gate(self, extra_env=None):
        env = dict(os.environ)
        env.pop("CLAUDE_PROJECT_DIR", None)
        env.pop("VCE_ITEM_CRUD_FALSE_COVER", None)
        env.update(extra_env or {})
        proc = subprocess.run([sys.executable, SCRIPT, "--criteria", self.criteria, "--evidence", self.evidence, "--final"],
                              cwd=self.repo, env=env, capture_output=True, text=True, timeout=60)
        return proc.returncode, proc.stdout + proc.stderr

    def _setup(self, start, items, evid=GOOD_EVID):
        svc = self.write(self.repo, "Svc/FooService.cs", DB_SVC)
        sql = self.write(self.repo, "db/x_ddl.sql", "CREATE TABLE t_x (id int);\n")
        self._criteria(items)
        self._assignment({"agents": {"odev-1": {"files": [svc, sql]}}})
        if evid is not None:
            self._make_ok(evid)
        if start is not None:
            self.set_start(start)

    # 재현(수정 후 정상): 다음 사이클(도입 이후 시작) — true 항목이 의심 파일 증거를 지므로 false 항목은 면제
    def test_r1_next_cycle_false_item_covered(self):
        self._setup(int(time.time()) - 5, [dict(FALSE_ITEM), dict(CRUD_ITEM)])
        rc, out = self.run_gate()
        self.assertEqual(rc, 0, out)
        self.assertIn("ITEM_CRUD_FALSE_PATH_COVERED: AC-F", out)
        self.assertNotIn("CRUD_DECLARATION_OVERRIDDEN", out)
        self.assertIn("CRUD_EVIDENCE_OK: CRUD 항목 1건", out)

    # c196 무영향: 도입 이전에 시작한 파이프라인(진행 중 사이클)은 종전 판정 그대로
    def test_r2_inflight_cycle_unchanged(self):
        self._setup(SINCE - 15000, [dict(FALSE_ITEM), dict(CRUD_ITEM)])
        rc, out = self.run_gate()
        self.assertEqual(rc, 1, out)
        self.assertIn("ITEM_CRUD_FALSE_COVER_OFF: AC-F", out)
        self.assertIn("CRUD_DECLARATION_OVERRIDDEN", out)
        self.assertNotIn("ITEM_CRUD_FALSE_PATH_COVERED", out)

    # 우회 차단: 의심 파일 증거를 질 item_crud:true 항목이 없으면 종전대로 무효화
    def test_r3_no_true_item_still_overridden(self):
        self._setup(int(time.time()) - 5, [dict(FALSE_ITEM)], evid=None)
        rc, out = self.run_gate()
        self.assertEqual(rc, 1, out)
        self.assertIn("CRUD_DECLARATION_OVERRIDDEN", out)
        self.assertNotIn("ITEM_CRUD_FALSE_PATH_COVERED", out)

    # 강제 OFF 환경변수
    def test_r4_env_force_off(self):
        self._setup(int(time.time()) - 5, [dict(FALSE_ITEM), dict(CRUD_ITEM)])
        rc, out = self.run_gate({"VCE_ITEM_CRUD_FALSE_COVER": "0"})
        self.assertEqual(rc, 1, out)
        self.assertIn("ITEM_CRUD_FALSE_COVER_OFF", out)

    # 강제 ON 수단은 없다 — 진행 중 사이클에서 환경변수 1 로 켤 수 없다
    def test_r5_env_cannot_force_on(self):
        self._setup(SINCE - 15000, [dict(FALSE_ITEM), dict(CRUD_ITEM)])
        rc, out = self.run_gate({"VCE_ITEM_CRUD_FALSE_COVER": "1"})
        self.assertEqual(rc, 1, out)
        self.assertNotIn("ITEM_CRUD_FALSE_PATH_COVERED", out)

    # 시작 시각을 읽을 수 없으면 OFF(종전 판정)
    def test_r6_no_start_time_off(self):
        self._setup(None, [dict(FALSE_ITEM), dict(CRUD_ITEM)])
        rc, out = self.run_gate()
        self.assertNotIn("ITEM_CRUD_FALSE_PATH_COVERED", out)

    # true 항목이 실제 저장 증거를 안 냈으면 면제가 있어도 전체는 거부(증거 책임이 실제로 집행된다)
    def test_r7_true_item_without_evidence_blocks(self):
        self._setup(int(time.time()) - 5, [dict(FALSE_ITEM), dict(CRUD_ITEM)],
                    evid=[{"id": "AC-C", "status": "PASS", "note": "차단 확인만"}])
        rc, out = self.run_gate()
        self.assertEqual(rc, 1, out)
        self.assertIn("ITEM_CRUD_FALSE_PATH_COVERED: AC-F", out)


if __name__ == "__main__":
    unittest.main()
