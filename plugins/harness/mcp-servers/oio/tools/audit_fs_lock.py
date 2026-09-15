#!/usr/bin/env python3
"""AST 기반 L-362 정적 감사 — `with _fs_lock:` 블록 내부 파일 I/O 금지.

L-362: `_fs_lock` 블록 안에서는 파일 I/O(os.listdir, open, read, write 등)를
수행하면 안 된다. lock 안에서는 키/ID 스냅샷만 수집하고, I/O는 lock 해제 후에
수행해야 한다. 위반 시 session_manager.py의 heartbeat_worker 등에서 교착·I/O
블로킹이 발생한다.

본 도구는 대상 파일을 AST로 파싱하여 `with _fs_lock:` 하위 트리 안에
금지 호출이 포함되어 있는지 검사하고, 위반을 line 번호/함수명으로 출력한다.

CLI:
    python audit_fs_lock.py                          # 기본: session_manager.py
    python audit_fs_lock.py path/to/file.py          # 지정 파일 감사

Exit code:
    0 = 통과
    1 = 위반 발견 또는 파싱 실패
"""
from __future__ import annotations

import ast
import os
import sys
from typing import Iterable

DEFAULT_TARGET = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "session_manager.py"
)

# `with _fs_lock:` 내부에서 금지되는 호출명 (os.*, builtins, shutil 등)
FORBIDDEN_CALL_NAMES = {
    "open", "read", "write",
}
FORBIDDEN_OS_ATTRS = {
    "listdir", "scandir", "walk",
    "remove", "unlink", "rename", "replace",
    "makedirs", "mkdir", "rmdir",
    "stat", "lstat",
    "chmod", "chown",
    "readlink", "symlink",
}
FORBIDDEN_SHUTIL_ATTRS = {
    "copy", "copy2", "copyfile", "copytree",
    "move", "rmtree",
}
# pathlib.Path.* I/O 메서드 (Attribute 기반 감지)
FORBIDDEN_PATHLIB_ATTRS = {
    "read_text", "write_text", "read_bytes", "write_bytes",
    "mkdir", "rmdir", "unlink", "rename", "replace", "iterdir",
}


def _is_fs_lock_with(node: ast.With) -> bool:
    """`with _fs_lock:` 또는 `with _fs_lock as x:` 인지 판정."""
    for item in node.items:
        ctx = item.context_expr
        if isinstance(ctx, ast.Name) and ctx.id == "_fs_lock":
            return True
        if isinstance(ctx, ast.Attribute) and ctx.attr == "_fs_lock":
            return True
    return False


def _iter_calls(tree: ast.AST) -> Iterable[ast.Call]:
    for node in ast.walk(tree):
        if isinstance(node, ast.Call):
            yield node


def _classify_call(call: ast.Call) -> str | None:
    """금지 호출이면 사유를 반환, 아니면 None."""
    func = call.func
    if isinstance(func, ast.Name):
        if func.id in FORBIDDEN_CALL_NAMES:
            return f"builtin {func.id}()"
        return None
    if isinstance(func, ast.Attribute):
        attr = func.attr
        # os.<attr>
        if isinstance(func.value, ast.Name) and func.value.id == "os":
            if attr in FORBIDDEN_OS_ATTRS:
                return f"os.{attr}()"
        # os.path.<attr> 는 stat 읽지 않는 순수 경로 조작이 다수라 제외
        if isinstance(func.value, ast.Name) and func.value.id == "shutil":
            if attr in FORBIDDEN_SHUTIL_ATTRS:
                return f"shutil.{attr}()"
        # pathlib.Path 인스턴스는 정적 판정이 어려우므로 메서드명만으로 경고
        if attr in FORBIDDEN_PATHLIB_ATTRS:
            return f".{attr}() (pathlib 의심)"
    return None


def _enclosing_func_name(
    stack: list[ast.AST],
) -> str:
    for node in reversed(stack):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            return node.name
    return "<module>"


def _collect_whitelist_lines(source: str) -> set[int]:
    """`# audit-whitelist: <tag>` 주석이 달린 라인 집합을 수집.

    주석이 동일 라인에 있거나, 바로 앞 라인에 위치한 경우 다음 라인도 whitelist.
    """
    whitelisted: set[int] = set()
    lines = source.splitlines()
    for idx, line in enumerate(lines, start=1):
        if "# audit-whitelist:" in line or "#audit-whitelist:" in line:
            whitelisted.add(idx)
            # 주석이 단독 라인이면 다음 실제 코드 라인도 허용
            stripped = line.strip()
            if stripped.startswith("#"):
                if idx + 1 <= len(lines):
                    whitelisted.add(idx + 1)
    return whitelisted


def audit_file(path: str) -> list[tuple[int, str, str]]:
    """위반 목록 반환: [(line, func_name, reason), ...]."""
    with open(path, "r", encoding="utf-8") as f:
        source = f.read()
    try:
        tree = ast.parse(source, filename=path)
    except SyntaxError as e:
        print(f"[audit_fs_lock] SyntaxError: {path}:{e.lineno}: {e.msg}", file=sys.stderr)
        raise

    whitelisted_lines = _collect_whitelist_lines(source)
    violations: list[tuple[int, str, str]] = []

    def visit(node: ast.AST, stack: list[ast.AST], in_fs_lock: bool) -> None:
        stack.append(node)
        try:
            if isinstance(node, ast.With) and _is_fs_lock_with(node):
                for child in node.body:
                    visit(child, stack, in_fs_lock=True)
                return
            if in_fs_lock and isinstance(node, ast.Call):
                reason = _classify_call(node)
                if reason is not None and node.lineno not in whitelisted_lines:
                    violations.append(
                        (node.lineno, _enclosing_func_name(stack), reason)
                    )
            for child in ast.iter_child_nodes(node):
                visit(child, stack, in_fs_lock)
        finally:
            stack.pop()

    visit(tree, [], in_fs_lock=False)
    return violations


def main(argv: list[str]) -> int:
    target = argv[1] if len(argv) > 1 else DEFAULT_TARGET
    target = os.path.abspath(target)
    if not os.path.isfile(target):
        print(f"[audit_fs_lock] 대상 파일 없음: {target}", file=sys.stderr)
        return 1
    try:
        violations = audit_file(target)
    except SyntaxError:
        return 1
    if not violations:
        print(f"[audit_fs_lock] PASS: {target} — _fs_lock 블록 내 I/O 없음")
        return 0
    print(f"[audit_fs_lock] FAIL: {target} — {len(violations)}건 위반", file=sys.stderr)
    for line, fn, reason in violations:
        print(f"  L{line}  {fn}()  -> {reason}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
