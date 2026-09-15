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
#   정본에 있는 (event, matcher, script) 조합이 없으면 "추가"만 한다.
#
#   --check : 감지만 (드리프트 있으면 종료코드 10)
#   --apply : 감지 + 자동 반영 (반영했으면 종료코드 10)
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
    "agent_backlog_guard.sh": "특정 프로젝트 전용 — 에이전트 백로그 가드",
    "PostToolUse_docker_compose_scripts_mount.sh": "특정 프로젝트 전용 — docker compose 마운트 검사",
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


def sync_project(canon, doc):
    """정본에만 있는 (event, matcher, script) 조합을 doc 에 추가한다. 변경 내역을 반환한다."""
    changes = []
    mine = triples(doc)
    for (event, matcher, name), src in sorted(triples(canon).items()):
        if (event, matcher, name) in mine:
            continue
        arr = doc.setdefault("hooks", {}).setdefault(event, [])
        slot = next((m for m in arr if m.get("matcher") == matcher), None)
        if slot is None:
            slot = {"matcher": matcher, "hooks": []}
            arr.append(slot)
        slot.setdefault("hooks", []).append(dict(src))
        changes.append("+ %s [%s] %s" % (event, matcher, name))
    return changes


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

    return 10 if drifted else 0


if __name__ == "__main__":
    sys.exit(main())
