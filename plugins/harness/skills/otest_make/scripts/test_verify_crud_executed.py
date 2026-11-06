#!/usr/bin/env python3
# verify_crud_executed.py 의 변경 파일 독립 산출 폴백(file_assignment.json 부재 시)을 검증하는 테스트
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "verify_crud_executed.py")

# 직전 사이클(hook 수정) AC 를 축약한 픽스처 — 비-CRUD, item_crud:false, 자연어 verify 가 INSPECTION_HINTS 밖
FIXTURE_AC = {
    "tier": "O2",
    "criteria": [
        {
            "id": "AC-001",
            "item_crud": False,
            "category": "hook",
            "priority": "must",
            "description": "재개 세션에서 pane 라벨이 '이름 description' 으로 설정된다.",
            "verify": "test_pane_label_owner.sh (a) 임시 pane 스텁 실행 후 tmux show 값 대조",
            "expected": "라벨 == 'NAME DESC'",
        },
        {
            "id": "AC-004",
            "item_crud": False,
            "category": "hook",
            "priority": "must",
            "description": "빈 description, 비JSON 입력, agent-id 불일치(--agent-id 만 틀림) 에서는 무동작·exit 0·무출력이다.",
            "verify": "test_pane_label_owner.sh (d)(e)",
            "expected": "라벨 미설정, rc=0, 무출력",
        },
        {
            "id": "AC-007",
            "item_crud": False,
            "category": "script",
            "priority": "must",
            "description": "~/.claude/settings.json hooks 가 정본과 일치한다(HOME-only 0건 확인 후 settings_hooks_sync.py 실행). 스칼라 키는 불변이다.",
            "verify": "실행 전 정본/HOME hooks 차집합 json 비교(HOME-only 0), 실행 후 settings_hooks_sync.py --check rc=0, 스칼라 키 json diff 0",
            "expected": "--check rc=0, 스칼라 diff 0",
        },
    ],
}


def _git(cwd, *args):
    subprocess.run(["git"] + list(args), cwd=cwd, check=True, capture_output=True)


class VerifyCrudFallbackTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = os.path.join(self.tmp.name, "repo")
        self.sess = os.path.join(self.tmp.name, "sess")
        os.makedirs(self.repo)
        os.makedirs(self.sess)
        _git(self.repo, "init", "-q")
        _git(self.repo, "config", "user.email", "t@t")
        _git(self.repo, "config", "user.name", "t")
        self.write(self.repo, "README.md", "init\n")
        _git(self.repo, "add", "-A")
        _git(self.repo, "commit", "-qm", "init")
        self.criteria = os.path.join(self.sess, "acceptance_criteria.json")
        with open(self.criteria, "w", encoding="utf-8") as fp:
            json.dump(FIXTURE_AC, fp, ensure_ascii=False)
        self.evidence = os.path.join(self.sess, "evidence", "make_ok")

    def tearDown(self):
        self.tmp.cleanup()

    @staticmethod
    def write(root, rel, content, mtime=None):
        path = os.path.join(root, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fp:
            fp.write(content)
        if mtime is not None:
            os.utime(path, (mtime, mtime))
        return path

    def set_start(self, value):
        with open(os.path.join(self.sess, "pipeline_start_time"), "w") as fp:
            fp.write(str(value))

    def run_gate(self, cwd=None):
        env = dict(os.environ)
        env.pop("CLAUDE_PROJECT_DIR", None)
        proc = subprocess.run(
            [sys.executable, SCRIPT, "--criteria", self.criteria,
             "--evidence", self.evidence, "--final"],
            cwd=cwd or self.repo, env=env, capture_output=True, text=True, timeout=60,
        )
        return proc.returncode, proc.stdout + proc.stderr

    def test_a_hook_sh_only_passes(self):
        self.set_start(int(time.time()) - 5)
        self.write(self.repo, "hooks/x.sh", "#!/bin/sh\necho hi\n")
        rc, out = self.run_gate()
        self.assertEqual(rc, 0, out)
        self.assertIn("CHANGED_FILES_DERIVED", out)
        self.assertIn("NON_CRUD_EXEMPT_DB_UNTOUCHED", out)

    def test_b_service_or_sql_with_false_item_crud_blocks(self):
        self.set_start(int(time.time()) - 5)
        self.write(self.repo, "hooks/x.sh", "echo hi\n")
        self.write(self.repo, "Svc/FooService.cs", "class FooService { string q = \"INSERT INTO t VALUES (1)\"; }\n")
        self.write(self.repo, "db/schema.sql", "CREATE TABLE t (id int);\n")
        rc, out = self.run_gate()
        self.assertEqual(rc, 1, out)
        self.assertIn("CHANGED_FILES_DERIVED", out)

    def test_c1_not_git_fail_closed(self):
        self.set_start(int(time.time()) - 5)
        nogit = os.path.join(self.tmp.name, "nogit")
        os.makedirs(nogit)
        rc, out = self.run_gate(cwd=nogit)
        self.assertEqual(rc, 1, out)
        self.assertNotIn("CHANGED_FILES_DERIVED", out)
        self.assertIn("DB_SCAN_UNVERIFIABLE", out)

    def test_c2_no_start_time_fail_closed(self):
        self.write(self.repo, "hooks/x.sh", "echo hi\n")
        rc, out = self.run_gate()
        self.assertEqual(rc, 1, out)
        self.assertNotIn("CHANGED_FILES_DERIVED", out)
        self.assertIn("DB_SCAN_UNVERIFIABLE", out)

    def test_d_dirty_before_start_ignored(self):
        old = int(time.time()) - 3600
        self.write(self.repo, "db/old.sql", "-- old\n", mtime=old)
        self.set_start(int(time.time()) - 5)
        self.write(self.repo, "hooks/x.sh", "echo hi\n")
        rc, out = self.run_gate()
        self.assertEqual(rc, 0, out)
        self.assertNotIn("old.sql", out)

    def test_e1_existing_assignment_sh_only_unchanged(self):
        # file_assignment.json 이 있으면 폴백 미사용 — git 의 *.sql 변경은 무시된다(기존 경로 그대로).
        self.set_start(int(time.time()) - 5)
        self.write(self.repo, "db/schema.sql", "-- schema\n")
        sh = self.write(self.repo, "hooks/x.sh", "echo hi\n")
        with open(os.path.join(self.sess, "file_assignment.json"), "w") as fp:
            json.dump({"agents": {"odev-1": {"files": [sh]}}}, fp)
        rc, out = self.run_gate()
        self.assertEqual(rc, 0, out)
        self.assertNotIn("CHANGED_FILES_DERIVED", out)

    def test_e2_existing_assignment_with_service_blocks(self):
        self.set_start(int(time.time()) - 5)
        svc = self.write(self.repo, "Svc/FooService.cs", "class FooService { string q = \"INSERT INTO t VALUES (1)\"; }\n")
        with open(os.path.join(self.sess, "file_assignment.json"), "w") as fp:
            json.dump({"agents": {"odev-1": {"files": [svc]}}}, fp)
        rc, out = self.run_gate()
        self.assertEqual(rc, 1, out)
        self.assertNotIn("CHANGED_FILES_DERIVED", out)

    def test_e3_corrupt_assignment_fail_closed_no_fallback(self):
        self.set_start(int(time.time()) - 5)
        self.write(self.repo, "hooks/x.sh", "echo hi\n")
        with open(os.path.join(self.sess, "file_assignment.json"), "w") as fp:
            fp.write("{broken")
        rc, out = self.run_gate()
        self.assertEqual(rc, 1, out)
        self.assertNotIn("CHANGED_FILES_DERIVED", out)

    def _assign(self, files):
        with open(os.path.join(self.sess, "file_assignment.json"), "w") as fp:
            json.dump({"agents": {"odev-1": {"files": files}}}, fp)

    def test_f_gate_self_files_excluded_from_db_scan(self):
        # 2026-10-06: 변경 파일이 판정기 자신+테스트뿐이면 DB 문자열이 있어도 DB 접촉이 아니다.
        self.set_start(int(time.time()) - 5)
        self._assign([SCRIPT, os.path.abspath(__file__)])
        rc, out = self.run_gate()
        self.assertEqual(rc, 0, out)
        self.assertIn("SELF_SCAN_EXCLUDED", out)
        self.assertNotIn("DB_CONTACT_DETECTED", out)

    def test_g_same_content_other_name_still_detected(self):
        # 정확 일치만 예외 — 같은 내용의 다른 이름/다른 디렉토리 파일은 여전히 DB 접촉이다.
        self.set_start(int(time.time()) - 5)
        body = "SELECT a FROM t; INSERT INTO t VALUES (1)\n"
        copy_py = self.write(self.repo, "tools/verify_crud_executed_copy.py", body)
        other_test = self.write(self.repo, "other/test_verify_crud_executed.py", body)
        self._assign([copy_py, other_test])
        rc, out = self.run_gate()
        self.assertEqual(rc, 1, out)
        self.assertIn("DB_CONTACT_DETECTED", out)
        self.assertNotIn("SELF_SCAN_EXCLUDED", out)

    # ── 2026-10-06 역라우팅 #2: deleted_files 선언 + 부재·git 실측으로 '삭제 확정' 분리 ──
    def _assign_agents(self, agents):
        with open(os.path.join(self.sess, "file_assignment.json"), "w") as fp:
            json.dump({"agents": agents}, fp)

    def _commit(self, msg, *paths):
        _git(self.repo, "add", "-A", *paths)
        _git(self.repo, "commit", "-qm", msg)

    def test_h1_untracked_never_declared_passes(self):
        self.set_start(int(time.time()) - 5)
        sh = self.write(self.repo, "hooks/x.sh", "echo hi\n")
        gone = os.path.join(self.repo, "hooks/gone.sh")
        self._assign_agents({"odev-1": {"files": [sh, gone], "deleted_files": [gone]}})
        rc, out = self.run_gate()
        self.assertEqual(rc, 0, out)
        self.assertIn(f"DELETED_CONFIRMED: {gone} (untracked-never)", out)
        self.assertIn("NON_CRUD_EXEMPT_DB_UNTOUCHED", out)
        self.assertNotIn("DB_SCAN_UNVERIFIABLE", out)

    def test_h2_absent_without_declaration_unverifiable(self):
        self.set_start(int(time.time()) - 5)
        sh = self.write(self.repo, "hooks/x.sh", "echo hi\n")
        gone = os.path.join(self.repo, "hooks/gone.sh")
        self._assign_agents({"odev-1": {"files": [sh, gone]}})
        rc, out = self.run_gate()
        self.assertEqual(rc, 1, out)
        self.assertIn("DB_SCAN_UNVERIFIABLE", out)
        self.assertNotIn("DELETED_CONFIRMED", out)

    def test_h3_declared_but_exists_with_db_code_detected(self):
        self.set_start(int(time.time()) - 5)
        live = self.write(self.repo, "hooks/live.sh", "q='INSERT INTO t VALUES (1)'\n")
        self._assign_agents({"odev-1": {"files": [live], "deleted_files": [live]}})
        rc, out = self.run_gate()
        self.assertEqual(rc, 1, out)
        self.assertIn("DB_CONTACT_DETECTED", out)
        self.assertNotIn("DELETED_CONFIRMED", out)

    def test_h4_tracked_deleted_head_has_db_code_detected(self):
        self.set_start(int(time.time()) - 5)
        old = self.write(self.repo, "hooks/old.sh", "q='INSERT INTO t VALUES (1)'\n")
        self._commit("add old")
        os.remove(old)
        sh = self.write(self.repo, "hooks/x.sh", "echo hi\n")
        self._assign_agents({"odev-1": {"files": [sh, old], "deleted_files": [old]}})
        rc, out = self.run_gate()
        self.assertEqual(rc, 1, out)
        self.assertIn("DB_CONTACT_DETECTED", out)
        self.assertNotIn("DELETED_CONFIRMED", out)

    def test_h5_tracked_deleted_head_harmless_passes(self):
        self.set_start(int(time.time()) - 5)
        old = self.write(self.repo, "hooks/old.sh", "echo bye\n")
        self._commit("add old")
        os.remove(old)
        self._assign_agents({"odev-1": {"files": [old], "deleted_files": [old]}})
        rc, out = self.run_gate()
        self.assertEqual(rc, 0, out)
        self.assertIn(f"DELETED_CONFIRMED: {old} (tracked-head-scanned)", out)
        self.assertIn("NON_CRUD_EXEMPT_DB_UNTOUCHED", out)

    def test_h6_history_only_unverifiable(self):
        self.set_start(int(time.time()) - 5)
        old = self.write(self.repo, "hooks/old.sh", "echo bye\n")
        self._commit("add old")
        _git(self.repo, "rm", "-q", "hooks/old.sh")
        _git(self.repo, "commit", "-qm", "rm old")
        sh = self.write(self.repo, "hooks/x.sh", "echo hi\n")
        self._assign_agents({"odev-1": {"files": [sh, old], "deleted_files": [old]}})
        rc, out = self.run_gate()
        self.assertEqual(rc, 1, out)
        self.assertIn("DB_SCAN_UNVERIFIABLE", out)
        self.assertNotIn("DELETED_CONFIRMED", out)

    def test_h7_outside_git_unverifiable(self):
        self.set_start(int(time.time()) - 5)
        sh = self.write(self.repo, "hooks/x.sh", "echo hi\n")
        nogit = os.path.join(self.tmp.name, "nogit")
        os.makedirs(nogit)
        gone = os.path.join(nogit, "gone.sh")
        self._assign_agents({"odev-1": {"files": [sh, gone], "deleted_files": [gone]}})
        rc, out = self.run_gate()
        self.assertEqual(rc, 1, out)
        self.assertIn("DB_SCAN_UNVERIFIABLE", out)
        self.assertNotIn("DELETED_CONFIRMED", out)

    def test_h8_only_deleted_confirmed_no_files(self):
        self.set_start(int(time.time()) - 5)
        gone = os.path.join(self.repo, "hooks/gone.sh")
        self._assign_agents({"odev-1": {"files": [gone], "deleted_files": [gone]}})
        rc, out = self.run_gate()
        self.assertEqual(rc, 1, out)
        self.assertIn("DB_SCAN_UNVERIFIABLE", out)
        self.assertNotIn("NON_CRUD_EXEMPT_DB_UNTOUCHED", out)

    def test_h9_declaration_outside_own_files_ignored(self):
        # 다른 agent 의 files 에 있는 경로를 선언해도 무시된다 → 그 부재 파일은 종전대로 판독 불가.
        self.set_start(int(time.time()) - 5)
        sh = self.write(self.repo, "hooks/x.sh", "echo hi\n")
        gone = os.path.join(self.repo, "hooks/gone.sh")
        self._assign_agents({
            "odev-1": {"files": [sh, gone]},
            "odev-2": {"files": [sh], "deleted_files": [gone]},
        })
        rc, out = self.run_gate()
        self.assertEqual(rc, 1, out)
        self.assertIn("DB_SCAN_UNVERIFIABLE", out)
        self.assertNotIn("DELETED_CONFIRMED", out)
        # 남은 files 만 있으면 선언 유무와 무관하게 그 판독 결과대로 통과한다.
        self._assign_agents({"odev-1": {"files": [sh], "deleted_files": [gone]}})
        rc, out = self.run_gate()
        self.assertEqual(rc, 0, out)
        self.assertNotIn("DELETED_CONFIRMED", out)

    # ── 2026-10-06 역라우팅 #3: 시작 이전 커밋(base) 대비 변경 줄 + 근접만 DB 검사 ──
    DB_LINE = "q='INSERT INTO t VALUES (1)'"
    REL = "hooks/s.sh"

    def _g(self, *args, env=None):
        full_env = dict(os.environ, **(env or {}))
        return subprocess.run(["git", "-C", self.repo] + list(args), check=True,
                              capture_output=True, text=True, env=full_env).stdout.strip()

    def _commit_at(self, ts, msg, touch_object=True, amend=False):
        # 시작 이전 커밋 위조 헬퍼 — committer/author 시각과 느슨한 객체 mtime 을 ts 로 맞춘다.
        stamp = {"GIT_COMMITTER_DATE": f"{ts} +0000", "GIT_AUTHOR_DATE": f"{ts} +0000"}
        self._g("add", "-A")
        self._g("commit", "-qm", msg, *(["--amend"] if amend else []), env=stamp)
        sha = self._g("rev-parse", "HEAD")
        if touch_object:
            obj = os.path.join(self.repo, ".git", "objects", sha[:2], sha[2:])
            os.utime(obj, (ts, ts))
        return sha

    @staticmethod
    def _lines(n=40):
        return [f"echo line{i}" for i in range(n)]

    def _put(self, lines, rel=None):
        return self.write(self.repo, rel or self.REL, "\n".join(lines) + "\n")

    def _base(self, lines, with_start=True):
        now = int(time.time())
        path = self._put(lines)
        sha = self._commit_at(now - 100, "base")
        if with_start:
            self.set_start(now - 5)
        return path, sha

    def test_i1_far_existing_db_line_ignored(self):
        lines = self._lines()
        lines[0] = self.DB_LINE
        path, sha = self._base(lines)
        lines[35] = "echo changed"
        self._put(lines)
        self._assign([path])
        rc, out = self.run_gate()
        self.assertEqual(rc, 0, out)
        self.assertIn(f"base={sha[:12]}", out)
        self.assertIn("DB_SCAN_BASE", out)
        self.assertIn("NON_CRUD_EXEMPT_DB_UNTOUCHED", out)

    def test_i2_added_db_line_detected(self):
        lines = self._lines()
        path, _ = self._base(lines)
        lines.insert(20, self.DB_LINE)
        self._put(lines)
        self._assign([path])
        rc, out = self.run_gate()
        self.assertEqual(rc, 1, out)
        self.assertIn("DB_CONTACT_DETECTED", out)
        self.assertIn("L21+", out)

    def test_i3_removed_db_line_detected(self):
        lines = self._lines()
        lines[20] = self.DB_LINE
        path, _ = self._base(lines)
        del lines[20]
        self._put(lines)
        self._assign([path])
        rc, out = self.run_gate()
        self.assertEqual(rc, 1, out)
        self.assertIn("DB_CONTACT_DETECTED", out)
        self.assertIn("L21-", out)

    def test_i4_keywordless_change_near_db_detected(self):
        lines = self._lines()
        lines[10] = self.DB_LINE
        path, _ = self._base(lines)
        lines[13] = "x=2"
        self._put(lines)
        self._assign([path])
        rc, out = self.run_gate()
        self.assertEqual(rc, 1, out)
        self.assertIn("DB_CONTACT_DETECTED", out)
        self.assertIn("근접", out)

    def test_i5_untracked_new_file_full_scan(self):
        self._base(self._lines())
        new = self.write(self.repo, "hooks/new.sh", self.DB_LINE + "\n")
        self._assign([new])
        rc, out = self.run_gate()
        self.assertEqual(rc, 1, out)
        self.assertIn("DB_SCAN_FULL", out)
        self.assertIn("DB_CONTACT_DETECTED", out)

    def test_i6_db_line_hidden_in_post_start_commit_detected(self):
        lines = self._lines()
        path, _ = self._base(lines)
        lines.insert(5, self.DB_LINE)
        self._put(lines)
        self._g("add", "-A")
        self._g("commit", "-qm", "hide")
        self.assertEqual(self._g("status", "--porcelain"), "")
        self._assign([path])
        rc, out = self.run_gate()
        self.assertEqual(rc, 1, out)
        self.assertIn("DB_CONTACT_DETECTED", out)

    def test_i7_amend_pre_start_commit_detected(self):
        lines = self._lines()
        path, _ = self._base(lines)
        lines.insert(5, self.DB_LINE)
        self._put(lines)
        self._g("add", "-A")
        self._g("commit", "-q", "--amend", "--no-edit")
        self._assign([path])
        rc, out = self.run_gate()
        self.assertEqual(rc, 1, out)
        self.assertIn("DB_CONTACT_DETECTED", out)

    def test_i8_forged_committer_date_detected(self):
        lines = self._lines()
        path, base_sha = self._base(lines)
        lines.insert(5, self.DB_LINE)
        self._put(lines)
        # 커밋 시각만 위조(객체 mtime 은 실제 기록 시각) → 그 커밋은 base 가 될 수 없다.
        self._commit_at(int(time.time()) - 50, "forged", touch_object=False)
        self._assign([path])
        rc, out = self.run_gate()
        self.assertEqual(rc, 1, out)
        self.assertIn(f"base={base_sha[:12]}", out)
        self.assertIn("DB_CONTACT_DETECTED", out)

    def test_i9_rm_cached_with_db_line_detected(self):
        lines = self._lines()
        path, _ = self._base(lines)
        self._g("rm", "-q", "--cached", self.REL)
        lines.insert(5, self.DB_LINE)
        self._put(lines)
        self._assign([path])
        rc, out = self.run_gate()
        self.assertEqual(rc, 1, out)
        self.assertIn("DB_CONTACT_DETECTED", out)

    def test_i10_clean_filter_cannot_hide_db_line(self):
        lines = self._lines()
        path, _ = self._base(lines)
        self.write(self.repo, ".gitattributes", "*.sh filter=strip\n")
        self._g("config", "filter.strip.clean", "sed /INSERT/d")
        lines.insert(5, self.DB_LINE)
        self._put(lines)
        self._g("add", "-A")
        self._assign([path])
        rc, out = self.run_gate()
        self.assertEqual(rc, 1, out)
        self.assertIn("DB_CONTACT_DETECTED", out)

    def test_i11_no_start_time_full_scan(self):
        lines = self._lines()
        lines[0] = self.DB_LINE
        path, _ = self._base(lines, with_start=False)
        lines[35] = "echo changed"
        self._put(lines)
        self._assign([path])
        rc, out = self.run_gate()
        self.assertEqual(rc, 1, out)
        self.assertIn("DB_SCAN_FULL", out)
        self.assertIn("DB_CONTACT_DETECTED", out)

    def test_i12_crlf_worktree_vs_lf_base_far_change_passes(self):
        lines = self._lines()
        lines[0] = self.DB_LINE
        path, _ = self._base(lines)
        lines[35] = "echo changed"
        with open(path, "w", encoding="utf-8", newline="") as fp:
            fp.write("\r\n".join(lines) + "\r\n")
        self._assign([path])
        rc, out = self.run_gate()
        self.assertEqual(rc, 0, out)
        self.assertIn("NON_CRUD_EXEMPT_DB_UNTOUCHED", out)

    def test_i13_base_blob_missing_unverifiable(self):
        lines = self._lines()
        path, sha = self._base(lines)
        oid = self._g("rev-parse", f"{sha}:{self.REL}")
        os.remove(os.path.join(self.repo, ".git", "objects", oid[:2], oid[2:]))
        lines[35] = "echo changed"
        self._put(lines)
        self._assign([path])
        rc, out = self.run_gate()
        self.assertEqual(rc, 1, out)
        self.assertIn("DB_SCAN_UNVERIFIABLE", out)

    def _nested(self, ts=None):
        # repo/hooks 안에 중첩 저장소를 만들고 other.sh 1개만 커밋한다(ts 지정 시 시작 이전으로 위조).
        nested = os.path.join(self.repo, "hooks")
        self.write(nested, "other.sh", "echo other\n")
        run = lambda *a, env=None: subprocess.run(["git", "-C", nested] + list(a), check=True,
                                                  capture_output=True, text=True,
                                                  env=dict(os.environ, **(env or {}))).stdout.strip()
        run("init", "-q")
        run("config", "user.email", "t@t")
        run("config", "user.name", "t")
        return nested, run

    def test_i15_nested_repo_not_tracking_uses_outer_repo(self):
        lines = self._lines()
        lines[0] = self.DB_LINE
        path, sha = self._base(lines)
        nested, run = self._nested()
        ts = int(time.time()) - 100
        run("add", "other.sh")
        stamp = {"GIT_COMMITTER_DATE": f"{ts} +0000", "GIT_AUTHOR_DATE": f"{ts} +0000"}
        run("commit", "-qm", "nested", env=stamp)
        nsha = run("rev-parse", "HEAD")
        os.utime(os.path.join(nested, ".git", "objects", nsha[:2], nsha[2:]), (ts, ts))
        lines[35] = "echo changed"
        self._put(lines)
        self._assign([path])
        rc, out = self.run_gate()
        self.assertEqual(rc, 0, out)
        self.assertIn(f"{self.repo} base={sha[:12]}", out)
        self.assertIn("NON_CRUD_EXEMPT_DB_UNTOUCHED", out)

    def test_i16_post_start_nested_repo_tracking_file_full_scan(self):
        # 시작 이후 새로 만든 중첩 저장소가 파일을 추적 → 그 저장소에 base 없음 → 전체 스캔(우회 차단).
        lines = self._lines()
        lines[0] = self.DB_LINE
        path, _ = self._base(lines)
        lines[35] = "echo changed"
        self._put(lines)
        nested, run = self._nested()
        run("add", "-A")
        run("commit", "-qm", "nested-after-start")
        self._assign([path])
        rc, out = self.run_gate()
        self.assertEqual(rc, 1, out)
        self.assertIn("DB_SCAN_FULL", out)
        self.assertIn("DB_CONTACT_DETECTED", out)

    def test_i14_outside_git_full_scan(self):
        self.set_start(int(time.time()) - 5)
        nogit = os.path.join(self.tmp.name, "nogit")
        outside = self.write(nogit, "x.sh", self.DB_LINE + "\n")
        self._assign([outside])
        rc, out = self.run_gate()
        self.assertEqual(rc, 1, out)
        self.assertIn("DB_SCAN_FULL", out)
        self.assertIn("DB_CONTACT_DETECTED", out)


# ── 2026-10-08 역라우팅 #1: content 무효화 → 변경 파일 DB 실측(사실 축) 이관 ──
#   비-CRUD 선언 + AC 본문이 CRUD 로 읽힘(content) 일 때, 경로 의심 0 + 실측 clean 이면만 면제한다.
#   기존 클래스의 테스트가 중복 실행되지 않도록 상속하지 않고 헬퍼만 빌려 쓴다.
class ContentOverrideFactTest(unittest.TestCase):
    setUp = VerifyCrudFallbackTest.setUp
    tearDown = VerifyCrudFallbackTest.tearDown
    write = staticmethod(VerifyCrudFallbackTest.write)
    set_start = VerifyCrudFallbackTest.set_start
    run_gate = VerifyCrudFallbackTest.run_gate
    _assign = VerifyCrudFallbackTest._assign

    SAVE_AC = "사용자 정보를 저장하고 DB 에 등록한다"
    SH = "#!/bin/bash\n# 테스트 hook\necho hi\n"

    def _criteria(self, desc, method, declared=True):
        data = {"criteria": [{"id": "AC-X", "item_crud": False, "category": "test", "priority": "must",
                              "description": desc, "method": method, "expected": "PASS"}]}
        if declared:
            data["crud_대상"] = False
            data["crud_미해당_사유"] = "hook 셸 스크립트 수정 작업으로 DB 변경 없음"
        with open(self.criteria, "w", encoding="utf-8") as fp:
            json.dump(data, fp, ensure_ascii=False)

    def _content_case(self, files, extra=None, desc=None, method="로그의 PASS 확인"):
        # content 무효화가 나도록 '저장/등록' AC + 검증형 어휘 밖 method 를 쓴다.
        self.set_start(int(time.time()) - 5)
        self._criteria(desc or self.SAVE_AC, method)
        paths = [self.write(self.repo, rel, body) for rel, body in files.items()]
        self._assign(paths + list(extra or []))
        return self.run_gate()

    def test_j1_content_override_sh_only_cleared(self):
        rc, out = self._content_case({"hooks/a.sh": self.SH})
        self.assertEqual(rc, 0, out)
        self.assertIn("CONTENT_OVERRIDE_FACT_CLEARED", out)
        self.assertNotIn("CONTENT_OVERRIDE_FACT_BLOCKED", out)

    def test_j2_content_override_new_dml_blocked(self):
        rc, out = self._content_case({"hooks/a.sh": "mysql -e \"INSERT INTO t VALUES(1)\"\n"})
        self.assertEqual(rc, 1, out)
        self.assertIn("CONTENT_OVERRIDE_FACT_BLOCKED: 실측 사유=db_found", out)
        self.assertIn("MISSING_CRUD_EVIDENCE", out)
        self.assertNotIn("CONTENT_OVERRIDE_FACT_CLEARED", out)

    def test_j3_content_override_unreadable_blocked(self):
        rc, out = self._content_case({"hooks/a.sh": self.SH}, extra=["/nonexistent/zz.sh"])
        self.assertEqual(rc, 1, out)
        self.assertIn("CONTENT_OVERRIDE_FACT_BLOCKED: 실측 사유=unreadable", out)
        self.assertNotIn("CONTENT_OVERRIDE_FACT_CLEARED", out)

    def test_j4_content_override_empty_files_blocked(self):
        rc, out = self._content_case({})
        self.assertEqual(rc, 1, out)
        self.assertNotIn("CONTENT_OVERRIDE_FACT_CLEARED", out)

    def test_j5_double_signal_blocks(self):
        # 경로 의심(Services/) 파일은 내용 무해라 path 단계를 통과하지만, AC 본문 의심과 겹치면 면제하지 않는다.
        rc, out = self._content_case({"Services/Tracking/Eng.cs": "class E{int a=1;}\n"})
        self.assertEqual(rc, 1, out)
        self.assertIn("CONTENT_OVERRIDE_FACT_BLOCKED: 실측 사유=path_and_content", out)
        self.assertNotIn("CONTENT_OVERRIDE_FACT_CLEARED", out)

    def test_j6_path_still_blocks(self):
        # 경로 기인 무효화(path)는 실측 이관 대상이 아니다 — content 분기를 타지 않고 즉시 하드 차단.
        rc, out = self._content_case({"Svc/UserService.cs": "class S{string q=\"UPDATE users SET a=1\";}\n"})
        self.assertEqual(rc, 1, out)
        self.assertIn("MISSING_CRUD_EVIDENCE", out)
        self.assertNotIn("CONTENT_OVERRIDE_FACT", out)

    def test_j7_inspection_ac_services_harmless_still_passes(self):
        # Present 회귀: 검증형 AC + DB 무해 Services 경로는 content 분기와 무관하게 종전대로 통과.
        rc, out = self._content_case({"Services/Tracking/Eng.cs": "class E{int a=1;}\n"},
                                     desc="추적 엔진 분기 존재", method="grep 으로 코드상 확인")
        self.assertEqual(rc, 0, out)
        self.assertNotIn("CONTENT_OVERRIDE_FACT", out)


# ── 사이클172 C25 (⑰): F-CRUD-1 오탐 3종 수정 회귀 — 양성(오탐 해소) + 음성(진짜 미실행은 여전히 차단) ──
class C172FalsePositiveTest(unittest.TestCase):
    setUp = VerifyCrudFallbackTest.setUp
    tearDown = VerifyCrudFallbackTest.tearDown
    write = staticmethod(VerifyCrudFallbackTest.write)
    run_gate = VerifyCrudFallbackTest.run_gate

    SH = "#!/bin/bash\necho hi\n"
    DB_SVC = "class FooService { string q = \"INSERT INTO t_x VALUES (1)\"; }\n"
    # 어휘 판정으로는 CRUD 로 읽히는 항목(저장 요구 + 검증형 어휘 밖 method)
    SAVE_ITEM = {"id": "AC-S", "category": "backend", "priority": "must",
                 "description": "설정을 저장한다", "method": "로그 확인", "expected": "PASS"}
    INSPECT_ITEM = {"id": "AC-I", "item_crud": False, "verify_kind": "inspection", "category": "frontend",
                    "priority": "must", "description": "공지 목록 등록 화면을 추가한다",
                    "method": "기계 판정: cNNN_gate.py item AC-I", "expected": "게이트 rc=0"}
    CRUD_ITEM = {"id": "AC-C", "item_crud": True, "category": "backend", "priority": "must",
                 "description": "프로젝트를 등록하면 DB 에 INSERT 된다", "method": "개발 DB COUNT 대조",
                 "expected": "COUNT +1"}

    def _criteria(self, items, extra=None):
        data = {"criteria": items}
        data.update(extra or {})
        with open(self.criteria, "w", encoding="utf-8") as fp:
            json.dump(data, fp, ensure_ascii=False)

    def _assignment(self, payload):
        with open(os.path.join(self.sess, "file_assignment.json"), "w", encoding="utf-8") as fp:
            json.dump(payload, fp, ensure_ascii=False)

    def _make_ok(self, results):
        os.makedirs(os.path.dirname(self.evidence), exist_ok=True)
        with open(self.evidence, "w", encoding="utf-8") as fp:
            json.dump({"criteria_results": results}, fp, ensure_ascii=False)

    def _emit(self, gate_stdout, gate_rc):
        # 가짜 게이트: goal_autoscript_run.sh 출력 형식(ID<TAB>STATUS<TAB>사유)을 그대로 내고 rc 로 끝난다.
        rows = os.path.join(self.tmp.name, "gate_rows.txt")
        with open(rows, "w", encoding="utf-8") as fp:
            fp.write(gate_stdout.replace("\\t", "\t").replace("\\n", "\n"))
        gate = os.path.join(self.tmp.name, "fake_gate.sh")
        with open(gate, "w", encoding="utf-8") as fp:
            fp.write(f"#!/bin/bash\ncat '{rows}'\nexit {gate_rc}\n")
        env = dict(os.environ)
        env.pop("CLAUDE_PROJECT_DIR", None)
        proc = subprocess.run(
            [sys.executable, SCRIPT, "--emit-from-goal", "--criteria", self.criteria,
             "--evidence", self.evidence, "--gate-cmd", f"bash {gate}"],
            cwd=self.repo, env=env, capture_output=True, text=True, timeout=60,
        )
        return proc.returncode, proc.stdout + proc.stderr

    # ① 양성 — 최상위 odev-* 키 스키마(사이클171 형식)를 "변경 파일 0개"로 오독하지 않는다
    def test_k1_top_level_agent_schema_read(self):
        sh = self.write(self.repo, "hooks/a.sh", self.SH)
        self._criteria([dict(self.SAVE_ITEM)])
        self._assignment({"odev-14": {"files": [sh], "tasks": ["x"], "persona": "p"}})
        rc, out = self.run_gate()
        self.assertEqual(rc, 0, out)
        self.assertIn("NON_CRUD_EXEMPT_DB_UNTOUCHED", out)
        self.assertNotIn("DB_SCAN_UNVERIFIABLE", out)

    # ① 양성 — batches[].file_assignment / phases[].files 스키마도 판독한다
    def test_k2_batches_and_phases_schema_read(self):
        a = self.write(self.repo, "hooks/a.sh", self.SH)
        b = self.write(self.repo, "hooks/b.sh", self.SH)
        self._criteria([dict(self.SAVE_ITEM)])
        self._assignment({"batches": [{"batch_id": 1, "file_assignment": {"odev-1": {"files": [a]}}}],
                          "phases": [{"files": [b]}]})
        rc, out = self.run_gate()
        self.assertEqual(rc, 0, out)
        self.assertIn("NON_CRUD_EXEMPT_DB_UNTOUCHED", out)
        self.assertIn("검사 대상: 2개 파일", out)

    # ① 음성 — 다중 스키마로 읽은 파일에 DB 코드가 있으면 종전대로 차단(판독 확대 ≠ 면제 확대)
    def test_k3_top_level_schema_db_file_still_blocks(self):
        svc = self.write(self.repo, "Svc/FooService.cs", self.DB_SVC)
        self._criteria([dict(self.SAVE_ITEM)])
        self._assignment({"odev-3": {"files": [svc]}})
        rc, out = self.run_gate()
        self.assertEqual(rc, 1, out)
        self.assertIn("DB_CONTACT_DETECTED", out)
        self.assertIn("MISSING_CRUD_EVIDENCE", out)

    # ② 양성 — verify_kind:inspection 항목은 CRUD 의심 파일이 있어도 item_crud:true 항목이 그 증거를 지면 면제
    def test_k4_inspection_kind_covered_by_crud_item(self):
        svc = self.write(self.repo, "Svc/FooService.cs", self.DB_SVC)
        self._criteria([dict(self.INSPECT_ITEM), dict(self.CRUD_ITEM)])
        self._assignment({"agents": {"odev-1": {"files": [svc]}}})
        self._make_ok([{"id": "AC-C", "status": "PASS", "write_log": "[PMS] 프로젝트 저장 완료",
                        "count_before": 10, "count_after": 11, "live_rows": False}])  # C26: 표식 행만 선언
        rc, out = self.run_gate()
        self.assertEqual(rc, 0, out)
        self.assertIn("INSPECTION_KIND_PATH_COVERED: AC-I", out)
        self.assertIn("CRUD_EVIDENCE_OK: CRUD 항목 1건", out)

    # ② 음성 — 의심 파일을 맡을 CRUD 항목이 없으면 inspection 선언도 경로 재대조에 무효화된다
    def test_k5_inspection_kind_uncovered_still_blocks(self):
        svc = self.write(self.repo, "Svc/FooService.cs", self.DB_SVC)
        self._criteria([dict(self.INSPECT_ITEM)])
        self._assignment({"agents": {"odev-1": {"files": [svc]}}})
        rc, out = self.run_gate()
        self.assertEqual(rc, 1, out)
        self.assertIn("CRUD_DECLARATION_OVERRIDDEN", out)
        self.assertNotIn("INSPECTION_KIND_PATH_COVERED", out)

    # 음성 — 진짜 CRUD 항목이 저장을 안 태웠으면(write_log·상태변화 없음) 여전히 PASS 마킹 거부
    def test_k6_genuine_crud_without_evidence_blocks(self):
        svc = self.write(self.repo, "Svc/FooService.cs", self.DB_SVC)
        self._criteria([dict(self.INSPECT_ITEM), dict(self.CRUD_ITEM)])
        self._assignment({"odev-1": {"files": [svc]}})
        self._make_ok([{"id": "AC-C", "status": "PASS", "note": "삭제 가드 차단 확인"}])
        rc, out = self.run_gate()
        self.assertEqual(rc, 1, out)
        self.assertIn("MISSING_CRUD_EVIDENCE: CRUD 실행 증거 불충분", out)
        self.assertIn("AC-C", out)

    # ③ 양성 — goal 게이트 전 항목 PASS + CRUD 항목 증거 파일 보유 → make_ok 확정, --final 통과
    def test_k7_goal_gate_all_pass_emits_make_ok(self):
        evdir = os.path.join(self.tmp.name, "evd")
        os.makedirs(evdir)
        with open(os.path.join(evdir, "AC-C.json"), "w", encoding="utf-8") as fp:
            # live_rows:false — [cNNNtest] 표식 신규 행만 다룸(사이클172 C26 스냅샷 게이트 면제 선언)
            json.dump({"result": "PASS", "write_log": "[PMS] 저장 완료", "count_before": 1, "count_after": 2,
                       "live_rows": False}, fp)
        crud = dict(self.CRUD_ITEM, evidence="AC-C.json")
        self._criteria([dict(self.INSPECT_ITEM), crud], {"evidence_dir": evdir})
        self._assignment({"odev-1": {"files": [self.write(self.repo, "hooks/a.sh", self.SH)]}})
        rc, out = self._emit("AC-I\\tPASS\\trc=0\\nAC-C\\tPASS\\trc=0\\n", 0)
        self.assertEqual(rc, 0, out)
        self.assertIn("MAKE_OK_FROM_GOAL", out)
        self.assertTrue(os.path.isfile(self.evidence))
        rc2, out2 = self.run_gate()
        self.assertEqual(rc2, 0, out2)

    # ③ 정직 — 게이트 FAIL 1건 → make_partial 만 기록(make_ok 없음), --final 은 PARTIAL 로만 인정
    def test_k8_goal_gate_fail_emits_partial_not_ok(self):
        crud = dict(self.CRUD_ITEM)
        self._criteria([dict(self.INSPECT_ITEM), crud])
        self._assignment({"odev-1": {"files": [self.write(self.repo, "Svc/FooService.cs", self.DB_SVC)]}})
        rc, out = self._emit("AC-I\\tPASS\\trc=0\\nAC-C\\tFAIL\\trc=1\\n", 1)
        self.assertEqual(rc, 1, out)
        self.assertIn("MAKE_PARTIAL_FROM_GOAL", out)
        self.assertFalse(os.path.isfile(self.evidence), "FAIL 이 있는데 make_ok 이 생기면 안 된다")
        partial = os.path.join(os.path.dirname(self.evidence), "make_partial")
        with open(partial, encoding="utf-8") as fp:
            data = json.load(fp)
        self.assertEqual(data["result"], "PARTIAL")
        self.assertEqual([e["id"] for e in data["not_passed"]], ["AC-C"])
        rc2, out2 = self.run_gate()
        self.assertEqual(rc2, 0, out2)
        self.assertIn("PARTIAL_ACKNOWLEDGED", out2)
        self.assertIn("AC-C: 미통과로 기록됨(PARTIAL)", out2)

    # ③ 음성 — 게이트는 전부 PASS 여도 CRUD 증거가 없으면 make_ok 거부, 위조 partial(PASS 표기)도 거부
    def test_k9_goal_pass_without_crud_evidence_refused_and_forged_partial_blocked(self):
        self._criteria([dict(self.INSPECT_ITEM), dict(self.CRUD_ITEM)])
        self._assignment({"odev-1": {"files": [self.write(self.repo, "Svc/FooService.cs", self.DB_SVC)]}})
        rc, out = self._emit("AC-I\\tPASS\\trc=0\\nAC-C\\tPASS\\trc=0\\n", 0)
        self.assertEqual(rc, 1, out)
        self.assertIn("MAKE_OK_REFUSED_CRUD", out)
        self.assertFalse(os.path.isfile(self.evidence))
        partial = os.path.join(os.path.dirname(self.evidence), "make_partial")
        with open(partial, "w", encoding="utf-8") as fp:
            json.dump({"result": "PARTIAL", "passed": ["AC-C"], "not_passed": [{"id": "AC-I", "status": "FAIL"}],
                       "criteria_results": [{"id": "AC-C", "status": "PASS"}]}, fp)
        rc2, out2 = self.run_gate()
        self.assertEqual(rc2, 1, out2)
        self.assertIn("AC-C: PASS 로 기록됐으나 write_log+상태변화 증거 없음", out2)

    # ③ 판정불가 — 게이트 판정 행 0건이면 아무것도 쓰지 않는다(rc=3)
    def test_k10_goal_gate_no_rows_undetermined(self):
        self._criteria([dict(self.CRUD_ITEM)])
        rc, out = self._emit("", 3)
        self.assertEqual(rc, 3, out)
        self.assertFalse(os.path.isfile(self.evidence))
        self.assertFalse(os.path.isfile(os.path.join(os.path.dirname(self.evidence), "make_partial")))

    # ── 사이클172 C26 보강1: 실업무 행 스냅샷 선행 게이트(L-1200) ──
    def _live_setup(self, ev_extra, snap=None, snap_mtime=None):
        evdir = os.path.join(self.tmp.name, "evd_live")
        os.makedirs(evdir, exist_ok=True)
        ev = {"result": "PASS", "write_log": "[PMS] 저장 완료", "count_before": 1, "count_after": 2}
        ev.update(ev_extra)
        with open(os.path.join(evdir, "AC-C.json"), "w", encoding="utf-8") as fp:
            json.dump(ev, fp)
        if snap is not None:
            sp = os.path.join(evdir, "snapshot_AC-C_t_Ticket.json")
            with open(sp, "w", encoding="utf-8") as fp:
                fp.write(snap)
            if snap_mtime is not None:
                os.utime(sp, (snap_mtime, snap_mtime))
        self._criteria([dict(self.INSPECT_ITEM), dict(self.CRUD_ITEM, evidence="AC-C.json")], {"evidence_dir": evdir})
        self._assignment({"odev-1": {"files": [self.write(self.repo, "hooks/a.sh", self.SH)]}})
        return self._emit("AC-I\\tPASS\\trc=0\\nAC-C\\tPASS\\trc=0\\n", 0)

    def _partial_status(self):
        with open(os.path.join(os.path.dirname(self.evidence), "make_partial"), encoding="utf-8") as fp:
            return {e["id"]: e["status"] for e in json.load(fp)["not_passed"]}

    SNAP = '{"table":"cspms.t_Ticket","where":"TicketID=19772","rows":[{"TicketID":19772}]}'

    # 양성(차단) — 실업무 CRUD 항목에 스냅샷이 없으면 make_ok 금지 → make_partial
    def test_k11_live_crud_without_snapshot_partial(self):
        rc, out = self._live_setup({"write_ts": "2026-10-08T12:00:00+09:00"})
        self.assertEqual(rc, 1, out)
        self.assertFalse(os.path.isfile(self.evidence), "스냅샷 없이 make_ok 이 생기면 안 된다")
        self.assertEqual(self._partial_status().get("AC-C"), "SNAPSHOT_MISSING")

    # 양성(차단) — 스냅샷이 첫 쓰기보다 늦으면(원값 아님, 19772 사고 형태) make_partial
    def test_k12_snapshot_after_first_write_partial(self):
        rc, out = self._live_setup({"write_ts": 1_700_000_000}, self.SNAP, snap_mtime=1_700_000_500)
        self.assertEqual(rc, 1, out)
        self.assertEqual(self._partial_status().get("AC-C"), "SNAPSHOT_AFTER_WRITE")

    # 양성(차단) — 첫 쓰기 시각이 증거에 없으면 선후 판정 불가 → make_partial
    def test_k13_write_ts_missing_partial(self):
        rc, out = self._live_setup({}, self.SNAP, snap_mtime=1_700_000_000)
        self.assertEqual(rc, 1, out)
        self.assertEqual(self._partial_status().get("AC-C"), "WRITE_TS_MISSING")

    # 양성(차단) — rows 없는 불량 스냅샷
    def test_k14_invalid_snapshot_partial(self):
        rc, out = self._live_setup({"write_ts": 1_700_000_900}, '{"table":"t_Ticket"}', snap_mtime=1_700_000_000)
        self.assertEqual(rc, 1, out)
        self.assertEqual(self._partial_status().get("AC-C"), "SNAPSHOT_INVALID")

    # 음성(통과) — 스냅샷이 첫 쓰기(GW 로그 시각)보다 앞서면 make_ok
    def test_k15_snapshot_before_write_make_ok(self):
        rc, out = self._live_setup({"gw_log_ts": "2023-11-15T08:00:00+09:00"}, self.SNAP, snap_mtime=1_700_000_000)
        self.assertEqual(rc, 0, out)
        self.assertIn("MAKE_OK_FROM_GOAL", out)

    # 음성(면제) — live_rows:false(테스트 표식 신규 행만) 선언 항목은 스냅샷 불요
    def test_k16_live_rows_false_exempt(self):
        rc, out = self._live_setup({"live_rows": False, "note": "[c172test] 신규 행만"})
        self.assertEqual(rc, 0, out)
        self.assertIn("MAKE_OK_FROM_GOAL", out)

    # 수기 make_ok(main 경로, emit 미경유) — 리드 결정 12:35 로 동일 검사 적용
    def _manual(self, rec_extra, snap_mtime=None):
        self._criteria([dict(self.INSPECT_ITEM), dict(self.CRUD_ITEM)])
        # DB 코드 파일을 넣어 CRUD 검사 경로를 실제로 타게 한다(DB 무접촉 면제로 빠지지 않게)
        self._assignment({"odev-1": {"files": [self.write(self.repo, "Svc/FooService.cs", self.DB_SVC)]}})
        rec = {"id": "AC-C", "status": "PASS", "write_log": "[PMS] 저장 완료", "count_before": 1, "count_after": 2}
        rec.update(rec_extra)
        self._make_ok([rec])
        if snap_mtime is not None:
            sp = os.path.join(os.path.dirname(self.evidence), "snapshot_AC-C_t_Ticket.json")
            with open(sp, "w", encoding="utf-8") as fp:
                fp.write(self.SNAP)
            os.utime(sp, (snap_mtime, snap_mtime))
        return self.run_gate()

    # 양성(차단) — 수기 make_ok 에 스냅샷 없음 → PASS 마킹 거부
    def test_k17_manual_make_ok_without_snapshot_blocked(self):
        rc, out = self._manual({"write_ts": 1_700_000_900})
        self.assertEqual(rc, 1, out)
        self.assertIn("MISSING_SNAPSHOT_EVIDENCE", out)
        self.assertIn("SNAPSHOT_MISSING", out)

    # 양성(차단) — 수기 make_ok, 스냅샷이 첫 쓰기 뒤
    def test_k18_manual_make_ok_snapshot_after_write_blocked(self):
        rc, out = self._manual({"write_ts": 1_700_000_000}, snap_mtime=1_700_000_500)
        self.assertEqual(rc, 1, out)
        self.assertIn("SNAPSHOT_AFTER_WRITE", out)

    # C26 rev4 — DB 무접촉 면제 조기 통과 우회 재현: 변경 파일에 DB 코드 없음 + item_crud:true + 스냅샷 없음
    def _clean(self, rec_extra=None, with_make_ok=True):
        self._criteria([dict(self.INSPECT_ITEM), dict(self.CRUD_ITEM)])
        self._assignment({"odev-1": {"files": [self.write(self.repo, "hooks/a.sh", self.SH)]}})
        if with_make_ok:
            rec = {"id": "AC-C", "status": "PASS", "write_log": "[PMS] 저장 완료(UI→GW)",
                   "count_before": 1, "count_after": 2, "write_ts": 1_700_000_900}
            rec.update(rec_extra or {})
            self._make_ok([rec])
        return self.run_gate()

    # 양성(차단) — 종전엔 NON_CRUD_EXEMPT_DB_UNTOUCHED 로 rc=0 이던 우회 경로
    def test_k20_db_untouched_exempt_no_longer_bypasses_snapshot(self):
        rc, out = self._clean()
        self.assertEqual(rc, 1, out)
        self.assertIn("MISSING_SNAPSHOT_EVIDENCE", out)
        self.assertNotIn("NON_CRUD_EXEMPT_DB_UNTOUCHED", out)

    # 양성(차단) — make_ok 없이 --final 로 무접촉 면제에 기대는 경로
    def test_k21_db_untouched_final_without_make_ok_blocked(self):
        rc, out = self._clean(with_make_ok=False)
        self.assertEqual(rc, 1, out)
        self.assertIn("SNAPSHOT_MISSING", out)

    # 음성(면제 유지) — live_rows:false 명시 항목은 종전대로 무접촉 면제
    def test_k22_db_untouched_live_rows_false_still_exempt(self):
        rc, out = self._clean({"live_rows": False})
        self.assertEqual(rc, 0, out)
        self.assertIn("NON_CRUD_EXEMPT_DB_UNTOUCHED", out)

    # 음성(통과) — 수기 make_ok, 스냅샷 선행
    def test_k19_manual_make_ok_snapshot_before_write_passes(self):
        rc, out = self._manual({"write_ts": 1_700_000_900}, snap_mtime=1_700_000_000)
        self.assertEqual(rc, 0, out)
        self.assertIn("CRUD_EVIDENCE_OK", out)


# ── 2026-10-10 conv_179160716700: F-CRUD-1 오탐 근본 수정 회귀 ──
#   R1 untracked 기준선(write_guard 가 보관한 편집 직전 원본) diff + 미변경 skip,
#   R2 부정 복합어 제거. 음성 케이스(진짜 DML 추가·기준선 위조·이전 파이프라인 기준선)는 여전히 차단.
#   DML 문자열은 런타임 조립한다(이 파일은 판정기 자기 파일 예외지만 사본·이동 시를 대비).
_DML = "INS" + "ERT INTO t VALUES (1)"


def _read(path):
    with open(path, encoding="utf-8") as fp:
        return fp.read()


def _load_verify_module():
    import importlib.util
    sys.dont_write_bytecode = True  # 저장소에 __pycache__ 를 남기지 않는다
    spec = importlib.util.spec_from_file_location("verify_crud_executed_mod", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _set_start_ok(self, value):
    # 정상 ok 진입처럼 pipeline_start_time 과 evidence/ok_started 를 같은 값으로 기록한다(역라우팅 #2 — 부재는 무효).
    VerifyCrudFallbackTest.set_start(self, value)
    os.makedirs(os.path.join(self.sess, "evidence"), exist_ok=True)
    with open(os.path.join(self.sess, "evidence", "ok_started"), "w") as fp:
        fp.write(str(value))


class UntrackedBaselineTest(unittest.TestCase):
    setUp = VerifyCrudFallbackTest.setUp
    tearDown = VerifyCrudFallbackTest.tearDown
    write = staticmethod(VerifyCrudFallbackTest.write)
    set_start = _set_start_ok
    run_gate = VerifyCrudFallbackTest.run_gate
    _assign = VerifyCrudFallbackTest._assign

    REL = "hooks/tests/test_fixture.py"

    def _lines(self):
        lines = [f"x{i} = {i}" for i in range(40)]
        lines[2] = f"SQL = '{_DML}'"  # 파이프라인 이전부터 있던 픽스처 SQL
        return lines

    def _preexisting(self):
        # 시작 이전에 만든 untracked 파일 — ctime 은 되돌릴 수 없으므로 1초 넘게 기다린 뒤 시작을 찍는다.
        path = self.write(self.repo, self.REL, "\n".join(self._lines()) + "\n")
        time.sleep(1.2)
        self.set_start(int(time.time()))
        return path

    def _baseline(self, path, recorded=None, content=None):
        import hashlib
        real = os.path.realpath(path)
        bdir = os.path.join(self.sess, "baseline_untracked")
        os.makedirs(bdir, exist_ok=True)
        stem = os.path.join(bdir, hashlib.sha1(real.encode("utf-8")).hexdigest())
        with open(stem + ".orig", "w", encoding="utf-8") as fp:
            fp.write(content if content is not None else _read(path))
        with open(stem + ".path", "w", encoding="utf-8") as fp:
            fp.write((recorded or real) + "\n")
        return stem

    def _edit(self, path, idx, text, insert=False):
        lines = _read(path).split("\n")
        if insert:
            lines.insert(idx, text)
        else:
            lines[idx] = text
        with open(path, "w", encoding="utf-8") as fp:
            fp.write("\n".join(lines))

    def test_t1_baseline_non_db_edit_passes(self):
        path = self._preexisting()
        self._baseline(path)
        self._edit(path, 35, "x35 = 'changed'")
        self._assign([path])
        rc, out = self.run_gate()
        self.assertEqual(rc, 0, out)
        self.assertIn("DB_SCAN_BASELINE:", out)
        self.assertNotIn("DB_SCAN_FULL", out)
        self.assertNotIn("DB_CONTACT_DETECTED", out)

    def test_t2_baseline_added_dml_blocked(self):
        path = self._preexisting()
        self._baseline(path)
        self._edit(path, 30, f"Q2 = '{_DML}'", insert=True)
        self._assign([path])
        rc, out = self.run_gate()
        self.assertEqual(rc, 1, out)
        self.assertIn("DB_SCAN_BASELINE:", out)
        self.assertIn("DB_CONTACT_DETECTED", out)
        self.assertIn("L31+", out)

    def test_t3_no_baseline_untouched_skipped(self):
        path = self._preexisting()
        self._assign([path])
        rc, out = self.run_gate()
        self.assertEqual(rc, 0, out)
        self.assertIn("DB_SCAN_SKIP_PREEXISTING", out)
        self.assertNotIn("DB_CONTACT_DETECTED", out)

    def test_t4_no_baseline_changed_after_start_full_scan(self):
        path = self._preexisting()
        self._edit(path, 35, "x35 = 'changed'")  # 셸 편집 등 — 기준선 없음
        self._assign([path])
        rc, out = self.run_gate()
        self.assertEqual(rc, 1, out)
        self.assertIn("DB_SCAN_FULL", out)
        self.assertIn("DB_CONTACT_DETECTED", out)
        self.assertNotIn("DB_SCAN_SKIP_PREEXISTING", out)

    def test_t5_baseline_path_mismatch_ignored_full_scan(self):
        path = self._preexisting()
        # 다른 파일 기준선을 덮어쓰는 위조 — DML 없는 원본을 넣어도 .path 불일치면 무시된다.
        self._baseline(path, recorded=path + ".other", content="x = 1\n")
        self._edit(path, 35, "x35 = 'changed'")
        self._assign([path])
        rc, out = self.run_gate()
        self.assertEqual(rc, 1, out)
        self.assertIn("DB_SCAN_BASELINE_IGNORED", out)
        self.assertIn("불일치", out)
        self.assertIn("DB_SCAN_FULL", out)
        self.assertIn("DB_CONTACT_DETECTED", out)

    def test_t5b_previous_pipeline_baseline_ignored(self):
        # 이전 파이프라인에서 만든 기준선(시작 이전 생성)은 인정하지 않는다.
        path = self.write(self.repo, self.REL, "\n".join(self._lines()) + "\n")
        self._baseline(path, content="x = 1\n")
        time.sleep(1.2)
        self.set_start(int(time.time()))
        self._edit(path, 35, "x35 = 'changed'")
        self._assign([path])
        rc, out = self.run_gate()
        self.assertEqual(rc, 1, out)
        self.assertIn("이전 파이프라인 기준선", out)
        self.assertIn("DB_SCAN_FULL", out)
        self.assertIn("DB_CONTACT_DETECTED", out)

    def test_t5c_baseline_ignored_but_untouched_still_skipped(self):
        # 무효 기준선은 "없는 것" 으로 본다 — 파일 자체가 미변경이면 미변경 skip 이 그대로 적용된다.
        path = self.write(self.repo, self.REL, "\n".join(self._lines()) + "\n")
        self._baseline(path, recorded="/elsewhere")
        time.sleep(1.2)
        self.set_start(int(time.time()))
        self._assign([path])
        rc, out = self.run_gate()
        self.assertEqual(rc, 0, out)
        self.assertIn("DB_SCAN_BASELINE_IGNORED", out)
        self.assertIn("DB_SCAN_SKIP_PREEXISTING", out)

    def test_t5d_new_untracked_file_without_baseline_full_scan(self):
        # 이번 파이프라인에서 새로 만든 untracked 파일은 종전대로 전체 스캔(차단 유지).
        time.sleep(1.2)
        self.set_start(int(time.time()) - 1)
        path = self.write(self.repo, "hooks/new_tool.py", f"Q = '{_DML}'\n")
        self._assign([path])
        rc, out = self.run_gate()
        self.assertEqual(rc, 1, out)
        self.assertIn("DB_SCAN_FULL", out)
        self.assertIn("DB_CONTACT_DETECTED", out)


class StartTimeTrustTest(unittest.TestCase):
    """역라우팅 #1: pipeline_start_time 변조 시 완화 경로(기준선·미변경 skip)를 끄고 전체 스캔한다."""
    setUp = VerifyCrudFallbackTest.setUp
    tearDown = VerifyCrudFallbackTest.tearDown
    write = staticmethod(VerifyCrudFallbackTest.write)
    set_start = VerifyCrudFallbackTest.set_start
    run_gate = VerifyCrudFallbackTest.run_gate
    _assign = VerifyCrudFallbackTest._assign
    _baseline = UntrackedBaselineTest._baseline

    def _dml_file(self):
        # DML 이 든 신규 untracked 파일을 먼저 만든다(공격자의 선삽입).
        path = self.write(self.repo, "hooks/evil.sh", f"Q='{_DML}'\n")
        time.sleep(1.2)
        self._assign([path])
        return path

    def _ok_started(self, value):
        os.makedirs(os.path.join(self.sess, "evidence"), exist_ok=True)
        with open(os.path.join(self.sess, "evidence", "ok_started"), "w") as fp:
            fp.write(str(value))

    def _assert_full_blocked(self, out, rc, why):
        self.assertEqual(rc, 1, out)
        self.assertIn("START_TIME_UNTRUSTED", out)
        self.assertIn(why, out)
        self.assertIn("DB_SCAN_FULL", out)
        self.assertIn("DB_CONTACT_DETECTED", out)
        self.assertNotIn("DB_SCAN_SKIP_PREEXISTING", out)

    def test_s1_future_start_untrusted(self):
        self._dml_file()
        self.set_start(int(time.time()) + 3600)
        rc, out = self.run_gate()
        self._assert_full_blocked(out, rc, "미래")

    def test_s2_rewritten_start_ctime_late_untrusted(self):
        # 내용값이 파일 ctime 보다 120초 이상 이르다 = 나중에 다시 쓴 흔적.
        self._dml_file()
        self.set_start(int(time.time()) - 300)
        rc, out = self.run_gate()
        self._assert_full_blocked(out, rc, "나중에 다시 쓴 흔적")

    def test_s3_ok_started_mismatch_untrusted(self):
        # 시작시각을 DML 선삽입 직후로 다시 썼다(ctime≈내용값) — 진입 시 기록된 ok_started 와 어긋난다.
        self._ok_started(int(time.time()) - 600)
        self._dml_file()
        self.set_start(int(time.time()))
        rc, out = self.run_gate()
        self._assert_full_blocked(out, rc, "ok_started")

    def test_s4_baseline_also_disabled_when_untrusted(self):
        path = self._dml_file()
        self.set_start(int(time.time()) + 3600)
        self._baseline(path)  # 기준선이 있어도 시작시각을 못 믿으면 쓰지 않는다
        rc, out = self.run_gate()
        self._assert_full_blocked(out, rc, "미래")
        self.assertNotIn("DB_SCAN_BASELINE:", out)

    def test_s5_normal_start_with_ok_started_trusted(self):
        # 정상: 시작 이전 untracked 파일 + 시작시각·ok_started 일치 → 미변경 skip 유지.
        self._dml_file()
        now = int(time.time())
        self._ok_started(now)
        self.set_start(now)
        rc, out = self.run_gate()
        self.assertEqual(rc, 0, out)
        self.assertNotIn("START_TIME_UNTRUSTED", out)
        self.assertIn("DB_SCAN_SKIP_PREEXISTING", out)

    def test_s6_ok_started_missing_untrusted(self):
        # 역라우팅 #2: ok_started 삭제 + 시작시각 재기록 → (c) 교차 확인 무력화 시도. 부재 자체를 무효로 본다.
        self._dml_file()
        self.set_start(int(time.time()))
        rc, out = self.run_gate()
        self._assert_full_blocked(out, rc, "ok_started_missing")

    def test_s7_ok_started_missing_baseline_also_unused(self):
        path = self._dml_file()
        self.set_start(int(time.time()))
        self._baseline(path)
        rc, out = self.run_gate()
        self._assert_full_blocked(out, rc, "ok_started_missing")
        self.assertNotIn("DB_SCAN_BASELINE:", out)


class NegatedCompoundTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mod = _load_verify_module()

    def crud(self, desc, verify=""):
        return self.mod.is_crud_item({"description": desc, "verify": verify}, trust_item_crud=False)

    def test_t6_negated_compound_alone_not_crud(self):
        self.assertFalse(self.crud("PROJECT_LOCAL 무변경, 2회 실행 시 무변경"))
        self.assertFalse(self.crud("설정 파일은 변경되지 않는다", "diff 결과 변경 없음"))
        self.assertFalse(self.crud("기존 hook 은 수정되지 않고 미변경 상태로 남는다"))

    def test_t6_other_crud_word_in_same_sentence_still_crud(self):
        self.assertTrue(self.crud("레코드 저장 후 무변경 확인"))
        self.assertTrue(self.crud("변경 없음을 확인하되 UPDATE 반영 행수를 본다"))
        self.assertTrue(self.crud("무변경 2회 실행 후 설정 변경 시 재적용"))
        self.assertTrue(self.crud("고아 파일 삭제하지 않음"))  # 목록 밖 부정형은 CRUD 쪽으로 남는다

    def test_t6_plain_crud_unchanged(self):
        self.assertTrue(self.crud("사용자 정보를 저장한다"))
        self.assertTrue(self.crud("inbox 삭제 시 exit 2"))  # 비DB 삭제는 어휘로 구분하지 않는다(L-466)


class PrevPipelineFalsePositiveTest(unittest.TestCase):
    """직전 파이프라인 오탐(AC-008 '무변경', AC-009/010 inbox '삭제' + untracked 테스트 픽스처 SQL) 재현."""
    setUp = VerifyCrudFallbackTest.setUp
    tearDown = VerifyCrudFallbackTest.tearDown
    write = staticmethod(VerifyCrudFallbackTest.write)
    set_start = _set_start_ok
    run_gate = VerifyCrudFallbackTest.run_gate
    _assign = VerifyCrudFallbackTest._assign
    _baseline = UntrackedBaselineTest._baseline
    _edit = UntrackedBaselineTest._edit

    ACS = [
        ("AC-008", "PROJECT_LOCAL 무변경, 2회 실행 시 무변경", "bash test_sync.sh 2회 실행 후 diff"),
        ("AC-009", "inbox 보존 / 고아 삭제", "bash test_inbox.sh (b) 실행 결과 확인"),
        ("AC-010", "inbox 삭제 시 exit 2", "bash test_inbox.sh (c) rc 확인"),
    ]

    def _setup(self):
        data = {"crud_대상": False, "crud_미해당_사유": "hook 셸 스크립트·테스트 수정 작업으로 DB 변경 없음",
                "criteria": [{"id": i, "item_crud": False, "category": "hook", "priority": "must",
                              "description": d, "verify": v, "expected": "PASS"} for i, d, v in self.ACS]}
        with open(self.criteria, "w", encoding="utf-8") as fp:
            json.dump(data, fp, ensure_ascii=False)
        fixture = "\n".join([f"y{i}={i}" for i in range(30)] + [f"CASE='{_DML}'"]) + "\n"
        # 확장자를 .sh 로 둔다 — 임시 저장소 디렉터리명이 'repo' 라 *.py 는 CRUD_SUSPECT_PATTERN 의
        # repo/ 세그먼트(경로 축)에 걸린다. 실제 오탐 경로(.claude/hooks/tests/)는 경로 축 비대상이었다.
        path = self.write(self.repo, "hooks/tests/test_c168_gates.sh", fixture)
        sh = self.write(self.repo, "hooks/sync.sh", "#!/bin/sh\necho ok\n")
        time.sleep(1.2)
        self.set_start(int(time.time()))
        return path, sh

    def test_t7_prev_false_positives_pass_with_baseline(self):
        path, sh = self._setup()
        self._baseline(path)
        self._edit(path, 5, "y5 = 'edited'")  # 픽스처 SQL 과 먼 줄만 편집
        with open(sh, "a", encoding="utf-8") as fp:
            fp.write("echo more\n")
        self._assign([path, sh])
        rc, out = self.run_gate()
        self.assertEqual(rc, 0, out)
        self.assertNotIn("CONTENT_OVERRIDE_FACT_BLOCKED", out)
        self.assertNotIn("DB_CONTACT_DETECTED", out)

    def test_t7_prev_false_positives_pass_untouched_fixture(self):
        path, sh = self._setup()
        with open(sh, "a", encoding="utf-8") as fp:
            fp.write("echo more\n")
        self._assign([path, sh])
        rc, out = self.run_gate()
        self.assertEqual(rc, 0, out)
        self.assertIn("DB_SCAN_SKIP_PREEXISTING", out)
        self.assertNotIn("CONTENT_OVERRIDE_FACT_BLOCKED", out)

    def test_t7_real_dml_added_still_blocked(self):
        # 같은 AC 라도 변경 파일에 DML 이 새로 들어가면 사실 축이 차단한다(거짓 완료 차단 유지).
        path, sh = self._setup()
        self._baseline(path)
        self._edit(path, 5, f"NEW = '{_DML}'", insert=True)
        self._assign([path, sh])
        rc, out = self.run_gate()
        self.assertEqual(rc, 1, out)
        self.assertIn("CONTENT_OVERRIDE_FACT_BLOCKED: 실측 사유=db_found", out)
        self.assertIn("MISSING_CRUD_EVIDENCE", out)
        self.assertNotIn("CRUD 의심 AC: AC-008", out)  # '무변경' 은 더 이상 CRUD 로 읽히지 않는다


class PathAxisUntouchedSkipTest(unittest.TestCase):
    """(5) 경로 축(CRUD_SUSPECT_PATTERN) 미변경 skip — 기준선 diff 없이 '손대지 않은 파일' 만 제외한다."""
    setUp = VerifyCrudFallbackTest.setUp
    tearDown = VerifyCrudFallbackTest.tearDown
    write = staticmethod(VerifyCrudFallbackTest.write)
    set_start = _set_start_ok
    run_gate = VerifyCrudFallbackTest.run_gate
    _assign = VerifyCrudFallbackTest._assign
    _baseline = UntrackedBaselineTest._baseline

    REL = "services/order_store.py"

    def _declare_non_crud(self):
        data = dict(FIXTURE_AC)
        data["crud_대상"] = False
        data["crud_미해당_사유"] = "hook 셸 스크립트 수정 작업으로 DB 변경 없음"
        with open(self.criteria, "w", encoding="utf-8") as fp:
            json.dump(data, fp, ensure_ascii=False)

    def _suspect(self, trusted=True):
        # 시작 이전에 만든 의심 경로 untracked 파일(기존 SQL 픽스처 포함). ctime 여유를 위해 1.5초 대기.
        self._declare_non_crud()
        path = self.write(self.repo, self.REL, f"Q = '{_DML}'\n" + "x = 1\n" * 20)
        time.sleep(1.5)
        if trusted:
            self.set_start(int(time.time()))
        else:
            VerifyCrudFallbackTest.set_start(self, int(time.time()))  # evidence/ok_started 부재 → 불신
        self._assign([path])
        return path

    def _assert_path_blocked(self, rc, out):
        self.assertEqual(rc, 1, out)
        self.assertNotIn("CRUD_PATH_SKIP_PREEXISTING", out)
        self.assertIn("CRUD_DECLARATION_OVERRIDDEN", out)
        self.assertIn("경로 기인", out)

    def test_p1_untouched_suspect_skipped(self):
        path = self._suspect()
        rc, out = self.run_gate()
        self.assertEqual(rc, 0, out)
        self.assertIn(f"CRUD_PATH_SKIP_PREEXISTING: {path}", out)
        self.assertEqual(out.count("CRUD_PATH_SKIP_PREEXISTING"), 1, out)  # 소비처 여러 곳이어도 1회 출력
        self.assertNotIn("경로 기인", out)  # 픽스처 AC-004 의 AC 내용 기인 판정은 이 시험의 대상이 아니다
        self.assertNotIn("CRUD 의심 파일", out)

    def test_p2_changed_suspect_full_scan_blocked(self):
        path = self._suspect()
        with open(path, "a", encoding="utf-8") as fp:
            fp.write("y = 2\n")  # 기준선 없음(untracked·base 없음) → 먼 줄만 수정해도 파일 전체 판독으로 차단(c197 이후에도 유지)
        rc, out = self.run_gate()
        self._assert_path_blocked(rc, out)

    def test_p2b_changed_suspect_with_baseline_still_blocked(self):
        # [c197 기대값 변경 — 사용자 결정 '쓰기 문장 기준'(18:4x)·리드 승인] 종전(L-467)은 기준선이 있어도 경로 축을
        #   파일 전체로 봤다. c197 사용자 결정으로 경로 축은 변경 줄 ±10줄(DB_CONTEXT_WINDOW)의 쓰기 토큰 기준이다.
        #   ⇒ 기준선이 있고 DML(1행)에서 먼 줄(22행)만 바꾸면 경로 기인 무효화가 아니다(CRUD_PATH_SUSPECT_CLEARED).
        #   전체 rc 는 픽스처 AC-004 의 AC 내용 기인 차단으로 여전히 1 이다. 기준선이 없으면 p2 대로 파일 전체 판독·차단.
        #   함수 이름은 이력 보존을 위해 그대로 둔다(still_blocked = 전체 rc 1 유지).
        path = self._suspect()
        self._baseline(path)
        with open(path, "a", encoding="utf-8") as fp:
            fp.write("y = 2\n")
        rc, out = self.run_gate()
        self.assertEqual(rc, 1, out)
        self.assertIn("CRUD_PATH_SUSPECT_CLEARED", out)
        self.assertNotIn("경로 기인", out)
        self.assertNotIn("CRUD_PATH_SKIP_PREEXISTING", out)

    def test_p2c_baseline_write_token_in_changed_line_blocked(self):
        # [c197 진양성 쌍] 기준선이 있어도 변경 줄(또는 ±10줄)에 쓰기 토큰이 있으면 종전대로 경로 기인 차단이다.
        path = self._suspect()
        self._baseline(path)
        with open(path, "a", encoding="utf-8") as fp:
            fp.write(f"W = '{_DML}'\n")
        rc, out = self.run_gate()
        self._assert_path_blocked(rc, out)
        self.assertIn("쓰기 토큰(변경 범위)", out)

    def test_p3_untrusted_start_no_skip(self):
        self._suspect(trusted=False)
        rc, out = self.run_gate()
        self._assert_path_blocked(rc, out)
        self.assertIn("START_TIME_UNTRUSTED", out)

    def test_p4_touch_mtime_back_ctime_blocks_skip(self):
        path = self._suspect()
        with open(path, "a", encoding="utf-8") as fp:
            fp.write("y = 2\n")
        subprocess.run(["touch", "-d", "-2 hours", path], check=True)  # mtime 만 되돌린다 — ctime 은 남는다
        self.assertLess(os.stat(path).st_mtime, int(time.time()) - 3600)
        rc, out = self.run_gate()
        self._assert_path_blocked(rc, out)

    def test_p5_missing_suspect_kept(self):
        self._declare_non_crud()
        time.sleep(1.5)
        self.set_start(int(time.time()))
        self._assign([os.path.join(self.repo, "services", "gone_store.py")])  # 부재 — stat 실패는 suspect 유지
        rc, out = self.run_gate()
        self._assert_path_blocked(rc, out)


TRIAGE = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                       "..", "..", "..", "hooks", "lib", "crud_fail_triage.py"))


class ExcludeTestFixturesTest(unittest.TestCase):
    """2026-10-11 역라우팅 #2: --exclude-test-fixtures(DB 접촉 축 한정) + DB_HITS_TEST_FIXTURE_ONLY 정보 줄.

    START_TIME_UNTRUSTED(ok_started 없음) 로 종전 전체 스캔을 태워 픽스처 파일의 DML 이 확실히 매치되게 한다.
    경로는 .sh 로 둔다 — 임시 저장소 디렉터리명 'repo' 가 *.py 경로 축에 걸리는 것을 피한다.
    """
    setUp = VerifyCrudFallbackTest.setUp
    tearDown = VerifyCrudFallbackTest.tearDown
    write = staticmethod(VerifyCrudFallbackTest.write)
    set_start = VerifyCrudFallbackTest.set_start
    _assign = VerifyCrudFallbackTest._assign

    def gate(self, *extra):
        env = dict(os.environ)
        env.pop("CLAUDE_PROJECT_DIR", None)
        proc = subprocess.run(
            [sys.executable, SCRIPT, "--criteria", self.criteria,
             "--evidence", self.evidence, "--final"] + list(extra),
            cwd=self.repo, env=env, capture_output=True, text=True, timeout=60,
        )
        return proc.returncode, proc.stdout + proc.stderr

    def _fixture(self, rel="hooks/tests/test_gate_cases.sh"):
        return self.write(self.repo, rel, f"#!/bin/sh\nCASE='{_DML}'\n")

    def _plain(self):
        return self.write(self.repo, "hooks/run.sh", "#!/bin/sh\necho ok\n")

    def test_default_without_exclude_test_fixtures_keeps_verdict_and_emits_info(self):
        self.set_start(int(time.time()) - 5)
        self._assign([self._fixture(), self._plain()])
        rc, out = self.gate()
        self.assertEqual(rc, 1, out)  # 기본 판정 무변경
        self.assertIn("DB_CONTACT_DETECTED", out)
        self.assertIn("DB_HITS_TEST_FIXTURE_ONLY: 1", out)
        self.assertNotIn("DB_SCAN_TEST_FIXTURE_EXCLUDED", out)

    def test_exclude_test_fixtures_passes_when_hits_are_fixture_only(self):
        self.set_start(int(time.time()) - 5)
        fx = self._fixture()
        self._assign([fx, self._plain()])
        rc, out = self.gate("--exclude-test-fixtures")
        self.assertEqual(rc, 0, out)
        self.assertIn(f"DB_SCAN_TEST_FIXTURE_EXCLUDED: {fx}:", out)
        self.assertIn("NON_CRUD_EXEMPT_DB_UNTOUCHED", out)
        self.assertNotIn("DB_HITS_TEST_FIXTURE_ONLY", out)

    def test_exclude_test_fixtures_keeps_non_fixture_dml_blocked(self):
        # 픽스처가 아닌 파일의 DML 은 옵션과 무관하게 남는다(선언·경로 회피 통로 아님).
        self.set_start(int(time.time()) - 5)
        real = self.write(self.repo, "hooks/store.sh", f"#!/bin/sh\nQ='{_DML}'\n")
        self._assign([self._fixture(), real])
        rc, out = self.gate("--exclude-test-fixtures")
        self.assertEqual(rc, 1, out)
        self.assertIn("DB_SCAN_TEST_FIXTURE_EXCLUDED", out)
        self.assertIn(f"  - {real}:", out)
        self.assertNotIn("DB_HITS_TEST_FIXTURE_ONLY", out)
        rc0, out0 = self.gate()  # 기본 모드도 섞여 있으면 정보 줄을 내지 않는다
        self.assertEqual(rc0, 1, out0)
        self.assertNotIn("DB_HITS_TEST_FIXTURE_ONLY", out0)

    def test_exclude_test_fixtures_still_fails_closed_on_unreadable_fixture(self):
        self.set_start(int(time.time()) - 5)
        bad = os.path.join(self.repo, "hooks", "fixtures", "broken.sh")
        os.makedirs(os.path.dirname(bad), exist_ok=True)
        with open(bad, "wb") as fp:
            fp.write(b"\xff\xfe\xfa INSERT")
        self._assign([bad, self._fixture()])
        rc, out = self.gate("--exclude-test-fixtures")
        self.assertEqual(rc, 1, out)
        self.assertIn("DB_SCAN_UNVERIFIABLE", out)

    def test_exclude_test_fixtures_regex_cases(self):
        sys.path.insert(0, os.path.dirname(SCRIPT))
        try:
            import verify_crud_executed as v
        finally:
            sys.path.pop(0)
        for p in ("a/tests/x.sql", "a/test/x.cs", "a/__tests__/x.js", "a/fixtures/x.sql", "a/fixture/x",
                  "tests/x.sh", "a/test_x.py", "a/test_x.sh", "a/x_test.py", "a\\tests\\x.sql"):
            self.assertTrue(v._is_test_fixture(p), p)
        for p in ("a/latest/x.sql", "a/mytests/x.sql", "a/test_x.sql", "a/contest.py", "a/Tests/x.sql",
                  "a/attest_x.py", "a/x_test.cs", "a/testdata.py"):
            self.assertFalse(v._is_test_fixture(p), p)

    def test_exclude_test_fixtures_triage_recheck_flow(self):
        # 기본 FAIL 출력 → 분류기 RECHECK → --exclude-test-fixtures 재판정 rc 0 (통과는 판정기만 준다)
        self.set_start(int(time.time()) - 5)
        self._assign([self._fixture(), self._plain()])
        rc, out = self.gate()
        tri = subprocess.run([sys.executable, TRIAGE, "--rc", str(rc)], input=out,
                             capture_output=True, text=True, timeout=10)
        self.assertEqual(tri.returncode, 0)
        self.assertTrue(tri.stdout.startswith("CLASS=TEST_FIXTURE_ONLY ACTION=RECHECK HINT="), tri.stdout)
        self.assertEqual(len(tri.stdout.strip().splitlines()), 1)
        rc2, out2 = self.gate("--exclude-test-fixtures")
        self.assertEqual(rc2, 0, out2)


class DocNameMentionTest(unittest.TestCase):
    """2026-10-20 역라우팅 #1 (conv_179239511726): 문서·설정 파일의 DB 이름 단독 언급은 DB 접촉이 아니다.

    미추적 파일은 START_TIME_UNTRUSTED(ok_started 없음) 로 전체 스캔, 추적 파일(README.md) 수정은 git diff 경로를 탄다.
    """
    setUp = VerifyCrudFallbackTest.setUp
    tearDown = VerifyCrudFallbackTest.tearDown
    write = staticmethod(VerifyCrudFallbackTest.write)
    set_start = VerifyCrudFallbackTest.set_start
    _assign = VerifyCrudFallbackTest._assign
    gate = ExcludeTestFixturesTest.gate

    def _run(self, rel, body):
        self.set_start(int(time.time()) - 5)
        path = self.write(self.repo, rel, body)
        self._assign([path])
        rc, out = self.gate()
        return path, rc, out

    def test_doc_md_bare_mysql_is_clean(self):  # (a)
        path, rc, out = self._run("docs/handoff.md", "# 핸드오프\nAC-006 mysql MCP tools/list 조회\n")
        self.assertEqual(rc, 0, out)
        self.assertIn(f"DB_NAME_MENTION_DOC_EXCLUDED: {path}:", out)
        self.assertIn("NON_CRUD_EXEMPT_DB_UNTOUCHED", out)
        self.assertNotIn("DB_CONTACT_DETECTED", out)

    def test_config_json_bare_mysql_is_clean(self):  # (b)
        path, rc, out = self._run("conf/servers.json",
                                  '{"mcpServers": {"mysql": {"command": "/opt/mysql-mcp/run"}}}\n')
        self.assertEqual(rc, 0, out)
        self.assertIn(f"DB_NAME_MENTION_DOC_EXCLUDED: {path}:", out)
        self.assertNotIn("DB_CONTACT_DETECTED", out)

    def test_doc_md_dml_still_db_found(self):  # (c)
        path, rc, out = self._run("docs/handoff.md", f"# 핸드오프\nmysql 에서 {_DML} 실행\n")
        self.assertEqual(rc, 1, out)
        self.assertIn("DB_CONTACT_DETECTED", out)
        self.assertIn(f"  - {path}:", out)
        self.assertNotIn("DB_NAME_MENTION_DOC_EXCLUDED", out)

    def test_code_sh_bare_mysql_still_db_found(self):  # (d)
        path, rc, out = self._run("hooks/dbcheck.sh", "#!/bin/sh\nmysql -e status\n")
        self.assertEqual(rc, 1, out)
        self.assertIn("DB_CONTACT_DETECTED", out)
        self.assertNotIn("DB_NAME_MENTION_DOC_EXCLUDED", out)

    def test_extensionless_script_bare_mysql_still_db_found(self):
        path, rc, out = self._run("bin/dbcheck", "#!/bin/sh\nmysql -e status\n")
        self.assertEqual(rc, 1, out)
        self.assertIn("DB_CONTACT_DETECTED", out)
        self.assertNotIn("DB_NAME_MENTION_DOC_EXCLUDED", out)

    def _diff_readme(self, extra):
        time.sleep(1.2)  # init 커밋이 시작시각 이전이 되도록
        self.set_start(int(time.time()))
        readme = os.path.join(self.repo, "README.md")
        with open(readme, "a", encoding="utf-8") as fp:
            fp.write(extra)
        self._assign([readme])
        return readme, *self.gate()

    def test_tracked_md_diff_bare_mysql_is_clean(self):
        readme, rc, out = self._diff_readme("mysql MCP 조회 절차\n")
        self.assertEqual(rc, 0, out)
        self.assertIn(f"DB_NAME_MENTION_DOC_EXCLUDED: {readme}:", out)
        self.assertNotIn("DB_SCAN_FULL", out)

    def test_tracked_md_diff_dml_near_name_still_db_found(self):
        # 첫 매치가 이름(mysql)이어도 같은 범위의 DML 을 다시 찾아 db_found 로 둔다.
        readme, rc, out = self._diff_readme(f"mysql 조회\n{_DML}\n")
        self.assertEqual(rc, 1, out)
        self.assertIn("DB_CONTACT_DETECTED", out)
        self.assertNotIn("DB_NAME_MENTION_DOC_EXCLUDED", out)

    def test_doc_unreadable_still_fails_closed(self):
        self.set_start(int(time.time()) - 5)
        bad = os.path.join(self.repo, "docs", "broken.md")
        os.makedirs(os.path.dirname(bad), exist_ok=True)
        with open(bad, "wb") as fp:
            fp.write(b"\xff\xfe mysql")
        self._assign([bad])
        rc, out = self.gate()
        self.assertEqual(rc, 1, out)
        self.assertIn("DB_SCAN_UNVERIFIABLE", out)


class CodeNameMentionTest(unittest.TestCase):
    """2026-10-24 (conv_179279890015 후속): 코드 파일의 DB 이름 언급(주석·정규식 리터럴·다른 명령의 인자 문자열)은
    DB 접근 형태가 없으면 DB 접촉이 아니다. 접근 형태(명령 위치 CLI·import·connect·Queries 경로·파싱 실패)는 그대로 차단한다.

    미추적 파일은 START_TIME_UNTRUSTED 로 전체 스캔, 추적 파일 수정은 git diff 경로를 탄다.
    """
    tearDown = VerifyCrudFallbackTest.tearDown
    write = staticmethod(VerifyCrudFallbackTest.write)
    set_start = VerifyCrudFallbackTest.set_start
    _assign = VerifyCrudFallbackTest._assign
    gate = ExcludeTestFixturesTest.gate

    def setUp(self):
        # 임시 저장소 디렉터리명 'repo' 는 CRUD_SUSPECT_PATTERN(repo/ 하위 .py·.cs) 에 걸려 '대상 외 경로' 가 되므로
        # 코드 파일 사례는 중립 이름 'proj' 로 옮겨 실제 접근 형태 판정이 돌게 한다.
        VerifyCrudFallbackTest.setUp(self)
        moved = os.path.join(self.tmp.name, "proj")
        os.rename(self.repo, moved)
        self.repo = moved

    INFO = "DB_NAME_MENTION_CODE_EXCLUDED"
    PY_MENTION = (
        "# DB 이름 언급 주석: mysql 접속 여부를 판정하는 정규식을 정의한다.\n"
        "# 자격증명 마스킹용 — mariadb 도 같이 본다.\n"
        "import re\n"
        "PAT = re.compile(r\"(?i)\\b(mysql\\w*|mariadb\\w*)\\b\")\n"
    )

    def _run(self, rel, body):
        self.set_start(int(time.time()) - 5)
        path = self.write(self.repo, rel, body)
        self._assign([path])
        rc, out = self.gate()
        return path, rc, out

    def _assert_found(self, rc, out):
        self.assertEqual(rc, 1, out)
        self.assertIn("DB_CONTACT_DETECTED", out)
        self.assertNotIn(self.INFO, out)

    def test_py_comment_and_regex_literal_mysql_is_clean(self):
        path, rc, out = self._run("lib/pda_core.py", self.PY_MENTION)
        self.assertEqual(rc, 0, out)
        self.assertIn(f"{self.INFO}: {path}:", out)
        self.assertNotIn("DB_CONTACT_DETECTED", out)

    def test_sh_mysql_as_other_command_argument_is_clean(self):
        body = ("#!/bin/sh\n# mysql 주석\n"
                "D \"M1\" \"$(bx \"mysql -uroot -pX -e 'select 1'; bash $DP\")\"\n")
        path, rc, out = self._run("hooks/pda_check.sh", body)
        self.assertEqual(rc, 0, out)
        self.assertIn(f"{self.INFO}: {path}:", out)
        self.assertNotIn("DB_CONTACT_DETECTED", out)

    def test_sh_command_position_mysql_still_db_found(self):
        self._assert_found(*self._run("hooks/a.sh", "#!/bin/sh\nx=1; mysql -e status\n")[1:])

    def test_sh_subshell_and_ssh_string_still_db_found(self):
        for body in ("#!/bin/sh\nr=$(mysql -N -e q)\n", "#!/bin/sh\nssh h \"mysql db < x\"\n"):
            self._assert_found(*self._run("hooks/b.sh", body)[1:])

    def test_py_import_pymysql_still_db_found(self):
        self._assert_found(*self._run("lib/c.py", "import pymysql\n")[1:])

    def test_py_subprocess_cli_list_still_db_found(self):
        body = "import subprocess\nsubprocess.run([\"mysql\", \"-e\", \"status\"])\n"
        self._assert_found(*self._run("lib/d.py", body)[1:])

    def test_py_cli_command_string_still_db_found(self):
        self._assert_found(*self._run("lib/e.py", "cmd = \"mysql -uroot -e status\"\n")[1:])

    def test_py_dml_string_still_db_found(self):
        self._assert_found(*self._run("lib/f.py", f"Q = \"{_DML}\"\n")[1:])

    def test_sql_comment_only_still_db_found(self):
        self._assert_found(*self._run("db/m.sql", "-- mysql 메모\n")[1:])

    def test_queries_and_services_paths_still_db_found(self):
        for rel in ("Queries/UserQueries.cs", "Services/UserService.cs"):
            self._assert_found(*self._run(rel, "// cspms 메모\nclass A { }\n")[1:])

    def test_unparsable_py_and_unknown_ext_still_db_found(self):
        self._assert_found(*self._run("lib/bad.py", "def f(:\n x='mysql'\n")[1:])
        self._assert_found(*self._run("lib/a.rb", "# mysql\n")[1:])

    def test_cs_using_mysql_still_db_found(self):
        self._assert_found(*self._run("lib/a.cs", "using MySql.Data.MySqlClient;\n")[1:])

    def test_tracked_py_diff_comment_mysql_is_clean(self):
        path = self.write(self.repo, "lib/x.py", "x = 1\n")
        _git(self.repo, "add", "-A")
        _git(self.repo, "commit", "-qm", "add x")
        time.sleep(1.2)  # 커밋이 시작시각 이전이 되도록
        self.set_start(int(time.time()))
        with open(path, "a", encoding="utf-8") as fp:
            fp.write("# mysql 설명\n")
        self._assign([path])
        rc, out = self.gate()
        self.assertEqual(rc, 0, out)
        self.assertIn(f"{self.INFO}: {path}:", out)
        self.assertNotIn("DB_CONTACT_DETECTED", out)

    def test_content_override_cleared_with_code_mention(self):
        # AC 본문 '저장/등록' 어휘로 content 무효화가 나도, 코드 파일의 이름 언급만 있으면 실측 해제된다.
        data = {"crud_대상": False, "crud_미해당_사유": "hook 수정 작업으로 DB 변경 없음",
                "criteria": [{"id": "AC-X", "item_crud": False, "category": "infra", "priority": "must",
                              "description": "사용자 정보를 저장하고 DB 에 등록한다 — reason 수정은 의도된 변경이다",
                              "method": "로그의 PASS 확인", "expected": "PASS"}]}
        with open(self.criteria, "w", encoding="utf-8") as fp:
            json.dump(data, fp, ensure_ascii=False)
        path, rc, out = self._run("lib/pda_core.py", self.PY_MENTION)
        self.assertEqual(rc, 0, out)
        self.assertIn("CONTENT_OVERRIDE_FACT_CLEARED", out)
        self.assertIn(f"{self.INFO}: {path}:", out)


class CrudFailTriageTest(unittest.TestCase):
    """hooks/lib/crud_fail_triage.py 6종 분류 단위 시험 — 분류만 하고 항상 rc 0."""

    def tri(self, text, rc):
        args = [sys.executable, TRIAGE] + ([] if rc is None else ["--rc", str(rc)])
        proc = subprocess.run(args, input=text, capture_output=True, text=True, timeout=10)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(len(proc.stdout.strip().splitlines()), 1, proc.stdout)
        return proc.stdout.strip()

    def test_six_classes(self):
        cases = [
            ("DB_CONTACT_DETECTED: x\nDB_HITS_TEST_FIXTURE_ONLY: 2\nMISSING_CRUD_EVIDENCE: y\n", 1,
             "CLASS=TEST_FIXTURE_ONLY ACTION=RECHECK"),
            ("CRUD_DECLARATION_OVERRIDDEN: a\nMISSING_CRUD_EVIDENCE: b\n", 1,
             "CLASS=DECLARATION_CONFLICT ACTION=REROUTE_PLAN"),
            ("MISSING_CRUD_EVIDENCE: a\n", 1, "CLASS=EVIDENCE_MISSING ACTION=REROUTE_DEV"),
            ("MISSING_SNAPSHOT_EVIDENCE: a\n", 1, "CLASS=EVIDENCE_MISSING ACTION=REROUTE_DEV"),
            ("DB_SCAN_UNVERIFIABLE: a\n", 1, "CLASS=SCAN_UNVERIFIABLE ACTION=REROUTE_DEV"),
            ("INPUT_ERROR: x\n", 2, "CLASS=INPUT_ERROR ACTION=RETRY_AFTER_FIX"),
            ("", 2, "CLASS=INPUT_ERROR ACTION=RETRY_AFTER_FIX"),
            ("zzz\n", 1, "CLASS=UNKNOWN ACTION=REROUTE_DEV"),
        ]
        for text, rc, want in cases:
            self.assertTrue(self.tri(text, rc).startswith(want + " HINT="), (text, rc, want))

    def test_indented_quote_is_not_a_code(self):
        # 판정기가 들여써 옮겨 적은 파일 내용 안의 코드 문자열은 코드로 세지 않는다.
        out = self.tri("DB_CONTACT_DETECTED: x\n  - f.sh: DB_HITS_TEST_FIXTURE_ONLY: 3\n", 1)
        self.assertTrue(out.startswith("CLASS=UNKNOWN"), out)

    def test_bad_rc_and_no_rc_never_fail(self):
        self.assertTrue(self.tri("x", "abc").startswith("CLASS=UNKNOWN"))
        self.assertTrue(self.tri("", None).startswith("CLASS=UNKNOWN"))


# ── 사이클177 A12: 결함1(goal_id 별칭 정확 일치) · 결함2(PARTIAL 경로 스냅샷 선행) · 결함3(c)(--ac-records) ──
class C177HarnessTest(unittest.TestCase):
    setUp = VerifyCrudFallbackTest.setUp
    tearDown = VerifyCrudFallbackTest.tearDown
    write = staticmethod(VerifyCrudFallbackTest.write)
    run_gate = VerifyCrudFallbackTest.run_gate
    _criteria = C172FalsePositiveTest._criteria
    _assignment = C172FalsePositiveTest._assignment

    INSPECT = dict(C172FalsePositiveTest.INSPECT_ITEM)
    DB_SVC = C172FalsePositiveTest.DB_SVC
    EV_OK = {"result": "PASS", "write_log": "[PMS] 저장 완료", "count_before": 1, "count_after": 2}

    def _crud(self, iid, gid, evidence=None):
        item = dict(C172FalsePositiveTest.CRUD_ITEM, id=iid, goal_id=gid)
        if evidence:
            item["evidence"] = evidence
        return item

    def _evdir(self, files):
        evdir = os.path.join(self.tmp.name, "evd177")
        os.makedirs(evdir, exist_ok=True)
        for name, payload in files.items():
            with open(os.path.join(evdir, name), "w", encoding="utf-8") as fp:
                json.dump(payload, fp, ensure_ascii=False)
        return evdir

    def _db_assignment(self):
        # DB 코드 파일 — 무접촉 면제로 빠지지 않고 증거 검사 경로를 실제로 타게 한다
        self._assignment({"odev-1": {"files": [self.write(self.repo, "Svc/FooService.cs", self.DB_SVC)]}})

    def _emit(self, gate_stdout, gate_rc, extra=()):
        rows = os.path.join(self.tmp.name, "gate_rows.txt")
        with open(rows, "w", encoding="utf-8") as fp:
            fp.write(gate_stdout)
        gate = os.path.join(self.tmp.name, "fake_gate.sh")
        with open(gate, "w", encoding="utf-8") as fp:
            fp.write(f"#!/bin/bash\ncat '{rows}'\nexit {gate_rc}\n")
        env = dict(os.environ)
        env.pop("CLAUDE_PROJECT_DIR", None)
        proc = subprocess.run(
            [sys.executable, SCRIPT, "--emit-from-goal", "--criteria", self.criteria,
             "--evidence", self.evidence, "--gate-cmd", f"bash {gate}"] + list(extra),
            cwd=self.repo, env=env, capture_output=True, text=True, timeout=60,
        )
        return proc.returncode, proc.stdout + proc.stderr

    def _partial_path(self):
        return os.path.join(os.path.dirname(self.evidence), "make_partial")

    def _partial(self):
        with open(self._partial_path(), encoding="utf-8") as fp:
            return json.load(fp)

    # ── 결함1: goal_id 별칭 ──
    def _alias_case(self, gid, gate_rows):
        evdir = self._evdir({"AC-C.json": dict(self.EV_OK, live_rows=False)})
        self._criteria([self.INSPECT, self._crud("AC-C", gid, "AC-C.json")], {"evidence_dir": evdir})
        self._db_assignment()
        rc, out = self._emit(gate_rows, 1)
        self.assertEqual(rc, 1, out)
        return self.run_gate()

    # 양성 — 정확 일치: goal 행 G1 PASS 로 AC-C 를 찾고 AC 자신의 증거로 PARTIAL 인정(종전엔 "기록 없음 — 거부")
    def test_c177_alias_exact_match_acknowledged(self):
        rc, out = self._alias_case("G1", "G1\tPASS\trc=0\nG2\tFAIL\trc=1\n")
        self.assertEqual(rc, 0, out)
        self.assertIn("PARTIAL_ACKNOWLEDGED", out)
        self.assertIn("AC-C: goal G1 PASS(별칭) + 이 AC 의 CRUD 증거 확인", out)

    # 음성 — 불일치: goal_id 가 어느 행과도 같지 않으면 종전대로 거부
    def test_c177_alias_mismatch_rejected(self):
        rc, out = self._alias_case("G9", "G1\tPASS\trc=0\nG2\tFAIL\trc=1\n")
        self.assertEqual(rc, 1, out)
        self.assertIn("AC-C: make_partial 에 기록 없음 — 거부", out)

    # 음성 — 접두 일치 금지: goal_id G1 은 G12 행으로 매칭되지 않는다
    def test_c177_alias_prefix_rejected(self):
        rc, out = self._alias_case("G1", "G12\tPASS\trc=0\nG2\tFAIL\trc=1\n")
        self.assertEqual(rc, 1, out)
        self.assertIn("AC-C: make_partial 에 기록 없음", out)
        self.assertNotIn("PARTIAL_ACKNOWLEDGED", out)

    # 음성 — AC 단위 증거 유지: 같은 goal 아래 증거 없는 AC-D 는 goal 행 PASS 로 함께 통과하지 않는다
    #   [c197 (a) 기대값 변경 — 리드 승인] 종전에는 기록 단계가 AC-D 를 적지 않아 --final 이 '증거 없음 — 거부'(rc1)로
    #   뒤늦게 막았다. judge_rca §16-C 설계대로 기록 단계가 AC-D 를 not_passed(CRUD_EVIDENCE_MISSING)로 바로 드러내므로
    #   --final 은 PARTIAL 인정(rc0, 통과 아님)이어야 한다. 최종이 OK(make_ok·passed 포함)로 접히면 실패다.
    def test_c177_alias_requires_per_ac_evidence(self):
        evdir = self._evdir({"AC-C.json": dict(self.EV_OK, live_rows=False)})
        self._criteria([self.INSPECT, self._crud("AC-C", "G1", "AC-C.json"), self._crud("AC-D", "G1")],
                       {"evidence_dir": evdir})
        self._db_assignment()
        rc, out = self._emit("G1\tPASS\trc=0\nG2\tFAIL\trc=1\n", 1)
        self.assertEqual(rc, 1, out)
        partial = self._partial()
        np_ = {e["id"]: e["status"] for e in partial["not_passed"]}
        self.assertEqual(np_.get("AC-D"), "CRUD_EVIDENCE_MISSING", out)
        self.assertNotIn("AC-D", partial["passed"], out)
        self.assertFalse(os.path.isfile(self.evidence), out)  # make_ok 없음
        rc2, out2 = self.run_gate()
        self.assertEqual(rc2, 0, out2)
        self.assertIn("PARTIAL_ACKNOWLEDGED", out2)
        self.assertIn("AC-D: 미통과로 기록됨(PARTIAL)", out2)
        self.assertNotIn("AC-D: PASS + CRUD 증거 확인", out2)
        self.assertNotIn("AC-D: goal G1 PASS(별칭) + 이 AC 의 CRUD 증거 확인", out2)
        self.assertFalse(os.path.isfile(self.evidence), out2)  # 최종이 OK 로 접히지 않는다

    # 양성 — make_ok 경로: 게이트 전부 PASS(goal 행) + AC 자신의 증거 → make_ok 확정(종전엔 MAKE_OK_REFUSED_CRUD)
    def test_c177_alias_make_ok_path(self):
        evdir = self._evdir({"AC-C.json": dict(self.EV_OK, live_rows=False)})
        self._criteria([self.INSPECT, self._crud("AC-C", "G1", "AC-C.json")], {"evidence_dir": evdir})
        self._db_assignment()
        rc, out = self._emit("AC-I\tPASS\trc=0\nG1\tPASS\trc=0\n", 0)
        self.assertEqual(rc, 0, out)
        self.assertIn("MAKE_OK_FROM_GOAL", out)

    # 음성 — make_ok 경로에서도 증거 없는 AC 는 AC id 로 미통과 기록
    def test_c177_alias_make_ok_refused_lists_ac(self):
        self._criteria([self.INSPECT, self._crud("AC-D", "G1")])
        self._db_assignment()
        rc, out = self._emit("AC-I\tPASS\trc=0\nG1\tPASS\trc=0\n", 0)
        self.assertEqual(rc, 1, out)
        self.assertIn("MAKE_OK_REFUSED_CRUD", out)
        self.assertIn("AC-D", [e["id"] for e in self._partial()["not_passed"]])

    # ── 결함2: PARTIAL 인정 경로의 스냅샷 선행 검사 ──
    def _ack_case(self, rec_extra, snap=None, snap_mtime=None):
        now = int(time.time())
        created = now - 100
        self._criteria([self.INSPECT, self._crud("AC-C", "G1")],
                       {"created_at": time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(created))})
        self._db_assignment()
        rec = {"id": "AC-C", "status": "PASS", "write_log": "[PMS] 저장 완료", "count_before": 1, "count_after": 2,
               "write_ts": now - 10}
        rec.update(rec_extra)
        os.makedirs(os.path.dirname(self.evidence), exist_ok=True)
        with open(self._partial_path(), "w", encoding="utf-8") as fp:
            json.dump({"result": "PARTIAL", "source": "goal_gate", "passed": ["AC-C"],
                       "not_passed": [{"id": "AC-I", "status": "FAIL"}], "criteria_results": [rec]}, fp)
        if snap is not None:
            sp = os.path.join(os.path.dirname(self.evidence), "snapshot_AC-C_t_Ticket.json")
            with open(sp, "w", encoding="utf-8") as fp:
                fp.write(snap)
            mt = now + snap_mtime
            os.utime(sp, (mt, mt))
        return self.run_gate()

    SNAP = '{"table":"cspms.t_Ticket","where":"TicketID=1","rows":[{"TicketID":1}]}'

    # 양성(차단) — 종전엔 PARTIAL_ACKNOWLEDGED rc=0 으로 스냅샷 없이 통과하던 경로
    def test_c177_partial_ack_without_snapshot_blocked(self):
        rc, out = self._ack_case({})
        self.assertEqual(rc, 1, out)
        self.assertIn("SNAPSHOT_MISSING", out)
        self.assertNotIn("PARTIAL_ACKNOWLEDGED", out)

    # 양성(차단) — 빈 스냅샷(rows=[])
    def test_c177_partial_ack_empty_snapshot_blocked(self):
        rc, out = self._ack_case({}, '{"table":"t","rows":[]}', snap_mtime=-50)
        self.assertEqual(rc, 1, out)
        self.assertIn("SNAPSHOT_EMPTY", out)

    # 양성(차단) — 크기 0 스냅샷
    def test_c177_partial_ack_zero_size_snapshot_blocked(self):
        rc, out = self._ack_case({}, "", snap_mtime=-50)
        self.assertEqual(rc, 1, out)
        self.assertIn("SNAPSHOT_EMPTY", out)

    # 양성(차단) — 옛 스냅샷(criteria created_at 이전 mtime)
    def test_c177_partial_ack_stale_snapshot_blocked(self):
        rc, out = self._ack_case({}, self.SNAP, snap_mtime=-500)
        self.assertEqual(rc, 1, out)
        self.assertIn("SNAPSHOT_STALE", out)

    # 양성(차단) — 스냅샷이 첫 쓰기 뒤
    def test_c177_partial_ack_snapshot_after_write_blocked(self):
        rc, out = self._ack_case({}, self.SNAP, snap_mtime=-5)
        self.assertEqual(rc, 1, out)
        self.assertIn("SNAPSHOT_AFTER_WRITE", out)

    # 음성(통과) — 이번 파이프라인 안, 첫 쓰기 전 스냅샷
    def test_c177_partial_ack_fresh_snapshot_passes(self):
        rc, out = self._ack_case({}, self.SNAP, snap_mtime=-50)
        self.assertEqual(rc, 0, out)
        self.assertIn("PARTIAL_ACKNOWLEDGED", out)

    # 음성(면제 유지) — live_rows:false 는 종전대로 스냅샷 불요
    def test_c177_partial_ack_live_rows_false_exempt(self):
        rc, out = self._ack_case({"live_rows": False})
        self.assertEqual(rc, 0, out)
        self.assertIn("PARTIAL_ACKNOWLEDGED", out)

    # ── 결함3(c): --ac-records 공식 입력 ──
    def _ac_file(self, records):
        path = os.path.join(self.tmp.name, "ac_records.json")
        with open(path, "w", encoding="utf-8") as fp:
            json.dump(records, fp, ensure_ascii=False)
        return path

    # 양성 — AC 레코드를 공식 병합 → make_partial passed 에 AC id, --final PARTIAL 인정
    def test_c177_ac_records_merged(self):
        self._criteria([self.INSPECT, self._crud("AC-C", "G1")])
        self._db_assignment()
        path = self._ac_file([dict(self.EV_OK, id="AC-C", status="PASS", live_rows=False)])
        rc, out = self._emit("G1\tPASS\trc=0\nG2\tFAIL\trc=1\n", 1, ["--ac-records", path])
        self.assertEqual(rc, 1, out)
        self.assertIn("AC_RECORDS_LOADED: 1건", out)
        data = self._partial()
        self.assertIn("AC-C", data["passed"])
        self.assertIn("ac_records", [r.get("source") for r in data["criteria_results"]])
        rc2, out2 = self.run_gate()
        self.assertEqual(rc2, 0, out2)
        self.assertIn("AC-C: PASS + CRUD 증거 확인", out2)

    # 음성 — criteria 에 없는 id → rc=2, 아무것도 쓰지 않는다
    def test_c177_ac_records_unknown_id_rejected(self):
        self._criteria([self.INSPECT, self._crud("AC-C", "G1")])
        path = self._ac_file([dict(self.EV_OK, id="AC-ZZ", status="PASS")])
        rc, out = self._emit("G1\tPASS\trc=0\nG2\tFAIL\trc=1\n", 1, ["--ac-records", path])
        self.assertEqual(rc, 2, out)
        self.assertIn("AC_RECORDS_REJECTED", out)
        self.assertFalse(os.path.isfile(self._partial_path()))

    # 음성 — goal 미통과 아래 AC PASS 레코드는 인정하지 않는다(FAIL→PASS 경로 없음)
    def test_c177_ac_records_goal_not_pass(self):
        self._criteria([self.INSPECT, self._crud("AC-C", "G2")])
        path = self._ac_file([dict(self.EV_OK, id="AC-C", status="PASS", live_rows=False)])
        rc, out = self._emit("G1\tPASS\trc=0\nG2\tFAIL\trc=1\n", 1, ["--ac-records", path])
        self.assertEqual(rc, 1, out)
        np_ = {e["id"]: e["status"] for e in self._partial()["not_passed"]}
        self.assertEqual(np_.get("AC-C"), "GOAL_NOT_PASS")
        self.assertNotIn("AC-C", self._partial()["passed"])

    # 음성 — CRUD AC PASS 레코드에 write_log+상태변화 없음 → 미통과
    def test_c177_ac_records_crud_without_evidence(self):
        self._criteria([self.INSPECT, self._crud("AC-C", "G1")])
        path = self._ac_file([{"id": "AC-C", "status": "PASS", "note": "확인함"}])
        rc, out = self._emit("G1\tPASS\trc=0\nG2\tFAIL\trc=1\n", 1, ["--ac-records", path])
        self.assertEqual(rc, 1, out)
        np_ = {e["id"]: e["status"] for e in self._partial()["not_passed"]}
        self.assertEqual(np_.get("AC-C"), "CRUD_EVIDENCE_MISSING")

    # ── 사이클195 역라우팅 #4: 카나리 계약 + 게이트 행·AC 기록 결합(판정은 게이트, 증거는 기록) ──
    CANARY = {"id": "AC-Y", "item_crud": False, "verify_kind": "inspection", "category": "canary",
              "priority": "must", "description": "카나리 — 항상 FAIL 이 정상", "method": "gate.py",
              "expected": "FAIL", "expected_result": "FAIL", "gate_kind": "canary"}

    def _sh_assignment(self):
        self._assignment({"odev-1": {"files": [self.write(self.repo, "hooks/a.sh", "#!/bin/bash\necho hi\n")]}})

    def _c195_crud(self, live_rows=False):
        item = dict(C172FalsePositiveTest.CRUD_ITEM, id="AC-C", gate_kind="record")
        if live_rows is False:
            item["live_rows"] = False
        return item

    # 양성 — 카나리 FAIL == expected_result → 정상, 나머지 PASS 면 make_ok(게이트 rc=1 이어도 실효 rc=0)
    def test_c195_canary_fail_matches_expected_make_ok(self):
        self._criteria([self.INSPECT, dict(self.CANARY)])
        self._sh_assignment()
        rc, out = self._emit("AC-I\tPASS\trc=0\nAC-Y\tFAIL\trc=1\n", 1)
        self.assertEqual(rc, 0, out)
        self.assertIn("CANARY_OK: AC-Y", out)
        self.assertIn("GOAL_GATE_EFFECTIVE_RC: 1 → 0", out)
        self.assertIn("MAKE_OK_FROM_GOAL", out)
        with open(self.evidence, encoding="utf-8") as fp:
            ok = json.load(fp)
        self.assertEqual(ok["canary_ok"], ["AC-Y"])
        row = {r["id"]: r for r in ok["criteria_results"]}["AC-Y"]
        self.assertEqual(row["status"], "FAIL", "카나리 관측값은 그대로 남는다(손으로 PASS 로 바꾸지 않는다)")
        self.assertIs(row["canary_ok"], True)

    # 음성 — 카나리가 PASS 로 나오면(판정기 우회·위조) CANARY_VIOLATION 으로 미통과, make_ok 금지
    def test_c195_canary_pass_is_violation(self):
        self._criteria([self.INSPECT, dict(self.CANARY)])
        self._sh_assignment()
        rc, out = self._emit("AC-I\tPASS\trc=0\nAC-Y\tPASS\trc=0\n", 0)
        self.assertEqual(rc, 1, out)
        self.assertIn("CANARY_VIOLATION", out)
        self.assertFalse(os.path.isfile(self.evidence))
        np_ = {e["id"]: e["status"] for e in self._partial()["not_passed"]}
        self.assertEqual(np_.get("AC-Y"), "CANARY_VIOLATION")

    # 음성 — 카나리 FAIL 이 정상이어도 다른 FAIL·UNDET 이 있으면 make_ok 가 아니다
    def test_c195_canary_does_not_absorb_other_fail(self):
        self._criteria([self.INSPECT, dict(self.CANARY)])
        self._sh_assignment()
        rc, out = self._emit("AC-I\tFAIL\trc=1\nAC-Y\tFAIL\trc=1\n", 1)
        self.assertEqual(rc, 1, out)
        self.assertNotIn("GOAL_GATE_EFFECTIVE_RC", out)
        self.assertFalse(os.path.isfile(self.evidence))
        np_ = {e["id"]: e["status"] for e in self._partial()["not_passed"]}
        self.assertEqual(np_.get("AC-I"), "FAIL")
        self.assertNotIn("AC-Y", np_, "정상 카나리는 미통과 목록에 들어가지 않는다")
        rc2, out2 = self._emit("AC-I\tUNDET\t판정불가\nAC-Y\tFAIL\trc=1\n", 3)
        self.assertEqual(rc2, 1, out2)
        self.assertNotIn("GOAL_GATE_EFFECTIVE_RC", out2)

    # 양성 — 게이트 PASS 행과 같은 id 의 AC 기록은 증거 필드만 결합되어 CRUD 검사를 통과한다
    def test_c195_ac_records_merge_evidence_into_gate_row(self):
        self._criteria([self.INSPECT, self._c195_crud()])
        self._db_assignment()
        path = self._ac_file([dict(self.EV_OK, id="AC-C", status="PASS", write_log="srv.log")])
        with open(os.path.join(os.path.dirname(path), "srv.log"), "w", encoding="utf-8") as fp:
            fp.write("[쓰기API] INSERT 1행\n")
        rc, out = self._emit("AC-I\tPASS\trc=0\nAC-C\tPASS\trc=0\n", 0, ["--ac-records", path])
        self.assertEqual(rc, 0, out)
        self.assertIn("AC_RECORDS_MERGED: AC-C", out)
        self.assertIn("MAKE_OK_FROM_GOAL", out)
        with open(self.evidence, encoding="utf-8") as fp:
            row = {r["id"]: r for r in json.load(fp)["criteria_results"]}["AC-C"]
        self.assertEqual(row["source"], "goal_gate")
        self.assertEqual(row["evidence_source"], "ac_records")
        self.assertEqual(row["count_after"], 2)

    # 음성 — 기록 status 가 게이트 판정과 다르면 거부(기록으로 판정을 바꾸는 경로 없음)
    def test_c195_ac_records_status_mismatch_rejected(self):
        self._criteria([self.INSPECT, self._c195_crud()])
        self._db_assignment()
        path = self._ac_file([dict(self.EV_OK, id="AC-C", status="PASS")])
        rc, out = self._emit("AC-I\tPASS\trc=0\nAC-C\tFAIL\trc=1\n", 1, ["--ac-records", path])
        self.assertEqual(rc, 2, out)
        self.assertIn("판정은 게이트가 한다", out)
        self.assertFalse(os.path.isfile(self._partial_path()))

    # 음성 — 게이트가 판정하지 않은 id(gate_kind 보유)의 PASS 기록은 거부
    def test_c195_ac_records_unjudged_pass_rejected(self):
        self._criteria([self.INSPECT, self._c195_crud()])
        self._db_assignment()
        path = self._ac_file([dict(self.EV_OK, id="AC-C", status="PASS")])
        rc, out = self._emit("AC-I\tPASS\trc=0\n", 0, ["--ac-records", path])
        self.assertEqual(rc, 2, out)
        self.assertIn("게이트를 거치지 않은 PASS", out)

    # 음성 — 결합해도 write_log+상태변화 증거가 없으면 CRUD PASS 는 여전히 거부
    def test_c195_merged_without_evidence_still_refused(self):
        self._criteria([self.INSPECT, self._c195_crud()])
        self._db_assignment()
        path = self._ac_file([{"id": "AC-C", "status": "PASS", "note": "확인함"}])
        rc, out = self._emit("AC-I\tPASS\trc=0\nAC-C\tPASS\trc=0\n", 0, ["--ac-records", path])
        self.assertEqual(rc, 1, out)
        self.assertIn("MAKE_OK_REFUSED_CRUD", out)
        self.assertFalse(os.path.isfile(self.evidence))
        np_ = {e["id"]: e["status"] for e in self._partial()["not_passed"]}
        self.assertEqual(np_.get("AC-C"), "CRUD_EVIDENCE_MISSING")

    # 양성 — 파일 여러 개: 같은 id 는 mtime 이 늦은 파일이 이긴다(cNNN_gate 규칙 4 와 동일)
    def test_c195_ac_records_multiple_files_latest_wins(self):
        self._criteria([self.INSPECT, self._c195_crud()])
        self._db_assignment()
        old = self._ac_file([{"id": "AC-C", "status": "PASS", "note": "증거 없음(옛 기록)"}])
        new_dir = os.path.join(self.tmp.name, "rec_new")
        os.makedirs(new_dir, exist_ok=True)
        new = os.path.join(new_dir, "ac_records_b2.json")
        with open(new, "w", encoding="utf-8") as fp:
            json.dump({"records": [dict(self.EV_OK, id="AC-C", status="PASS")]}, fp, ensure_ascii=False)
        os.utime(old, (1_700_000_000, 1_700_000_000))
        os.utime(new, (1_700_000_100, 1_700_000_100))
        rc, out = self._emit("AC-I\tPASS\trc=0\nAC-C\tPASS\trc=0\n", 0,
                             ["--ac-records", old, "--ac-records", new])
        self.assertEqual(rc, 0, out)
        self.assertIn("MAKE_OK_FROM_GOAL", out)


class EmitRecheckExcludeFlagTest(unittest.TestCase):
    """D-9 (사이클199): --emit-from-goal --exclude-test-fixtures 의 make_ok 후보 재검사에도 같은 플래그가 전달된다.

    종전: 본 실행(_derive_crud_items)은 픽스처 적중을 빼 content_cleared 인데, 재검사 subprocess 는 플래그 없이 돌아
      db_found → "*" CRUD_EVIDENCE_MISSING 으로 make_partial 이 남았다(otest 실측).
    비-CRUD 선언 + AC 본문 어휘('삭제') → content 무효화 → 사실 축(DB 실측) 경로를 탄다.
    """
    setUp = VerifyCrudFallbackTest.setUp
    tearDown = VerifyCrudFallbackTest.tearDown
    write = staticmethod(VerifyCrudFallbackTest.write)
    set_start = VerifyCrudFallbackTest.set_start
    _criteria = C172FalsePositiveTest._criteria
    _assignment = C172FalsePositiveTest._assignment
    _emit = C177HarnessTest._emit
    _partial_path = C177HarnessTest._partial_path
    _partial = C177HarnessTest._partial

    ITEM = {"id": "AC-001", "item_crud": False, "category": "infra", "priority": "must",
            "description": "가드가 보호 파일 쓰기·삭제·이동을 계속 막는다",
            "method": "기계 판정: dNN_gate.py item X", "expected": "rc 0"}
    EXTRA = {"crud_대상": False, "crud_미해당_사유": "hook 판정기 수정만 — DB 접근 코드 변경 없음"}

    def _setup(self, non_fixture_dml):
        self.set_start(int(time.time()) - 5)
        self._criteria([dict(self.ITEM)], self.EXTRA)
        files = [self.write(self.repo, "hooks/tests/test_cases.sh", f"#!/bin/sh\nCASE='{_DML}'\n"),
                 self.write(self.repo, "hooks/run.sh", "#!/bin/sh\necho ok\n")]
        if non_fixture_dml:
            files.append(self.write(self.repo, "hooks/store.sh", f"#!/bin/sh\nQ='{_DML}'\n"))
        self._assignment({"odev-1": {"files": files}})

    # 음성 — 픽스처만 적중 + 플래그: 재검사도 플래그를 받아 make_ok
    def test_d9_fixture_only_with_flag_emits_make_ok(self):
        self._setup(non_fixture_dml=False)
        rc, out = self._emit("AC-001\tPASS\trc=0\n", 0, ("--exclude-test-fixtures",))
        self.assertEqual(rc, 0, out)
        self.assertIn("MAKE_OK_FROM_GOAL", out)
        self.assertTrue(os.path.isfile(self.evidence), out)
        self.assertFalse(os.path.isfile(self._partial_path()), out)

    # 양성 — 픽스처가 아닌 파일의 DB 적중은 플래그가 있어도 make_partial
    def test_d9_non_fixture_dml_with_flag_stays_partial(self):
        self._setup(non_fixture_dml=True)
        rc, out = self._emit("AC-001\tPASS\trc=0\n", 0, ("--exclude-test-fixtures",))
        self.assertEqual(rc, 1, out)
        self.assertFalse(os.path.isfile(self.evidence), out)
        self.assertTrue(any(n["id"] == "*" for n in self._partial()["not_passed"]), out)

    # 양성 — 기본(플래그 없음)은 픽스처만 적중이어도 종전대로 make_partial
    def test_d9_fixture_only_without_flag_stays_partial(self):
        self._setup(non_fixture_dml=False)
        rc, out = self._emit("AC-001\tPASS\trc=0\n", 0)
        self.assertEqual(rc, 1, out)
        self.assertFalse(os.path.isfile(self.evidence), out)


class DirExpandNoSlashTest(unittest.TestCase):
    """2026-11-06 과제3: 끝 '/' 없는 디렉터리·디렉터리 symlink 배정 전개(허용 3) + fail-closed 유지(차단 6)."""
    setUp = VerifyCrudFallbackTest.setUp
    tearDown = VerifyCrudFallbackTest.tearDown
    write = staticmethod(VerifyCrudFallbackTest.write)
    set_start = VerifyCrudFallbackTest.set_start
    run_gate = VerifyCrudFallbackTest.run_gate
    _assign = VerifyCrudFallbackTest._assign

    def _pack(self, rel, content="#!/bin/sh\necho ok\n"):
        self.write(self.repo, rel + "/a.sh", content)
        return os.path.join(self.repo, rel)

    def _link(self, target, rel):
        link = os.path.join(self.repo, rel)
        os.makedirs(os.path.dirname(link), exist_ok=True)
        os.symlink(target, link)
        return link

    def _assert_clean(self, rc, out):
        self.assertEqual(rc, 0, out)
        self.assertIn("NON_CRUD_EXEMPT_DB_UNTOUCHED", out)
        self.assertNotIn("Is a directory", out)

    def _assert_unreadable(self, rc, out, why):
        self.assertEqual(rc, 1, out)
        self.assertIn("DB_SCAN_UNVERIFIABLE", out)
        self.assertIn(why, out)

    def test_dirx_r1_dir_no_slash_clean(self):
        self.set_start(int(time.time()) - 5)
        self._assign([self._pack("hooks/pack")])
        self._assert_clean(*self.run_gate())

    def test_dirx_r2_dir_symlink_no_slash_clean(self):
        self.set_start(int(time.time()) - 5)
        real = self._pack("hooks/real_pack")
        self._assign([self._link(real, "hooks/link_pack")])
        self._assert_clean(*self.run_gate())

    def test_dirx_r3_dir_symlink_slash_clean(self):
        self.set_start(int(time.time()) - 5)
        real = self._pack("hooks/real_pack")
        self._assign([self._link(real, "hooks/link_pack") + "/"])
        self._assert_clean(*self.run_gate())

    def test_dirx_b1_dir_no_slash_dml_blocked(self):
        self.set_start(int(time.time()) - 5)
        self._assign([self._pack("hooks/pack", f"#!/bin/sh\nQ='{_DML}'\n")])
        rc, out = self.run_gate()
        self.assertEqual(rc, 1, out)
        self.assertIn("DB_CONTACT_DETECTED", out)

    def test_dirx_b2_dir_symlink_dml_blocked(self):
        self.set_start(int(time.time()) - 5)
        real = self._pack("hooks/real_pack", f"#!/bin/sh\nQ='{_DML}'\n")
        self._assign([self._link(real, "hooks/link_pack")])
        rc, out = self.run_gate()
        self.assertEqual(rc, 1, out)
        self.assertIn("DB_CONTACT_DETECTED", out)

    def test_dirx_b3_nested_link_dir_unreadable(self):
        self.set_start(int(time.time()) - 5)
        other = self._pack("hooks/other_pack")
        top = self._pack("hooks/pack")
        self._link(other, "hooks/pack/sub_link")
        self._assign([top])
        self._assert_unreadable(*self.run_gate(), "링크 디렉터리")

    def test_dirx_b4_empty_dir_unreadable(self):
        self.set_start(int(time.time()) - 5)
        empty = os.path.join(self.repo, "hooks", "empty_pack")
        os.makedirs(empty)
        self._assign([empty])
        self._assert_unreadable(*self.run_gate(), "일반 파일 0개")

    def test_dirx_b5_wildcard_unreadable(self):
        self.set_start(int(time.time()) - 5)
        self._pack("hooks/pack")
        self._assign([os.path.join(self.repo, "hooks", "pack", "*.sh")])
        self._assert_unreadable(*self.run_gate(), "와일드카드")

    def test_dirx_b6_path_axis_dir_expanded_dml_overridden(self):
        data = dict(FIXTURE_AC)
        data["crud_대상"] = False
        data["crud_미해당_사유"] = "hook 셸 스크립트 수정 작업으로 DB 변경 없음"
        with open(self.criteria, "w", encoding="utf-8") as fp:
            json.dump(data, fp, ensure_ascii=False)
        _set_start_ok(self, int(time.time()) - 5)
        # CRUD_SUSPECT_PATTERN 은 확장자로 끝나는 경로만 잡는다 → '.sql' 로 끝나는 디렉터리 이름으로 경로 축을 태운다.
        svc = os.path.join(self.repo, "db", "legacy_dump.sql")
        self.write(self.repo, "db/legacy_dump.sql/part1.sql", f"{_DML};\n")
        self._assign([svc])
        rc, out = self.run_gate()
        self.assertEqual(rc, 1, out)
        self.assertIn("CRUD_DECLARATION_OVERRIDDEN", out)
        self.assertIn("경로 기인", out)
        self.assertIn("쓰기 토큰(변경 범위)", out)
        self.assertNotIn("Is a directory", out)


if __name__ == "__main__":
    unittest.main()
