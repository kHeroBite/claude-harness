# 정본(AI) settings.json 의 범용 hook 등록을 REGULAR 파생본 전체에 동기화한다.
#
# 사전 차단(PreToolUse)은 구조적으로 불가능하다 — hook 을 6곳에 등록하는 것은 6회의 개별 쓰기이므로
# 첫 쓰기 시점에 나머지 5곳이 미등록인 것이 정상 상태다. 이를 block 하면 등록 자체가 막힌다.
# 따라서 "드리프트 발생"이 아니라 "드리프트 잔존"을 불가능하게 만드는 사후 집행 방식을 쓴다.
#
# ★ hook 의 동일성 기준은 (event, matcher, script) 3튜플이다.
#   하나의 스크립트가 여러 matcher 슬롯에 정당하게 등록될 수 있다.
#   실제 사례: write_guard.sh 는 Bash / Edit|Write / Read|Grep / oio-write 4개 슬롯에 동시 등록된다.
#   "같은 스크립트인데 matcher 가 다르다"를 드리프트로 보면 슬롯끼리 matcher 를 덮어쓰며
#   수렴하지 않고 회전한다(2026-08-20 검증에서 실제로 재현됨). 그래서 matcher 재작성은 하지 않는다.
#   정본에 있는 (event, matcher, script) 조합이 없으면 "추가"한다.
# ★ 조합은 같은데 내용(command·timeout·async 등)이 다르면 정본으로 "교체"한다(위치 보존).
#   추가만 하면 command 문자열을 바꾼 정본(예: 래퍼판)과 옛 파생본(원본판)이 공존해
#   같은 hook 이 두 번 실행된다 — 공식 문서상 문자열이 다르면 별개 handler 다(2026-10-10).
#   같은 슬롯 안에 같은 조합이 중복 등록돼 있으면 첫 항목만 남기고 나머지는 제거한다.
#   PROJECT_LOCAL 은 triples() 단계에서 제외되므로 교체·제거 대상이 아니다.
#
#   --check : 감지만 (드리프트 있으면 종료코드 10)
#   --apply : 감지 + 자동 반영 (반영했으면 종료코드 10)
# ★ [사이클182 L-616] 이 동기화는 추가·교체만 하므로 정본에서 지운 hook 이 파생본에 남는다(삭제 미전파).
#   그래서 파생본의 '낡은 항목'을 따로 찾아 경고하고 종료코드 11 로 실패 판정한다(10 보다 우선). 자동 삭제는 하지 않는다
#   (프로젝트 고유 hook 을 PROJECT_LOCAL 미등재 상태로 지우는 사고를 막기 위해 사람 판단에 맡긴다).
#     ! … (스크립트 파일 없음)            — 명령이 가리키는 .sh/.py 가 디스크에 없다
#     ! … (정본에 없음)                    — 정본 어디에도 없는 스크립트(정본에서 지웠다면 함께 지우고, 고유 hook 이면 PROJECT_LOCAL 등재)
#     ! … (정본은 다른 matcher 로 등록)    — 같은 이벤트의 같은 스크립트가 정본과 다른 matcher 슬롯에 남은 옛 중복
# 연관: L-578 (문서/경고만으로는 재발방지 실패 실증)
import io
import json
import os
import re
import sys

BASE = "/mnt/c/DATA/Project"
CANON_PROJECT = "AI"

# 프로젝트 고유 hook — 전파 대상에서 영구 제외한다. 신규 고유 hook 추가 시 여기에 등재하라.
PROJECT_LOCAL = {
    "agent_backlog_guard.sh": "Mars 전용 — 에이전트 백로그 가드",
    "PostToolUse_docker_compose_scripts_mount.sh": "rtx5070 전용 — docker compose 마운트 검사",
}


def regular_projects():
    """settings.json 이 symlink 가 아닌(=개별 관리되는) 프로젝트 목록을 반환한다."""
    out = []
    try:
        names = sorted(os.listdir(BASE))
    except OSError:
        return out
    for name in names:
        p = os.path.join(BASE, name, ".claude", "settings.json")
        if os.path.isfile(p) and not os.path.islink(p):
            out.append(name)
    return out


def script_name(cmd):
    hits = re.findall(r"[\w./-]+\.sh", cmd or "")
    return hits[-1].split("/")[-1] if hits else (cmd or "")[:40]


def load(path):
    with io.open(path, encoding="utf-8") as f:
        return json.load(f)


def triples(doc):
    """{(event, matcher, script): hookdict} — 고유 hook 은 제외한다."""
    idx = {}
    for event, arr in doc.get("hooks", {}).items():
        for slot in arr:
            matcher = slot.get("matcher", "")
            for hk in slot.get("hooks", []):
                name = script_name(hk.get("command", ""))
                if name in PROJECT_LOCAL:
                    continue
                idx[(event, matcher, name)] = hk
    return idx


def _slot_hooks(doc, event, matcher, name):
    """doc 에서 (event, matcher, name) 조합에 해당하는 [(hooks 리스트, hookdict)] 를 등록 순서대로 반환한다."""
    found = []
    for slot in doc.get("hooks", {}).get(event, []):
        if slot.get("matcher", "") != matcher:
            continue
        lst = slot.get("hooks", [])
        for hk in lst:
            if script_name(hk.get("command", "")) == name:
                found.append((lst, hk))
    return found


def sync_project(canon, doc):
    """정본 기준으로 doc 의 (event, matcher, script) 조합을 추가·교체한다. 변경 내역을 반환한다."""
    changes = []
    mine = triples(doc)
    for (event, matcher, name), src in sorted(triples(canon).items()):
        if (event, matcher, name) in mine:
            found = _slot_hooks(doc, event, matcher, name)
            first_lst, first = found[0]
            if first != src:
                first.clear()
                first.update(dict(src))  # 같은 dict 객체를 갱신하므로 위치가 보존된다
                changes.append("~ %s [%s] %s (정본으로 교체)" % (event, matcher, name))
            for lst, dup in found[1:]:
                lst[:] = [h for h in lst if h is not dup]
                changes.append("- %s [%s] %s (중복 제거)" % (event, matcher, name))
            continue
        arr = doc.setdefault("hooks", {}).setdefault(event, [])
        slot = next((m for m in arr if m.get("matcher") == matcher), None)
        if slot is None:
            slot = {"matcher": matcher, "hooks": []}
            arr.append(slot)
        slot.setdefault("hooks", []).append(dict(src))
        changes.append("+ %s [%s] %s" % (event, matcher, name))
    return changes


def stale_items(canon, doc):
    """파생본의 낡은 항목 목록(정본으로 동기화해도 사라지지 않는 것) — 고유 hook 은 제외한다."""
    ct = triples(canon)
    names = {n for (_, _, n) in ct}
    ev_names = {(e, n) for (e, _, n) in ct}
    out = []
    for event, arr in doc.get("hooks", {}).items():
        for slot in arr:
            matcher = slot.get("matcher", "")
            for hk in slot.get("hooks", []):
                cmd = hk.get("command", "")
                name = script_name(cmd)
                if name in PROJECT_LOCAL:
                    continue
                paths = re.findall(r"/[\w./-]+\.(?:sh|py)", cmd or "")
                if paths and not os.path.exists(paths[-1]):
                    out.append("! %s [%s] %s (스크립트 파일 없음)" % (event, matcher, name))
                elif name not in names:
                    out.append("! %s [%s] %s (정본에 없음 — 정본에서 지웠다면 함께 지우고, 고유 hook 이면 PROJECT_LOCAL 에 등재)" % (event, matcher, name))
                elif (event, name) in ev_names and (event, matcher, name) not in ct:
                    out.append("! %s [%s] %s (정본은 다른 matcher 로 등록 — 옛 슬롯 중복)" % (event, matcher, name))
    return out


def write_atomic(path, doc):
    tmp = path + ".hrsync.tmp"
    with io.open(tmp, "w", encoding="utf-8", newline="\n") as f:
        json.dump(doc, f, ensure_ascii=False, indent=2)
        f.write("\n")
    with io.open(tmp, encoding="utf-8") as f:  # 검증: 유효 JSON 인가
        json.load(f)
    os.replace(tmp, path)


def main():
    apply_changes = "--apply" in sys.argv
    canon_path = os.path.join(BASE, CANON_PROJECT, ".claude", "settings.json")
    try:
        canon = load(canon_path)
    except Exception as e:
        print("정본 로드 실패: %s" % e)
        return 1

    drifted = False
    has_stale = False
    for proj in regular_projects():
        if proj == CANON_PROJECT:
            continue
        path = os.path.join(BASE, proj, ".claude", "settings.json")
        try:
            doc = load(path)
        except Exception as e:
            print("%s: 로드 실패 — %s" % (proj, e))
            return 1
        changes = sync_project(canon, doc)
        stale = stale_items(canon, doc)
        if stale:
            has_stale = True
            print("%s: 낡은 항목 %d건(삭제 미전파 — 수동 정리 필요)" % (proj, len(stale)))
            for s in stale:
                print("    %s" % s)
        if not changes:
            continue
        drifted = True
        print("%s: %d건 %s" % (proj, len(changes), "반영" if apply_changes else "감지"))
        for c in changes:
            print("    %s" % c)
        if apply_changes:
            try:
                write_atomic(path, doc)
            except Exception as e:
                print("%s: 쓰기 실패 — %s" % (proj, e))
                return 1

    if has_stale:
        return 11
    return 10 if drifted else 0


if __name__ == "__main__":
    sys.exit(main())
