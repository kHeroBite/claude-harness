#!/usr/bin/env python3
"""
pptClone.py — 소스 PPTX 레이아웃을 기반으로 타겟 PPTX 텍스트를 채워 넣기
사용법: python3 pptClone.py <소스> <타겟> [출력명] [--template-dir DIR]
예:     python3 pptClone.py red KB_AI --template-dir template
        → template/red.pptx 레이아웃에 template/KB_AI.pptx 텍스트를 이식 → template/KB_AI_cloned.pptx

방식 (fill-in):
  1. 타겟 슬라이드 유형(COVER/TOC/CONTENT) 판별
  2. 소스 후보 중 본문 sp 수(y≥130pt)가 가장 유사한 슬라이드 선택
  3. 소스 슬라이드를 deepcopy → 타겟 텍스트를 1:1 순서 매핑 교체
  4. 소스 박스 수 초과 텍스트는 절단
  5. 타겟 이미지(pic)는 소스 spTree에 오버레이 추가 (보존)
"""

import sys
import os
import copy
import zipfile
import re
from xml.etree import ElementTree as ET

# ─────────────────────────────────────────────
# 네임스페이스
# ─────────────────────────────────────────────
NS_P  = "http://schemas.openxmlformats.org/presentationml/2006/main"
NS_A  = "http://schemas.openxmlformats.org/drawingml/2006/main"
NS_R  = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

for prefix, uri in [
    ("p",  NS_P),
    ("a",  NS_A),
    ("r",  NS_R),
    ("mc", "http://schemas.openxmlformats.org/markup-compatibility/2006"),
    ("pr", "http://schemas.openxmlformats.org/package/2006/relationships"),
]:
    try:
        ET.register_namespace(prefix, uri)
    except Exception:
        pass

# ─────────────────────────────────────────────
# 페이지 구조 상수 (1-based)
# 1~10: 표지, 11~15: 목차, 16: 본문헤더샘플, 17~끝: 본문레이아웃
# ─────────────────────────────────────────────
COVER_RANGE    = (1, 10)
TOC_RANGE      = (11, 15)
HEADER_SAMPLE  = 16
BODY_START     = 17

# 헤더/본문 경계 (EMU) — 130pt
HEADER_Y_MAX = int(130 * 12700)  # 1,651,000


# ─────────────────────────────────────────────
# XML 헬퍼
# ─────────────────────────────────────────────
def get_xywh(sp):
    xfrm = sp.find(f".//{{{NS_A}}}xfrm")
    if xfrm is None:
        return None
    off = xfrm.find(f"{{{NS_A}}}off")
    ext = xfrm.find(f"{{{NS_A}}}ext")
    if off is None or ext is None:
        return None
    try:
        return (int(off.get("x", 0)), int(off.get("y", 0)),
                int(ext.get("cx", 0)), int(ext.get("cy", 0)))
    except ValueError:
        return None


def get_text(sp):
    parts = [t.text for t in sp.findall(f".//{{{NS_A}}}t") if t.text]
    return " ".join(parts).strip()


def set_all_text(sp, text):
    """sp 내 모든 <a:t> 텍스트를 대체 — 첫 번째 run에만 넣고 나머지 run 제거."""
    txBody = sp.find(f".//{{{NS_P}}}txBody")
    if txBody is None:
        txBody = sp.find(f".//{{{NS_A}}}txBody")
    if txBody is None:
        return
    paras = txBody.findall(f"{{{NS_A}}}p")
    if not paras:
        return

    # 줄바꿈 분리
    lines = text.split("\n")

    # 기존 단락 수가 부족하면 마지막 단락을 복제해서 추가
    while len(paras) < len(lines):
        paras.append(copy.deepcopy(paras[-1]))
        txBody.append(paras[-1])

    for idx, para in enumerate(paras):
        runs = para.findall(f"{{{NS_A}}}r")
        target_line = lines[idx] if idx < len(lines) else ""
        if runs:
            # 첫 번째 run에 텍스트 설정
            t_elem = runs[0].find(f"{{{NS_A}}}t")
            if t_elem is None:
                t_elem = ET.SubElement(runs[0], f"{{{NS_A}}}t")
            t_elem.text = target_line
            # 나머지 run 제거
            for run in runs[1:]:
                para.remove(run)
        else:
            # run 없으면 새로 생성
            run = ET.SubElement(para, f"{{{NS_A}}}r")
            t_elem = ET.SubElement(run, f"{{{NS_A}}}t")
            t_elem.text = target_line

    # 남는 단락 제거 (텍스트가 없는 초과 단락)
    for para in paras[len(lines):]:
        txBody.remove(para)


# ─────────────────────────────────────────────
# 슬라이드 유형 분류
# ─────────────────────────────────────────────
def classify_slide(xml_str, slide_idx_1based):
    if slide_idx_1based == 1:
        return "COVER"
    root = ET.fromstring(xml_str)
    sp_tree = root.find(f".//{{{NS_P}}}spTree")
    if sp_tree is None:
        return "CONTENT"
    sps = sp_tree.findall(f"{{{NS_P}}}sp")
    pics = sp_tree.findall(f"{{{NS_P}}}pic")
    all_text = " ".join(get_text(sp) for sp in sps).lower()

    toc_keywords = ["목차", "contents", "agenda", "index", "table of content"]
    if any(kw in all_text for kw in toc_keywords):
        return "TOC"
    if len(all_text) < 50 and len(pics) >= 2:
        return "COVER"
    if len(sps) <= 3 and len(all_text) < 100:
        return "COVER"
    return "CONTENT"


# ─────────────────────────────────────────────
# 소스 후보 매칭 — 본문 sp 수(y≥130pt) 기준
# ─────────────────────────────────────────────
def count_body_sps(xml_str):
    """y≥HEADER_Y_MAX인 sp 수 반환"""
    root = ET.fromstring(xml_str)
    count = 0
    for sp in root.findall(f".//{{{NS_P}}}sp"):
        xywh = get_xywh(sp)
        if xywh and xywh[1] >= HEADER_Y_MAX:
            count += 1
    return count


def find_best_source(tgt_xml, src_candidates, src_entries):
    """타겟 본문 sp 수와 가장 유사한 소스 슬라이드 인덱스 반환"""
    tgt_body_count = count_body_sps(tgt_xml)
    best_idx = src_candidates[0]
    best_diff = float("inf")

    for src_idx in src_candidates:
        src_name = f"ppt/slides/slide{src_idx}.xml"
        if src_name not in src_entries:
            continue
        src_xml = src_entries[src_name].decode("utf-8")
        diff = abs(count_body_sps(src_xml) - tgt_body_count)
        if diff < best_diff:
            best_diff = diff
            best_idx = src_idx

    return best_idx, best_diff


# ─────────────────────────────────────────────
# fill-in 핵심: 소스 deepcopy + 타겟 텍스트 교체 + 이미지 오버레이
# ─────────────────────────────────────────────
def extract_texts_by_zone(xml_str):
    """
    헤더(y < HEADER_Y_MAX)와 본문(y >= HEADER_Y_MAX)으로 분리해서 텍스트 반환.
    각 존에서 y 오름차순 정렬.
    반환: (header_texts: list[str], body_texts: list[str])
    """
    root = ET.fromstring(xml_str)
    headers, bodies = [], []
    for sp in root.findall(f".//{{{NS_P}}}sp"):
        xywh = get_xywh(sp)
        txt = get_text(sp)
        if not txt:
            continue
        y = xywh[1] if xywh else HEADER_Y_MAX
        if y < HEADER_Y_MAX:
            headers.append((y, txt))
        else:
            bodies.append((y, txt))
    headers.sort(key=lambda t: t[0])
    bodies.sort(key=lambda t: t[0])
    return [t[1] for t in headers], [t[1] for t in bodies]


def replace_texts_in_sps(sps, texts):
    """sps 순서대로 texts를 1:1 매핑해서 교체. 초과 텍스트는 절단."""
    valid_sps = [sp for sp in sps if get_text(sp) or sp.find(f".//{{{NS_A}}}txBody") is not None]
    for i, sp in enumerate(valid_sps):
        if i < len(texts):
            set_all_text(sp, texts[i])
        # i >= len(texts) 이면 해당 sp는 기존 텍스트 유지 (소스 레이아웃 텍스트)


def fill_in_slide(src_xml_str, tgt_xml_str):
    """
    소스 슬라이드 deepcopy → 타겟 텍스트 이식 → 타겟 이미지 오버레이.
    반환: 결과 XML 문자열
    """
    src_root = ET.fromstring(src_xml_str)
    tgt_root = ET.fromstring(tgt_xml_str)

    # 소스 deepcopy를 출력 기반으로
    out_root = copy.deepcopy(src_root)
    out_tree = out_root.find(f".//{{{NS_P}}}spTree")
    if out_tree is None:
        return src_xml_str

    # 타겟 텍스트 추출 (헤더/본문 분리)
    tgt_header_texts, tgt_body_texts = extract_texts_by_zone(tgt_xml_str)

    # 출력 sp 분리 (헤더/본문)
    out_sps = out_tree.findall(f"{{{NS_P}}}sp")
    out_header_sps = []
    out_body_sps   = []
    for sp in out_sps:
        xywh = get_xywh(sp)
        y = xywh[1] if xywh else HEADER_Y_MAX
        if y < HEADER_Y_MAX:
            out_header_sps.append(sp)
        else:
            out_body_sps.append(sp)

    # 텍스트 1:1 매핑 교체
    replace_texts_in_sps(out_header_sps, tgt_header_texts)
    replace_texts_in_sps(out_body_sps,   tgt_body_texts)

    # 타겟 이미지(pic) 오버레이
    tgt_tree = tgt_root.find(f".//{{{NS_P}}}spTree")
    if tgt_tree is not None:
        for pic in tgt_tree.findall(f"{{{NS_P}}}pic"):
            out_tree.append(copy.deepcopy(pic))

    return ET.tostring(out_root, encoding="unicode", xml_declaration=False)


# ─────────────────────────────────────────────
# PPTX 파일 읽기/쓰기
# ─────────────────────────────────────────────
def read_pptx(path):
    entries = {}
    with zipfile.ZipFile(path, "r") as zf:
        for name in zf.namelist():
            entries[name] = zf.read(name)
    return entries


def write_pptx(entries, path):
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for name, data in entries.items():
            zf.writestr(name, data)


def get_slide_names(entries):
    names = [n for n in entries if re.match(r"ppt/slides/slide\d+\.xml$", n)]
    names.sort(key=lambda n: int(re.search(r"\d+", n.split("/")[-1]).group()))
    return names


# ─────────────────────────────────────────────
# 메인 로직
# ─────────────────────────────────────────────
def clone_pptx(src_path, tgt_path, out_path):
    print(f"[pptClone] 소스: {src_path}")
    print(f"[pptClone] 타겟: {tgt_path}")
    print(f"[pptClone] 출력: {out_path}")

    src_entries = read_pptx(src_path)
    tgt_entries = read_pptx(tgt_path)

    src_slides = get_slide_names(src_entries)
    tgt_slides = get_slide_names(tgt_entries)

    src_total = len(src_slides)
    tgt_total = len(tgt_slides)
    print(f"[pptClone] 소스 슬라이드: {src_total}, 타겟 슬라이드: {tgt_total}")

    # 소스 구조별 인덱스 목록 (1-based)
    src_covers = list(range(COVER_RANGE[0], min(COVER_RANGE[1], src_total) + 1))
    src_tocs   = list(range(TOC_RANGE[0],   min(TOC_RANGE[1],   src_total) + 1))
    src_bodies = list(range(BODY_START, src_total + 1))
    if not src_bodies and src_total >= HEADER_SAMPLE:
        src_bodies = [HEADER_SAMPLE]

    # 출력: 타겟 기반 (미디어/릴레이션/테마 등은 소스로 교체 예정)
    out_entries = dict(tgt_entries)

    for i, tgt_name in enumerate(tgt_slides):
        tgt_xml = tgt_entries[tgt_name].decode("utf-8")
        slide_num = i + 1
        slide_type = classify_slide(tgt_xml, slide_num)

        # 유형별 소스 후보 결정
        if slide_type == "COVER":
            candidates = src_covers
        elif slide_type == "TOC":
            candidates = src_tocs if src_tocs else src_covers
        else:
            candidates = src_bodies if src_bodies else src_covers

        if not candidates:
            print(f"  slide{slide_num:02d} → {slide_type} [소스 후보 없음, 스킵]")
            continue

        best_idx, diff = find_best_source(tgt_xml, candidates, src_entries)
        src_name = f"ppt/slides/slide{best_idx}.xml"

        if src_name not in src_entries:
            print(f"  slide{slide_num:02d} → {slide_type} [소스 slide{best_idx} 없음, 스킵]")
            continue

        src_xml = src_entries[src_name].decode("utf-8")
        result_xml = fill_in_slide(src_xml, tgt_xml)
        out_entries[tgt_name] = result_xml.encode("utf-8")

        tgt_body_n = count_body_sps(tgt_xml)
        src_body_n = count_body_sps(src_xml)
        print(f"  slide{slide_num:02d} → {slide_type} ← 소스slide{best_idx} "
              f"(본문sp: 타겟={tgt_body_n}, 소스={src_body_n}, diff={diff})")

    # 소스 테마 이식 (색상 테마)
    src_theme = "ppt/theme/theme1.xml"
    if src_theme in src_entries:
        out_entries[src_theme] = src_entries[src_theme]
        print(f"[pptClone] 소스 테마 복사: {src_theme}")

    write_pptx(out_entries, out_path)
    print(f"[pptClone] 완료: {out_path} ({os.path.getsize(out_path):,} bytes)")


# ─────────────────────────────────────────────
# CLI
# ─────────────────────────────────────────────
def main():
    import argparse
    parser = argparse.ArgumentParser(description="pptClone — 소스 레이아웃으로 타겟 PPTX 텍스트 이식")
    parser.add_argument("source", help="소스 파일명 (확장자 생략 가능)")
    parser.add_argument("target", help="타겟 파일명 (확장자 생략 가능)")
    parser.add_argument("output", nargs="?", help="출력 파일명 (생략 시 {target}_cloned)")
    parser.add_argument("--template-dir", default="template", help="템플릿 디렉토리 (기본: template)")
    args = parser.parse_args()

    tdir = args.template_dir

    def resolve(name):
        if not name.endswith(".pptx"):
            name += ".pptx"
        if os.path.isabs(name) or os.path.exists(name):
            return name
        return os.path.join(tdir, name)

    src_path = resolve(args.source)
    tgt_path = resolve(args.target)

    if args.output:
        out_name = args.output if args.output.endswith(".pptx") else args.output + ".pptx"
        out_path = os.path.join(tdir, out_name) if not os.path.isabs(out_name) else out_name
    else:
        base = os.path.splitext(os.path.basename(tgt_path))[0]
        out_path = os.path.join(tdir, f"{base}_cloned.pptx")

    if not os.path.exists(src_path):
        print(f"[오류] 소스 파일 없음: {src_path}", file=sys.stderr)
        sys.exit(1)
    if not os.path.exists(tgt_path):
        print(f"[오류] 타겟 파일 없음: {tgt_path}", file=sys.stderr)
        sys.exit(1)

    clone_pptx(src_path, tgt_path, out_path)


if __name__ == "__main__":
    main()
