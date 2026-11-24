"""#337 命名改名的 recon / apply 引擎。

用法（由 tools/naming.lua 调用；直接跑只用于调试，--apply 的干净工作区保护在 Lua 层）：
  python tools/naming/engine.py --recon [--layer l3a|l3b|all] [--root DIR] [--json] [--summary]
  python tools/naming/engine.py --apply [--layer l3a|l3b|all] [--root DIR]

口径：
  - l3a：449 个标识符（方法名、局部变量、字段）按 token 改；跳过字符串、保留注释，
    所以 require 路径、协议串不会被误改，注释和 docs/ 跟着改（与 b3a1855 一致）。
  - l3b：45 个方法名只改成员访问/定义（.Name / :Name），并按 l3b_rename.py 当年的
    官方构造器、Vector3:Length、Task:Spawn、BaseController:Move/GetState、Unit:Destroy
    等排除口径跳过；另带 4 处按名查找的字面量特例。
  - --recon 只打印将要改的位置；--apply 才落盘。两者用同一份 data/*.txt 映射。
"""
import argparse
import bisect
import collections
import json
import os
import re
import sys
import tempfile
from pathlib import Path

DATA_DIR = Path(__file__).resolve().parent / "data"
ROOTS = ("client", "common", "server", "tests", "tools")
EXCL_SUBSTR = ("/packages/", "/_trigger/")

L3A_MAP = DATA_DIR / "l3a_renames.txt"
L3B_MAP = DATA_DIR / "l3b_renames.txt"

OFFICIAL_NEW = set("""Vector2 Vector3 Color RaycastParams RemoteEvent CFrame Vector4 Animation Axes BoundingBox
Color3 ColorSequence ColorSequenceKeypoint Faces DataStoreGetOptions DataStoreGetVersionOptions
DataStoreIncrementOptions DataStoreListKeyOptions DataStoreListOptions DataStoreOptions
DataStoreRemoveOptions DataStoreRemoveVersionOptions DataStoreSetOptions EffectBindData MaterialParam
Matrix Matrix3x3 MemoryStoreHashMapSetOptions MemoryStoreHashMapUpdateOptions MemoryStoreQueueAddOptions
MemoryStoreQueueGetSizeOptions MemoryStoreQueueReadOptions MemoryStoreSortedMapGetRangeOptions
MemoryStoreSortedMapSetOptions MemoryStoreSortedMapUpdateOptions NumberRange NumberSequence
NumberSequenceKeypoint OverlapParams PhysicalProperties Quaternion Ray Region3 Region3int16 Signal
SubCustomAppearance TeleportOptions Transform TweenInfo UDim UDim2 Vector2int16 Vector3int16""".split())

VENDOR = "tests/support/official_ai_vendor_runtime.lua"
DESTROY_ALLOW = {("server/data/player_data.lua", "PlayerData"), ("server/player_data_host.lua", "data")}
SPAWN_ALLOW = {"mgr", "Mgr", "MgrFishCarrier", "Carrier", "Probe"}
# Attach 只改自研运载；能力行为模块与官方锚点行为接口的 Attach 按 ADR-0037 跟随接口，保持 Pascal。
ATTACH_ALLOW_FILES = {
    "common/carry_mount.lua",
    "server/main.lua",
    "server/world_host/fish_ai.lua",
    "server/world_host/fish_carrier.lua",
    "server/world_host/fish_tree.lua",
    "tests/native/ability_proto_test.lua",
    "tests/native/ability_seams_test.lua",
    "tests/native/fish_carrier_test.lua",
    "tests/native/weapon_system_test.lua",
    "tests/probes/ability_proto.lua",
}
# 测试替身里直接以方法名为表键的写法（{ Spawn = function() end }），只限 tests/ 下这几个名字。
BARE_TEST_NAMES = {"Spawn", "Custom", "Stop", "Pause", "Start", "GetState", "Handle", "Attach"}

# l3b 当年手工补的 3 处「按名取方法」字面量；正则的 group 3 或整段替换。
EXTRA = [
    ("server/world_host/server_runtime.lua",
     re.compile(r"(has_method\s*\([^,()]+,\s*([\'\"]))(Start|Stop)([\'\"])"), 3, "has_method 名字符串"),
    ("tests/support/attr_runtime.lua",
     re.compile(r"(?<![\w.])self\.Vitals\.GetState(?![A-Za-z0-9_])"), None, "Vitals 鸭子类型探测"),
    ("tests/native/spec/06_ai_target_test.lua",
     re.compile(r"(?<![\w.])adapter\.State(?![A-Za-z0-9_])"), None, "替身按名取 State"),
]
EXTRA_REPL = {
    "tests/support/attr_runtime.lua": "self.Vitals.get_state",
    "tests/native/spec/06_ai_target_test.lua": "adapter.state",
}
# 9685b9e 顺手同步了一处注释里的示例调用名；改名器默认不动注释，这里单列以保持重放 diff 一致。
RAW_EXTRA = [
    ("tests/support/local_link.lua", re.compile(r"--- 调用方随后 link:Start\(\)"), "--- 调用方随后 link:start()"),
    ("tests/native/spec/client_spoke_backbone_test.lua",
     re.compile(r'(?<="common\.zone_markers"\] = \{ )Start(?= = noop)'), "start"),
]


def fail(message):
    print(message, file=sys.stderr)
    raise SystemExit(1)


def load_map(path):
    rows = []
    text = Path(path).read_text(encoding="utf-8")
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) != 2:
            fail(f"映射行格式不对：{path}: {line}")
        old, new = parts
        if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", old) or not re.match(r"^[a-z0-9_]+$", new):
            fail(f"映射不是标识符/ snake_case：{path}: {line}")
        rows.append((old, new))
    if not rows:
        fail(f"映射为空：{path}")
    return rows


def load_maps(layer):
    maps = {}
    if layer in ("l3a", "all"):
        maps["l3a"] = load_map(L3A_MAP)
    if layer in ("l3b", "all"):
        maps["l3b"] = load_map(L3B_MAP)
    seen = {}
    for name, rows in maps.items():
        for old, _ in rows:
            if old in seen:
                fail(f"旧名 {old} 同时出现在 {seen[old]} 与 {name}，apply 顺序会决定结果")
            seen[old] = name
    seen_new = {}
    for name, rows in maps.items():
        for old, new in rows:
            norm = old[:1].lower() + old[1:]
            if new in seen_new and seen_new[new] != norm:
                fail(f"新名 {new} 同时由 {seen_new[new]} 与 {old} 映射，字段会被静默合并")
            seen_new[new] = norm
    return maps


def excluded(rel):
    if any(p in "/" + rel for p in EXCL_SUBSTR):
        return True
    return rel.split("/")[0] == "data"


def collect_files(root, include_docs=False):
    files = []
    for top in ROOTS:
        base = os.path.join(root, top)
        if not os.path.isdir(base):
            continue
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = [d for d in dirnames if d != ".git"]
            for filename in filenames:
                if not filename.endswith(".lua"):
                    continue
                path = os.path.join(dirpath, filename)
                rel = os.path.relpath(path, root).replace("\\", "/")
                if excluded(rel):
                    continue
                files.append((rel, path))
    if include_docs:
        base = os.path.join(root, "docs")
        if os.path.isdir(base):
            for dirpath, dirnames, filenames in os.walk(base):
                dirnames[:] = [d for d in dirnames if d not in ("adr", "packages", "_trigger", "tmp", "target", "evidence", "learn", "data", "unit_scripts")]
                for filename in filenames:
                    if not filename.endswith(".md"):
                        continue
                    path = os.path.join(dirpath, filename)
                    rel = os.path.relpath(path, root).replace("\\", "/")
                    if excluded(rel):
                        continue
                    files.append((rel, path))
    files.sort()
    return files


def _scan(src, blank_strings, blank_comments=True):
    out = list(src)
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == "-" and src.startswith("--", i):
            m = re.match(r"--\[(=*)\[", src[i:])
            if m:
                eq = m.group(1)
                close = "]" + eq + "]"
                j = src.find(close, i + len(m.group(0)))
                j = n if j < 0 else j + len(close)
            else:
                j = src.find("\n", i)
                j = n if j < 0 else j
            if blank_comments:
                for k in range(i, j):
                    out[k] = " "
            i = j
            continue
        if c == "[" and re.match(r"\[(=*)\[", src[i:]):
            m = re.match(r"\[(=*)\[", src[i:])
            eq = m.group(1)
            close = "]" + eq + "]"
            j = src.find(close, i)
            j = n if j < 0 else j + len(close)
            for k in range(i, j):
                out[k] = " "
            i = j
            continue
        if c in "\"'":
            j = i + 1
            while j < n:
                if src[j] == "\\":
                    j += 2
                    continue
                if src[j] == c:
                    j += 1
                    break
                if src[j] == "\n":
                    break
                j += 1
            if blank_strings:
                for k in range(i, j):
                    out[k] = " "
            i = j
            continue
        i += 1
    return "".join(out)


def strip_code(src):
    return _scan(src, True)


def strip_comments(src):
    return _scan(src, False)


def strip_strings(src):
    """L3a 口径：跳过引号内容，但注释照改（b3a1855 连注释和 docs 一起改）。"""
    return _scan(src, True, False)


def read_file(path):
    raw = open(path, "rb").read()
    bom = raw.startswith(b"\xef\xbb\xbf")
    return bom, raw.decode("utf-8-sig" if bom else "utf-8", "surrogateescape")


def write_file(path, src, bom):
    data = src.encode("utf-8", "surrogateescape")
    if bom:
        data = b"\xef\xbb\xbf" + data
    directory = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".naming-", suffix=".tmp")
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def line_starts(src):
    starts = [0]
    for m in re.finditer("\n", src):
        starts.append(m.end())
    return starts


def line_of(starts, pos):
    return bisect.bisect_right(starts, pos)


def context(src, starts, pos):
    line = line_of(starts, pos)
    text = src[starts[line - 1]:].split("\n", 1)[0].strip()
    return line, text[:110]


def l3a_edits(rel, src, rows):
    code = src if rel.endswith(".md") else strip_strings(src)
    starts = line_starts(src)
    names = sorted((old for old, _ in rows), key=len, reverse=True)
    pattern = re.compile(r"(?<![A-Za-z0-9_])(?:" + "|".join(re.escape(n) for n in names) + r")(?![A-Za-z0-9_])")
    new_by_old = dict(rows)
    edits = []
    for m in pattern.finditer(code):
        old = m.group(0)
        ln, text = context(src, starts, m.start())
        if text.lstrip().startswith("---@enum"):
            continue
        edits.append({
            "file": rel, "start": m.start(), "end": m.end(),
            "old": old, "new": new_by_old[old], "kind": "token",
            "line": ln, "text": text,
        })
    return edits


def why_skip_l3b(name, recv, rel):
    if name == "New":
        base = recv.split(".")[-1]
        if recv in OFFICIAL_NEW or base in OFFICIAL_NEW or recv.startswith("_G."):
            return "official ctor"
        return None
    if name == "Length" and rel == VENDOR:
        return "Vector3:Length 替身"
    if name == "Pause" and recv == "api":
        return "modifier 包 API"
    if name == "Spawn" and recv not in SPAWN_ALLOW:
        return "Task:Spawn 官方"
    if name == "Move" and rel != "client/press_gesture.lua":
        return "BaseController:Move 替身"
    if name == "GetState" and rel == VENDOR:
        return "BaseController:GetState 替身"
    if name == "Attach" and rel not in ATTACH_ALLOW_FILES:
        return "官方/接口 Attach"
    if name == "Destroy" and rel.startswith("tests/") and recv in {"bound", "data", "PlayerData", "pd"}:
        return None
    if name == "Destroy" and (rel, recv) not in DESTROY_ALLOW:
        return "Unit:Destroy 官方/替身"
    return None


def bare_key_skip(name, rel, src, start):
    """测试替身裸表键的上下文口径：官方 Task / MgrUtil 等替身保持原样。"""
    if name == "Attach":
        return rel not in ATTACH_ALLOW_FILES
    line_start = src.rfind("\n", 0, start) + 1
    line = src[line_start:start]
    if name == "Start" and ("MgrUtil" in line or "noop_module" in line):
        return True
    window = src[max(0, start - 500):start]
    if name == "Spawn":
        return re.search(r"\bTask\b|\btask\b", window) is not None
    if name == "Start":
        return re.search(r"zone_markers|FishAbility|fish_ability|mgr\.Ai|\.Ai\b", window) is None
    if name == "GetState":
        return "Survival" in window
    return False


def receiver_before(code, sep_pos):
    j = sep_pos - 1
    while j >= 0 and code[j] in " \t":
        j -= 1
    if j < 0:
        return ""
    if code[j] in ")]":
        return code[j]
    k = j
    while k >= 0 and (code[k].isalnum() or code[k] in "_."):
        k -= 1
    return code[k + 1:j + 1]


def l3b_edits(rel, src, rows, skipped):
    new_by_old = dict(rows)
    code = strip_code(src)
    ccode = strip_comments(src) if any(r[0] == rel for r in EXTRA) else code
    starts = line_starts(src)
    edits = []
    for old, new in rows:
        if old not in code:
            continue
        call = re.compile(r"(?<=[\w\]\)\}\'\"])[ \t]*([.:])" + re.escape(old) + r"(?![A-Za-z0-9_])(?=[ \t]*\()")
        assign = re.compile(r"(?<=[\w\]\)\}\'\"])[ \t]*([.:])" + re.escape(old) + r"(?![A-Za-z0-9_])[ \t]*=[ \t]*function\b")
        for rx, kind in ((call, "call"), (assign, "assign")):
            for m in rx.finditer(code):
                sep = m.group(1)
                sep_pos = m.start(1)
                recv = receiver_before(code, sep_pos)
                reason = why_skip_l3b(old, recv, rel)
                if reason:
                    skipped.append({"file": rel, "old": old, "receiver": recv, "why": reason, "kind": kind})
                    continue
                ln, text = context(src, starts, m.start())
                edits.append({
                    "file": rel, "start": sep_pos, "end": sep_pos + 1 + len(old),
                    "old": old, "new": sep + new, "kind": kind,
                    "line": ln, "text": text, "receiver": sep + recv,
                })
        if rel.startswith("tests/") and old in BARE_TEST_NAMES:
            bare = re.compile(r"(?<![A-Za-z0-9_.:])" + re.escape(old) + r"(?![A-Za-z0-9_])[ \t]*=[ \t]*function\b")
            for m in bare.finditer(code):
                if bare_key_skip(old, rel, src, m.start()):
                    continue
                ln, text = context(src, starts, m.start())
                edits.append({
                    "file": rel, "start": m.start(), "end": m.end() - (len(m.group(0)) - len(old)),
                    "old": old, "new": new, "kind": "bare",
                    "line": ln, "text": text,
                })
    for relx, rx, grp, why in EXTRA:
        if rel != relx:
            continue
        for m in rx.finditer(ccode):
            if grp:
                s, e = m.start(grp), m.end(grp)
                old = m.group(grp)
                repl = new_by_old.get(old, old)
            else:
                s, e = m.start(), m.end()
                old = m.group(0)
                repl = EXTRA_REPL[rel]
            ln, text = context(src, starts, s)
            edits.append({
                "file": rel, "start": s, "end": e, "old": old, "new": repl,
                "kind": "extra", "line": ln, "text": text, "why": why,
            })
    for relx, rx, repl in RAW_EXTRA:
        if rel != relx:
            continue
        for m in rx.finditer(src):
            ln, text = context(src, starts, m.start())
            edits.append({
                "file": rel, "start": m.start(), "end": m.end(), "old": m.group(0),
                "new": repl, "kind": "raw", "line": ln, "text": text, "why": "历史注释同步",
            })
    return edits


def apply_edits(src, edits):
    out = src
    for e in sorted(edits, key=lambda x: -x["start"]):
        if out[e["start"]:e["end"]] != src[e["start"]:e["end"]]:
            fail(f"编辑区间重叠：{e['file']}:{e['line']} {e['old']}")
        out = out[:e["start"]] + e["new"] + out[e["end"]:]
    return out


def collect_layer(root, files, layer, rows):
    edits_by_file = collections.defaultdict(list)
    skipped = []
    for rel, path in files:
        bom, src = read_file(path)
        if layer == "l3a":
            edits = l3a_edits(rel, src, rows)
        else:
            edits = l3b_edits(rel, src, rows, skipped)
        if edits:
            edits_by_file[rel].extend(edits)
    return edits_by_file, skipped


def run(args):
    root = os.path.abspath(args.root)
    if not os.path.isdir(root):
        fail(f"--root 不是目录：{root}")
    maps = load_maps(args.layer)
    all_edits = collections.defaultdict(list)
    skipped = []
    for layer, rows in maps.items():
        files = collect_files(root, include_docs=(layer == "l3a"))
        edits_by_file, layer_skipped = collect_layer(root, files, layer, rows)
        skipped.extend(layer_skipped)
        for rel, edits in edits_by_file.items():
            all_edits[(layer, rel)].extend(edits)
    summary = {layer: {"files": set(), "edits": 0, "names": collections.Counter()} for layer in maps}
    for (layer, rel), edits in all_edits.items():
        item = summary.setdefault(layer, {"files": set(), "edits": 0, "names": collections.Counter()})
        item["files"].add(rel)
        item["edits"] += len(edits)
        for e in edits:
            item["names"][e["old"]] += 1
    if args.json:
        payload = {
            "root": root,
            "layers": {
                layer: {
                    "files": len(item["files"]),
                    "edits": item["edits"],
                    "names": dict(sorted(item["names"].items())),
                }
                for layer, item in sorted(summary.items())
            },
            "edits": [
                {k: e[k] for k in ("file", "line", "old", "new", "kind")}
                for (layer, rel), edits in sorted(all_edits.items())
                for e in sorted(edits, key=lambda x: (x["line"], x["start"]))
            ],
            "skipped": skipped,
        }
        if args.recon:
            print(json.dumps(payload, ensure_ascii=False, indent=2))
            return 0
    if args.recon:
        for layer in sorted(summary):
            item = summary[layer]
            print(f"layer {layer}: files={len(item['files'])} edits={item['edits']} names={len(item['names'])}")
        if not args.summary:
            for (layer, rel), edits in sorted(all_edits.items()):
                for e in sorted(edits, key=lambda x: (x["line"], x["start"])):
                    print(f"{rel}:{e['line']} {e['old']} -> {e['new']} [{e['kind']}]")
        if args.verbose and skipped:
            print("\n--- skipped ---")
            for s in skipped:
                print(f"{s['file']} {s['old']} recv={s['receiver']} [{s['kind']}] {s['why']}")
        return 0
    # --apply：按层、按文件落盘。l3a 先于 l3b；每层都重新扫描，避免上一层改长度后偏移错位。
    applied = []
    for layer, rows in maps.items():
        edits_by_file, _ = collect_layer(root, collect_files(root, include_docs=(layer == "l3a")), layer, rows)
        prepared = []
        for rel in sorted(edits_by_file):
            path = os.path.join(root, rel)
            bom, src = read_file(path)
            prepared.append((path, bom, apply_edits(src, edits_by_file[rel])))
        for path, bom, out in prepared:
            write_file(path, out, bom)
        applied.append((layer, len(edits_by_file), sum(len(v) for v in edits_by_file.values())))
    for layer, files_count, edits_count in applied:
        print(f"APPLIED layer={layer} files={files_count} edits={edits_count}")
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description="#337 命名改名 recon/apply")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--recon", action="store_true", help="只列将要改的位置")
    mode.add_argument("--apply", action="store_true", help="落盘改名")
    parser.add_argument("--layer", choices=("l3a", "l3b", "all"), default="all")
    parser.add_argument("--root", default=".", help="目标仓库根（默认当前目录）")
    parser.add_argument("--json", action="store_true", help="recon 输出 JSON")
    parser.add_argument("--summary", action="store_true", help="recon 只打印汇总")
    parser.add_argument("--verbose", action="store_true", help="recon 附带跳过明细")
    args = parser.parse_args(argv)
    if args.json and not args.recon:
        parser.error("--json 只用于 --recon")
    return run(args)


if __name__ == "__main__":
    raise SystemExit(main())
