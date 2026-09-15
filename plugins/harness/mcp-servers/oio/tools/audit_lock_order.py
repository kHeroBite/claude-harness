#!/usr/bin/env python3
"""AST 기반 lock ordering 정적 감사.

oio-mcp-server는 다중 Lock 계층을 쓴다:
    Layer 1: intent lock (세션/파일 단위, lock_manager 경유)
    Layer 2: _fs_lock (모듈 레벨 RLock — session_manager 내부 상태 보호)

교착 방지를 위한 **정해진 획득 순서**:
    intent lock → _fs_lock   (앞에서 뒤로만)

역순 (`_fs_lock` 보유 중 intent lock 취득)이 발생하면 다른 워커가
정상 순서로 획득할 때 dead-lock 가능성이 생긴다.

본 도구는 각 함수(또는 메서드) 단위로 `with` 문을 AST로 훑어
다음을 검출한다:
    1. `_fs_lock` 블록 안에서 `lock_manager`/`acquire*`/intent lock 류 호출
    2. 동일 함수 내에 `_fs_lock` → intent lock 순의 중첩 `with`

CLI:
    python audit_lock_order.py                       # 기본: oio-mcp-server/*.py
    python audit_lock_order.py path/to/file.py [...] # 지정 파일만 감사

Exit code:
    0 = 통과
    1 = 위반 발견 또는 파싱 실패
"""
from __future__ import annotations

import ast
import os
import sys
from typing import Iterable

DEFAULT_TARGETS = [
    "session_manager.py",
    "file_ops.py",
    "dir_ops.py",
    "find_ops.py",
    "lock_manager.py",
    "session_ops.py",
]

# intent lock을 취득한다고 판단되는 호출명 패턴
INTENT_LOCK_CALL_NAMES = {
    "acquire", "acquire_lock",
    "intent_acquire", "implicit_acquire",
    "app_lock_acquire",
    "lock_acquire",
    "check_ownership",
}
# `with lock_manager.something(...):` 형태도 intent lock으로 간주
INTENT_LOCK_ATTR_HINTS = {
    "lock_manager",
    "locks",
    "intent_lock",
}


def _is_fs_lock_with(item: ast.withitem) -> bool:
    ctx = item.context_expr
    if isinstance(ctx, ast.Name) and ctx.id == "_fs_lock":
        return True
    if isinstance(ctx, ast.Attribute) and ctx.attr == "_fs_lock":
        return True
    return False


def _is_intent_lock_with(item: ast.withitem) -> bool:
    ctx = item.context_expr
    # with acquire(...): / with intent_acquire(...):
    if isinstance(ctx, ast.Call):
        func = ctx.func
        if isinstance(func, ast.Name) and func.id in INTENT_LOCK_CALL_NAMES:
            return True
        if isinstance(func, ast.Attribute):
            if func.attr in INTENT_LOCK_CALL_NAMES:
                return True
            if (
                isinstance(func.value, ast.Name)
                and func.value.id in INTENT_LOCK_ATTR_HINTS
            ):
                return True
    # with lock_manager.something: (bare attribute)
    if isinstance(ctx, ast.Attribute):
        base = ctx.value
        if isinstance(base, ast.Name) and base.id in INTENT_LOCK_ATTR_HINTS:
            return True
    return False


def _iter_nested_with(
    body: list[ast.stmt],
) -> Iterable[ast.With]:
    for stmt in body:
        for node in ast.walk(stmt):
            if isinstance(node, ast.With):
                yield node


def _classify_call(call: ast.Call) -> str | None:
    func = call.func
    if isinstance(func, ast.Name) and func.id in INTENT_LOCK_CALL_NAMES:
        return f"{func.id}()"
    if isinstance(func, ast.Attribute):
        if func.attr in INTENT_LOCK_CALL_NAMES:
            return f".{func.attr}()"
        if (
            isinstance(func.value, ast.Name)
            and func.value.id in INTENT_LOCK_ATTR_HINTS
        ):
            return f"{func.value.id}.{func.attr}()"
    return None


def audit_file(path: str) -> list[tuple[int, str, str]]:
    with open(path, "r", encoding="utf-8") as f:
        source = f.read()
    try:
        tree = ast.parse(source, filename=path)
    except SyntaxError as e:
        print(
            f"[audit_lock_order] SyntaxError: {path}:{e.lineno}: {e.msg}",
            file=sys.stderr,
        )
        raise

    violations: list[tuple[int, str, str]] = []

    for node in ast.walk(tree):
        if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        func_name = node.name

        # 함수 내부 모든 with 노드 순회
        for with_node in ast.walk(node):
            if not isinstance(with_node, ast.With):
                continue
            has_fs_lock = any(_is_fs_lock_with(it) for it in with_node.items)
            if not has_fs_lock:
                continue

            # 1) 중첩 with 안에서 intent lock을 추가로 취득하는 케이스
            for inner in _iter_nested_with(with_node.body):
                for it in inner.items:
                    if _is_intent_lock_with(it):
                        violations.append(
                            (
                                inner.lineno,
                                func_name,
                                "역순 lock: _fs_lock 보유 중 intent lock with 취득",
                            )
                        )

            # 2) _fs_lock 블록 내부에서 intent lock 함수 호출
            for sub in ast.walk(with_node):
                if sub is with_node:
                    continue
                if isinstance(sub, ast.Call):
                    reason = _classify_call(sub)
                    if reason is not None:
                        violations.append(
                            (
                                sub.lineno,
                                func_name,
                                f"역순 lock: _fs_lock 내부 intent lock 호출 {reason}",
                            )
                        )
    return violations


def _resolve_targets(argv: list[str]) -> list[str]:
    if len(argv) > 1:
        return [os.path.abspath(p) for p in argv[1:]]
    base = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
    return [os.path.join(base, name) for name in DEFAULT_TARGETS]


def main(argv: list[str]) -> int:
    targets = _resolve_targets(argv)
    total = 0
    any_missing = False
    for target in targets:
        if not os.path.isfile(target):
            print(
                f"[audit_lock_order] SKIP: 대상 없음 {target}", file=sys.stderr
            )
            any_missing = True
            continue
        try:
            violations = audit_file(target)
        except SyntaxError:
            return 1
        if violations:
            total += len(violations)
            print(
                f"[audit_lock_order] FAIL: {target} — {len(violations)}건",
                file=sys.stderr,
            )
            for line, fn, reason in violations:
                print(f"  L{line}  {fn}()  -> {reason}", file=sys.stderr)
        else:
            print(f"[audit_lock_order] PASS: {target}")
    if total > 0:
        return 1
    # 파일 누락만 있고 위반 없음 → 경고지만 PASS
    if any_missing:
        print("[audit_lock_order] 일부 대상 누락(경고). 위반 없음 → PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
