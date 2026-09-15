#!/usr/bin/env python3
"""
pptColor.py — PPTX 템플릿 테마 색상 교체 스크립트

소스 파일의 모든 유채색 중 dominant hue를 자동 감지하여 대상 hue로 회전 교체.
- replace_color_scheme() 미사용: 다색 테마의 비-주색 보존
- clrScheme name 속성만 업데이트 (경량)
- 변환 시 brandlogy 로고/텍스트 요소 자동 제거.

사용법:
    python3 pptColor.py <소스> <대상> [출력명] [--template-dir <경로>]

소스/대상: 팔레트 이름(red, blue ...) 또는 hex 컬러코드(#RRGGBB) 또는 자유 색상명(mint, coral ...)

예시:
    python3 pptColor.py red blue
    python3 pptColor.py red mint
    python3 pptColor.py red "#3EB489"
    python3 pptColor.py red "#3EB489" mint
"""

import argparse
import shutil
import sys
import zipfile
import re
import colorsys
import tempfile
from pathlib import Path
from collections import Counter


# ─────────────────────────────────────────────────────────
# 내장 팔레트 (tgt hue 참조용 — src_hue는 파일에서 자동 감지)
# ─────────────────────────────────────────────────────────
COLOR_PALETTES = {
    "red": {
        "clrScheme_name": "Red",
        "hue": 0.0,
        "dk2": "3B0000", "lt2": "F2DEDE",
        "accent1": "C0392B", "accent2": "E74C3C", "accent3": "922B21",
        "accent4": "F1948A", "accent5": "7B241C", "accent6": "FADBD8",
        "hlink": "C0392B", "folHlink": "922B21",
    },
    "blue": {
        "clrScheme_name": "Blue",
        "hue": 210.0,
        "dk2": "0E2841", "lt2": "D6EAF8",
        "accent1": "1A5276", "accent2": "2E86C1", "accent3": "1F618D",
        "accent4": "85C1E9", "accent5": "154360", "accent6": "D6EAF8",
        "hlink": "2471A3", "folHlink": "1A5276",
    },
    "green": {
        "clrScheme_name": "Green",
        "hue": 130.0,
        "dk2": "0B3D0B", "lt2": "D5F5E3",
        "accent1": "1E8449", "accent2": "27AE60", "accent3": "1D8348",
        "accent4": "82E0AA", "accent5": "145A32", "accent6": "D5F5E3",
        "hlink": "1E8449", "folHlink": "145A32",
    },
    "orange": {
        "clrScheme_name": "Orange",
        "hue": 25.0,
        "dk2": "4A1800", "lt2": "FDEBD0",
        "accent1": "D35400", "accent2": "E67E22", "accent3": "BA4A00",
        "accent4": "F0B27A", "accent5": "A04000", "accent6": "FDEBD0",
        "hlink": "D35400", "folHlink": "BA4A00",
    },
    "purple": {
        "clrScheme_name": "Purple",
        "hue": 280.0,
        "dk2": "2E0854", "lt2": "E8DAEF",
        "accent1": "6C3483", "accent2": "8E44AD", "accent3": "76448A",
        "accent4": "C39BD3", "accent5": "512E5F", "accent6": "E8DAEF",
        "hlink": "7D3C98", "folHlink": "6C3483",
    },
    "teal": {
        "clrScheme_name": "Teal",
        "hue": 168.0,
        "dk2": "003333", "lt2": "D0ECE7",
        "accent1": "148F77", "accent2": "1ABC9C", "accent3": "117A65",
        "accent4": "76D7C4", "accent5": "0E6655", "accent6": "D0ECE7",
        "hlink": "17A589", "folHlink": "148F77",
    },
    "yellow": {
        "clrScheme_name": "Yellow",
        "hue": 45.0,
        "dk2": "4A3B00", "lt2": "FEF9E7",
        "accent1": "B7950B", "accent2": "D4AC0D", "accent3": "9A7D0A",
        "accent4": "F9E79F", "accent5": "7D6608", "accent6": "FEF9E7",
        "hlink": "B7950B", "folHlink": "9A7D0A",
    },
    "pink": {
        "clrScheme_name": "Pink",
        "hue": 340.0,
        "dk2": "4A0026", "lt2": "FDEDEC",
        "accent1": "C0392B", "accent2": "E91E8C", "accent3": "AD1457",
        "accent4": "F48FB1", "accent5": "880E4F", "accent6": "FCE4EC",
        "hlink": "E91E8C", "folHlink": "AD1457",
    },
    "gray": {
        "clrScheme_name": "Gray",
        "hue": None,  # 무채색 — hue 교체 없음
        "dk2": "1C1C1C", "lt2": "EAECEE",
        "accent1": "4D5656", "accent2": "717D7E", "accent3": "616A6B",
        "accent4": "ABB2B9", "accent5": "2C3E50", "accent6": "D5D8DC",
        "hlink": "5D6D7E", "folHlink": "4D5656",
    },
    "navy": {
        "clrScheme_name": "Navy",
        "hue": 220.0,
        "dk2": "001433", "lt2": "D6DBDF",
        "accent1": "1B2A49", "accent2": "2E4482", "accent3": "1A237E",
        "accent4": "7986CB", "accent5": "0D1B2A", "accent6": "C5CAE9",
        "hlink": "283593", "folHlink": "1A237E",
    },
}

# 자유 색상 이름 → hex 매핑
COLOR_NAME_MAP = {
    "mint":      "3EB489", "lime":      "32CD32", "sage":      "8FBC8F",
    "olive":     "6B8E23", "forest":    "228B22", "emerald":   "50C878",
    "sky":       "87CEEB", "azure":     "007FFF", "cobalt":    "0047AB",
    "indigo":    "4B0082", "cerulean":  "2A52BE", "aqua":      "00FFFF",
    "cyan":      "00BCD4", "coral":     "FF6B6B", "salmon":    "FA8072",
    "crimson":   "DC143C", "rose":      "FF007F", "magenta":   "FF00FF",
    "maroon":    "800000", "amber":     "FFBF00", "gold":      "FFD700",
    "tan":       "D2B48C", "khaki":     "C3B091", "peach":     "FFCBA4",
    "violet":    "EE82EE", "lavender":  "967BB6", "lilac":     "C8A2C8",
    "plum":      "DDA0DD", "mauve":     "E0B0FF", "slate":     "708090",
    "charcoal":  "36454F", "ivory":     "FFFFF0", "cream":     "FFFDD0",
    "beige":     "F5F5DC", "brown":     "8B4513", "chocolate": "D2691E",
    "silver":    "C0C0C0",
}


# ─────────────────────────────────────────────────────────
# 색상 유틸
# ─────────────────────────────────────────────────────────
def hex_to_rgb(hex6: str) -> tuple:
    h = hex6.lstrip("#")
    return tuple(int(h[i:i+2], 16) / 255.0 for i in (0, 2, 4))


def rgb_to_hex(r: float, g: float, b: float) -> str:
    return f"{int(r*255):02X}{int(g*255):02X}{int(b*255):02X}"


def hue_of(hex6: str) -> float:
    """hex → hue 0~360"""
    r, g, b = hex_to_rgb(hex6)
    h, s, v = colorsys.rgb_to_hsv(r, g, b)
    return h * 360.0


def sat_of(hex6: str) -> float:
    r, g, b = hex_to_rgb(hex6)
    _, s, _ = colorsys.rgb_to_hsv(r, g, b)
    return s


def hue_distance(h1: float, h2: float) -> float:
    """0~360 범위에서 두 hue의 최소 거리"""
    d = abs(h1 - h2) % 360
    return min(d, 360 - d)


def rotate_hue(hex6: str, src_hue: float, dst_hue: float, threshold: float = 40.0) -> str:
    """
    hex 색상의 hue가 src_hue에서 threshold 이내이면 dst_hue로 회전.
    채도가 낮으면(< 0.12) 무채색으로 간주하여 변경하지 않음.
    """
    r, g, b = hex_to_rgb(hex6)
    h, s, v = colorsys.rgb_to_hsv(r, g, b)
    hue_deg = h * 360.0

    # 무채색 스킵
    if s < 0.12:
        return hex6.lstrip("#").upper()

    if hue_distance(hue_deg, src_hue) > threshold:
        return hex6.lstrip("#").upper()

    # hue 회전 (src_hue 기준 상대 오프셋 유지)
    offset = hue_deg - src_hue
    new_hue = (dst_hue + offset) % 360
    r2, g2, b2 = colorsys.hsv_to_rgb(new_hue / 360.0, s, v)
    return rgb_to_hex(r2, g2, b2)


def lighten(hex6: str, amount: float = 0.85) -> str:
    r, g, b = hex_to_rgb(hex6)
    r2 = r + (1 - r) * amount
    g2 = g + (1 - g) * amount
    b2 = b + (1 - b) * amount
    return rgb_to_hex(r2, g2, b2)


def darken(hex6: str, factor: float = 0.35) -> str:
    r, g, b = hex_to_rgb(hex6)
    return rgb_to_hex(r * factor, g * factor, b * factor)


def adjust_brightness(hex6: str, factor: float) -> str:
    r, g, b = hex_to_rgb(hex6)
    h, s, v = colorsys.rgb_to_hsv(r, g, b)
    v2 = max(0.0, min(1.0, v * factor))
    r2, g2, b2 = colorsys.hsv_to_rgb(h, s, v2)
    return rgb_to_hex(r2, g2, b2)


def derive_palette(base_hex: str, scheme_name: str) -> dict:
    """hex 주색으로 전체 팔레트 자동 파생."""
    h = base_hex.lstrip("#").upper()
    hue = hue_of(h)
    return {
        "clrScheme_name": scheme_name,
        "hue": hue,
        "dk2":     darken(h, 0.25),
        "lt2":     lighten(h, 0.88),
        "accent1": h,
        "accent2": adjust_brightness(h, 1.25),
        "accent3": adjust_brightness(h, 0.80),
        "accent4": lighten(h, 0.55),
        "accent5": adjust_brightness(h, 0.50),
        "accent6": lighten(h, 0.90),
        "hlink":   h,
        "folHlink": adjust_brightness(h, 0.75),
    }



# ─────────────────────────────────────────────────────────
# 자연어 색상 지시어 파싱
# ─────────────────────────────────────────────────────────

# 자연어 지시어 → (조작 종류, 강도)
# 강도: 약(0.15) / 보통(0.30) / 강(0.55)
_NATURAL_DIRECTIVES = {
    # 어둡게
    "어둡게":       ("darken", 0.30),
    "좀어둡게":     ("darken", 0.20),
    "좀더어둡게":   ("darken", 0.30),
    "많이어둡게":   ("darken", 0.55),
    "더어둡게":     ("darken", 0.40),
    "어둡":         ("darken", 0.30),
    "dark":         ("darken", 0.30),
    "darker":       ("darken", 0.40),
    "darkest":      ("darken", 0.55),
    # 밝게
    "밝게":         ("lighten", 0.30),
    "좀밝게":       ("lighten", 0.20),
    "좀더밝게":     ("lighten", 0.30),
    "많이밝게":     ("lighten", 0.55),
    "더밝게":       ("lighten", 0.40),
    "밝":           ("lighten", 0.30),
    "light":        ("lighten", 0.30),
    "lighter":      ("lighten", 0.40),
    "lightest":     ("lighten", 0.55),
    # 채도
    "선명하게":     ("saturate", 0.25),
    "채도높게":     ("saturate", 0.25),
    "더선명하게":   ("saturate", 0.40),
    "탁하게":       ("desaturate", 0.25),
    "채도낮게":     ("desaturate", 0.25),
    "더탁하게":     ("desaturate", 0.40),
    # 따뜻/차갑 (hue shift)
    "따뜻하게":     ("hue_shift", -20),
    "더따뜻하게":   ("hue_shift", -35),
    "차갑게":       ("hue_shift", +20),
    "더차갑게":     ("hue_shift", +35),
}


def _apply_directive(hex6: str, directive: str) -> str | None:
    """자연어 지시어를 hex에 적용. 미인식 시 None 반환."""
    key = directive.lower().replace(" ", "").replace("_", "")
    # 공백/언더스코어 제거 후 매핑 재시도
    mapping = {k.replace(" ", "").replace("_", ""): v for k, v in _NATURAL_DIRECTIVES.items()}
    if key not in mapping:
        return None
    op, amount = mapping[key]
    r, g, b = hex_to_rgb(hex6)
    h, s, v = colorsys.rgb_to_hsv(r, g, b)
    if op == "darken":
        v = max(0.0, v * (1.0 - amount))
    elif op == "lighten":
        v = min(1.0, v + (1.0 - v) * amount)
    elif op == "saturate":
        s = min(1.0, s + (1.0 - s) * amount)
    elif op == "desaturate":
        s = max(0.0, s * (1.0 - amount))
    elif op == "hue_shift":
        h = (h * 360 + amount) % 360 / 360
    r2, g2, b2 = colorsys.hsv_to_rgb(h, s, v)
    return rgb_to_hex(r2, g2, b2)


def is_natural_directive(s: str) -> bool:
    """자연어 지시어인지 판별 (hex도 팔레트명도 아닌 경우)"""
    return (not is_hex_color(s)
            and s.lower() not in COLOR_PALETTES
            and s.lower() not in COLOR_NAME_MAP)

def is_hex_color(s: str) -> bool:
    return bool(re.fullmatch(r"#?[0-9A-Fa-f]{6}", s))


def resolve_color(arg: str) -> tuple:
    """인자 → (palette_dict, file_stem)"""
    lower = arg.lower()
    if lower in COLOR_PALETTES:
        return COLOR_PALETTES[lower], lower
    if is_hex_color(arg):
        h = arg.lstrip("#").upper()
        return derive_palette(h, h), h
    if lower in COLOR_NAME_MAP:
        h = COLOR_NAME_MAP[lower]
        print(f"   '{arg}' → #{h} 자동 매핑")
        return derive_palette(h, lower), lower
    known = sorted(list(COLOR_PALETTES.keys()) + list(COLOR_NAME_MAP.keys()))
    print(f"❌ 알 수 없는 색상: '{arg}'", file=sys.stderr)
    print(f"   지원 이름: {', '.join(known)}", file=sys.stderr)
    print(f"   또는 hex 코드: #RRGGBB 형식 사용", file=sys.stderr)
    sys.exit(1)


# ─────────────────────────────────────────────────────────
# 소스 파일 dominant hue 자동 감지
# ─────────────────────────────────────────────────────────
def detect_dominant_hue(src_path: str, sat_threshold: float = 0.2) -> float | None:
    """
    소스 PPTX 파일의 모든 XML에서 srgbClr을 수집하고,
    채도 >= sat_threshold인 유채색의 hue 분포를 분석하여
    가장 많이 등장하는 dominant hue를 반환.
    무채색만 있거나 색상이 없으면 None 반환.
    """
    try:
        hue_counts = Counter()
        with zipfile.ZipFile(src_path, 'r') as z:
            for fname in z.namelist():
                if not fname.endswith('.xml'):
                    continue
                xml = z.read(fname).decode('utf-8')
                for m in re.finditer(r'<a:srgbClr val="([0-9A-Fa-f]{6})"', xml):
                    hex6 = m.group(1).upper()
                    r, g, b = hex_to_rgb(hex6)
                    h, s, v = colorsys.rgb_to_hsv(r, g, b)
                    if s >= sat_threshold:
                        # 10° 단위 버킷으로 집계 (원형 hue 공간)
                        bucket = round(h * 36) % 36  # 0~35 (각 10°)
                        hue_counts[bucket] += 1

        if not hue_counts:
            return None

        # 인접 버킷 합산 (±10° 이내 클러스터링)
        best_center = None
        best_count = 0
        for bucket in range(36):
            count = (hue_counts.get(bucket, 0) +
                     hue_counts.get((bucket - 1) % 36, 0) +
                     hue_counts.get((bucket + 1) % 36, 0))
            if count > best_count:
                best_count = count
                best_center = bucket

        if best_center is None:
            return None

        # 클러스터 내 가중 평균 hue 계산 (원형 평균)
        total = 0
        sin_sum = 0.0
        cos_sum = 0.0
        for offset in [-1, 0, 1]:
            b = (best_center + offset) % 36
            cnt = hue_counts.get(b, 0)
            hue_rad = b * 10 * (3.14159265 / 180)
            sin_sum += cnt * __import__('math').sin(hue_rad)
            cos_sum += cnt * __import__('math').cos(hue_rad)
            total += cnt

        import math
        dominant = math.degrees(math.atan2(sin_sum, cos_sum)) % 360
        return dominant

    except Exception:
        return None


# ─────────────────────────────────────────────────────────
# XML 교체
# ─────────────────────────────────────────────────────────
def update_scheme_name(xml: str, scheme_name: str) -> str:
    """clrScheme name 속성만 업데이트 (색상값 변경 없음)."""
    return re.sub(
        r'(<a:clrScheme\s+name=")[^"]*(")',
        rf'\g<1>{scheme_name}\g<2>',
        xml
    )


def replace_hue_in_xml(xml: str, src_hue: float, dst_hue: float, threshold: float = 40.0) -> str:
    """XML 내 모든 srgbClr val을 hue 회전으로 교체.
    
    두 가지 형태 모두 처리:
    - 셀프클로징: <a:srgbClr val="RRGGBB"/>  → <a:srgbClr val="NEW"/>
    - 자식 포함:  <a:srgbClr val="RRGGBB"><a:alpha .../></a:srgbClr>
                 → <a:srgbClr val="NEW"><a:alpha .../></a:srgbClr>
    """
    def replacer_self(m):
        new_hex = rotate_hue(m.group(1), src_hue, dst_hue, threshold)
        return f'<a:srgbClr val="{new_hex}"/>'

    def replacer_open(m):
        new_hex = rotate_hue(m.group(1), src_hue, dst_hue, threshold)
        return f'<a:srgbClr val="{new_hex}">'

    # 1) 셀프클로징 형태
    xml = re.sub(r'<a:srgbClr val="([0-9A-Fa-f]{6})"/>', replacer_self, xml)
    # 2) 자식 요소가 있는 여는 태그 형태 (셀프클로징이 아닌 것)
    xml = re.sub(r'<a:srgbClr val="([0-9A-Fa-f]{6})">', replacer_open, xml)
    return xml


# brandlogy 우측상단 이미지 기준: x >= 29cm (= 10440000 EMU)
_BRANDLOGY_X_EMU = 29 * 360000


def remove_brandlogy_elements(xml: str, filename: str) -> tuple:
    """
    모든 슬라이드/마스터 XML에서 brandlogy 관련 요소 제거.
    - BRANDLOGY 텍스트가 포함된 <p:sp> 요소 제거 (slideMaster 전용)
    - 우측 상단(x >= 29cm)에 위치한 <p:pic> 요소 제거 (모든 슬라이드 적용)
    반환: (수정된 xml, 제거된 요소 수)
    """
    if not filename.endswith('.xml'):
        return xml, 0

    modified = xml
    total_removed = 0

    # 1) BRANDLOGY 텍스트가 포함된 <p:sp> 요소 제거 (slideMaster에만 존재)
    if 'slideMaster' in filename:
        sp_pattern = re.compile(
            r'<p:sp>(?:(?!</p:sp>).)*?BRANDLOGY(?:(?!</p:sp>).)*?</p:sp>',
            re.DOTALL
        )
        matches = sp_pattern.findall(modified)
        if matches:
            modified = sp_pattern.sub('', modified)
            total_removed += len(matches)

    # 2) 우측 상단(x >= 29cm)에 위치한 <p:pic> 요소 제거
    # 슬라이드마다 이미지 이름(그림 6, 그림 9 등)이 다를 수 있으므로 위치로 식별
    pic_pattern = re.compile(r'<p:pic>.*?</p:pic>', re.DOTALL)
    def remove_if_brandlogy(m):
        p = m.group(0)
        off = re.search(r'off x="(\d+)"', p)
        if off and int(off.group(1)) >= _BRANDLOGY_X_EMU:
            return ''
        return p
    prev_len = len(modified)
    result = pic_pattern.sub(remove_if_brandlogy, modified)
    removed_pics = (prev_len - len(result)) > 0
    if removed_pics:
        # 제거된 pic 수 계산
        orig_pics = len(pic_pattern.findall(modified))
        new_pics = len(pic_pattern.findall(result))
        removed_count = orig_pics - new_pics
        total_removed += removed_count
        modified = result

    return modified, total_removed


def convert_template(src_path: str, dst_path: str,
                     src_palette: dict, tgt_palette: dict,
                     remove_brandlogy: bool = True,
                     threshold: float = 40.0) -> None:
    src = Path(src_path)
    dst = Path(dst_path)

    if not src.exists():
        print(f"❌ 소스 파일 없음: {src}", file=sys.stderr)
        sys.exit(1)

    dst.parent.mkdir(parents=True, exist_ok=True)

    # src_hue: 파일 전체의 dominant hue 자동 감지
    src_hue = detect_dominant_hue(str(src))
    tgt_hue = tgt_palette.get("hue")

    if src_hue is None:
        print("   ⚠️  소스 파일 dominant hue 감지 실패 — 팔레트 정의 hue 사용")
        src_hue = src_palette.get("hue")
    else:
        print(f"   감지된 소스 dominant hue: {src_hue:.0f}°")

    with tempfile.NamedTemporaryFile(suffix=".pptx", delete=False) as tmp:
        tmp_path = tmp.name

    replaced_count = 0
    brandlogy_removed = 0
    try:
        with zipfile.ZipFile(src, 'r') as zin, \
             zipfile.ZipFile(tmp_path, 'w', compression=zipfile.ZIP_DEFLATED) as zout:
            for item in zin.infolist():
                data = zin.read(item.filename)
                if item.filename.endswith('.xml'):
                    xml_str = data.decode('utf-8')
                    original = xml_str

                    # 1) 테마 scheme name만 업데이트 (색상값 변경 없음)
                    if re.match(r'ppt/theme/theme\d+\.xml$', item.filename):
                        xml_str = update_scheme_name(xml_str, tgt_palette["clrScheme_name"])

                    # 2) hue 회전 (src/tgt hue가 모두 있을 때)
                    if src_hue is not None and tgt_hue is not None:
                        xml_str = replace_hue_in_xml(xml_str, src_hue, tgt_hue, threshold)

                    # 3) brandlogy 요소 제거
                    if remove_brandlogy:
                        xml_str, removed = remove_brandlogy_elements(xml_str, item.filename)
                        brandlogy_removed += removed

                    if xml_str != original:
                        replaced_count += 1
                    data = xml_str.encode('utf-8')
                zout.writestr(item, data)
        shutil.move(tmp_path, dst)
        print(f"   색상 교체된 XML 파일: {replaced_count}개")
        if brandlogy_removed > 0:
            print(f"   brandlogy 요소 제거: {brandlogy_removed}개")
    except Exception as e:
        Path(tmp_path).unlink(missing_ok=True)
        raise e


# ─────────────────────────────────────────────────────────
# 메인
# ─────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(
        description="PPTX 템플릿 테마 색상 교체 (hue 회전 방식)",
        epilog=f"팔레트 이름: {', '.join(COLOR_PALETTES.keys())}"
    )
    parser.add_argument("source_color", help="소스 색상 (이름 또는 #RRGGBB)")
    parser.add_argument("target_color", help="대상 색상 (이름 또는 #RRGGBB)")
    parser.add_argument("output_name", nargs="?", default=None,
                        help="출력 파일명 stem (생략 시 자동)")
    parser.add_argument("--template-dir", default="template",
                        help="템플릿 폴더 경로 (기본: template)")
    parser.add_argument("--threshold", type=float, default=40.0,
                        help="hue 매칭 허용 범위(도) (기본: 40)")
    parser.add_argument("--keep-brandlogy", action="store_true",
                        help="brandlogy 요소를 제거하지 않음")
    args = parser.parse_args()

    src_palette, src_stem = resolve_color(args.source_color)

    # 자연어 지시어 처리: 소스 파일 accent1 읽어 조작
    if is_natural_directive(args.target_color):
        template_dir_early = Path(args.template_dir)
        src_file_early = template_dir_early / f"{src_stem}.pptx"
        # 소스 파일 accent1 추출
        import zipfile as _zf
        src_accent1 = None
        if src_file_early.exists():
            with _zf.ZipFile(str(src_file_early), 'r') as _z:
                for _fname in _z.namelist():
                    if 'theme' in _fname and _fname.endswith('.xml'):
                        _xml = _z.read(_fname).decode('utf-8')
                        import re as _re
                        _m = _re.search(r'<a:dk1[^>]*>.*?</a:dk1>|<a:accent1[^>]*>.*?<a:srgbClr val="([0-9A-Fa-f]{6})"', _xml, _re.DOTALL)
                        _m2 = _re.search(r'<a:accent1[^/]*?<a:srgbClr val="([0-9A-Fa-f]{6})"', _xml, _re.DOTALL)
                        if _m2:
                            src_accent1 = _m2.group(1).upper()
                            break
        if src_accent1 is None:
            # fallback: src_palette accent1 사용
            src_accent1 = src_palette.get("accent1", "808080")
        new_hex = _apply_directive(src_accent1, args.target_color)
        if new_hex is None:
            print(f"❌ 알 수 없는 자연어 지시어: '{args.target_color}'", file=sys.stderr)
            print(f"   지원: {', '.join(_NATURAL_DIRECTIVES.keys())}", file=sys.stderr)
            sys.exit(1)
        directive_label = args.target_color.lower().replace(" ", "")
        print(f"   자연어 지시어 '{args.target_color}': #{src_accent1} → #{new_hex}")
        tgt_palette = derive_palette(new_hex, directive_label)
        tgt_stem = directive_label
    else:
        tgt_palette, tgt_stem = resolve_color(args.target_color)

    out_stem = args.output_name.lower() if args.output_name else tgt_stem

    template_dir = Path(args.template_dir)
    src_file = template_dir / f"{src_stem}.pptx"
    dst_file = template_dir / f"{out_stem}.pptx"

    print(f"🎨 테마 색상 변환: {src_stem} → {out_stem}")
    print(f"   소스: {src_file}")
    print(f"   대상: {dst_file}")

    convert_template(
        str(src_file), str(dst_file),
        src_palette, tgt_palette,
        remove_brandlogy=not args.keep_brandlogy,
        threshold=args.threshold
    )
    print(f"✅ 완료: {dst_file} 생성")


if __name__ == "__main__":
    main()
