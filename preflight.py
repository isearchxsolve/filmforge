#!/usr/bin/env python3
"""
preflight.py - the LIVE check you MUST pass before your first PAID render.

Confirms, against a RUNNING ComfyUI, the things an offline build cannot:

  1. NODES      - every node class our graphs use exists on the server.
  2. SIGNATURES - every node's REQUIRED inputs are supplied AND every literal
                  choice value (model file, format, ...) is actually offered by
                  THIS install. This is the check that catches version drift a
                  bare "does the class exist" test misses - i.e. the silent
                  HTTP 400 that cost us a night.
  3. MODELS     - every model file our graphs reference is present on disk.
  4. SMOKE      - (optional) a tiny real render completes end to end.

It derives everything by BUILDING every graph variant with make_workflows.build,
so the check always matches what render_film will actually send - no
hand-maintained list to drift.

USAGE
  python3 preflight.py --offline
  python3 preflight.py --comfy http://127.0.0.1:8188
  python3 preflight.py --comfy http://127.0.0.1:8188 --smoke

EXIT CODE is non-zero if anything is missing/mismatched (CI-friendly).
"""
import argparse, json, os, pathlib, re, sys, time, uuid, urllib.request

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import make_workflows as mw

MODEL_RE = re.compile(r"\.(safetensors|gguf|pth|ckpt|pt|onnx|bin)$", re.I)


def _all_variants(model=None):
    """Build every graph render_film could send. If model is given, only that
    model's variants (so a signature check stays focused on what you render)."""
    models = (model,) if model else ("ltx23", "wan22")
    graphs = []
    for m in models:
        for upscale in (False, True):
            for char in (None, "__probe__.safetensors"):
                graphs.append(mw.build(m, 768, 448, 3,
                                       char_lora=char, char_strength=0.85,
                                       upscale=upscale))
    return graphs


def requirements():
    mw.apply_manifest()                       # reflect real on-disk filenames
    nodes, models = set(), set()
    for g in _all_variants():
        for node in g.values():
            nodes.add(node["class_type"])
            for v in node.get("inputs", {}).values():
                if isinstance(v, str) and MODEL_RE.search(v) and "probe" not in v:
                    models.add(v)
    return sorted(nodes), sorted(models)


def _get(base, path):
    with urllib.request.urlopen(base.rstrip("/") + path, timeout=30) as r:
        return json.loads(r.read())


def _post(base, path, data):
    req = urllib.request.Request(
        base.rstrip("/") + path, data=json.dumps(data).encode(),
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read())


def check_models_on_disk(models):
    comfy = pathlib.Path(os.environ.get("COMFY_DIR",
                                        os.path.expanduser("~/ComfyUI")))
    root = comfy / "models"
    present, missing = [], []
    have = set()
    if root.exists():
        for p in root.rglob("*"):
            if p.is_file():
                have.add(p.name)
    for m in models:
        (present if pathlib.Path(m).name in have else missing).append(m)
    return root, present, missing


def _is_link(v):
    """A ComfyUI wired input is [node_id, output_index] - not a literal value."""
    return (isinstance(v, list) and len(v) == 2
            and isinstance(v[0], (str, int)) and isinstance(v[1], int))


def validate_signatures(graphs, info):
    """Diff every built graph against the LIVE node schemas from /object_info.

    Mirrors ComfyUI's own prompt validation, so a clean result here means
    /prompt will not 400 on 'required input missing' or 'value not in list' -
    the exact drift that bit us. Returns a list of human-readable problems.
    """
    problems, seen = [], set()
    for g in graphs:
        for node in g.values():
            cls = node["class_type"]
            schema = info.get(cls)
            if not schema:
                continue                      # missing-class reported elsewhere
            spec = schema.get("input", {}) or {}
            required = spec.get("required", {}) or {}
            allspec = {}
            allspec.update(required)
            allspec.update(spec.get("optional", {}) or {})
            given = node.get("inputs", {}) or {}

            # 1) every REQUIRED input must be supplied
            for name in required:
                if name not in given:
                    key = (cls, "miss", name)
                    if key not in seen:
                        seen.add(key)
                        problems.append(
                            f"{cls}: required input missing -> '{name}'")

            # 2) every literal fed to a CHOICE input must be offered by THIS install
            for name, val in given.items():
                if _is_link(val):
                    continue                  # wired from another node
                meta = allspec.get(name)
                if not meta:
                    continue                  # unknown extra - ComfyUI ignores
                t = meta[0]
                if isinstance(t, list) and val not in t:
                    key = (cls, "choice", name, str(val))
                    if key not in seen:
                        seen.add(key)
                        if not t:
                            hint = ("  <-- list is EMPTY: that file is not on "
                                    "disk or is in the WRONG models/ subfolder")
                            problems.append(
                                f"{cls}.{name}: '{val}' rejected.{hint}")
                        else:
                            sample = t[:6]
                            more = "" if len(t) <= 6 else f" (+{len(t)-6} more)"
                            problems.append(
                                f"{cls}.{name}: '{val}' not offered. "
                                f"Valid here: {sample}{more}")
    return problems


def smoke(base):
    print("\n[SMOKE] queuing a tiny 1s LTX render ...")
    g = mw.build("ltx23", 768, 448, 1, char_lora=None, upscale=False)
    for n in g.values():
        if n["class_type"] == "VHS_VideoCombine":
            n["inputs"]["filename_prefix"] = "preflight_smoke"
    pid = _post(base, "/prompt", {"prompt": g, "client_id": str(uuid.uuid4())})["prompt_id"]
    for _ in range(150):
        time.sleep(2)
        hist = _get(base, f"/history/{pid}")
        if pid in hist:
            st = hist[pid].get("status", {})
            if st.get("status_str") == "error":
                return False, "render errored (see ComfyUI log)"
            for out in hist[pid].get("outputs", {}).values():
                for k in ("gifs", "videos", "images"):
                    for it in out.get(k, []) or []:
                        if it.get("filename", "").endswith(".mp4"):
                            return True, it["filename"]
            if st.get("completed"):
                return False, "completed but no mp4"
    return False, "timed out"


def main():
    ap = argparse.ArgumentParser(description="FilmForge live pre-flight check")
    ap.add_argument("--comfy", default=None)
    ap.add_argument("--offline", action="store_true")
    ap.add_argument("--smoke", action="store_true")
    args = ap.parse_args()

    nodes, models = requirements()
    print(f"Required NODE classes ({len(nodes)}):")
    for n in nodes:
        print(f"  - {n}")
    print(f"\nReferenced MODEL files ({len(models)}):")
    for m in models:
        print(f"  - {m}")

    if args.offline or not args.comfy:
        print("\n[offline] listed requirements only. Re-run with --comfy "
              "http://127.0.0.1:8188 to check against a live server.")
        return

    ok = True
    print(f"\n[1/4 NODES] checking {args.comfy} ...")
    try:
        info = _get(args.comfy, "/object_info")
    except Exception as e:
        sys.exit(f"  cannot reach ComfyUI: {e}")
    missing_nodes = [n for n in nodes if n not in info]
    if missing_nodes:
        ok = False
        print("  MISSING node classes (install the custom-node pack):")
        for n in missing_nodes:
            print(f"    x {n}")
    else:
        print("  all node classes present.")

    # SIGNATURES - scoped to the model you are actually rendering (MODEL env).
    active = os.environ.get("MODEL", "ltx23")
    print(f"\n[2/4 SIGNATURES] validating '{active}' node inputs against this install ...")
    problems = validate_signatures(_all_variants(active), info)
    if problems:
        ok = False
        print("  SIGNATURE MISMATCH (THIS is what causes the silent HTTP 400):")
        for p in problems:
            print(f"    x {p}")
    else:
        print("  all node inputs satisfied - no drift.")

    print("\n[3/4 MODELS] checking files on disk ...")
    root, present, missing_models = check_models_on_disk(models)
    print(f"  models root: {root}")
    for m in present:
        print(f"    ok {m}")
    if missing_models:
        ok = False
        for m in missing_models:
            print(f"    x MISSING {m}")

    if args.smoke:
        if not ok:
            print("\n[4/4 SMOKE] skipped - fix the items above first. A smoke "
                  "render would only 400 and waste GPU time.")
        else:
            good, detail = smoke(args.comfy)
            print(f"[4/4 SMOKE] {'OK ' + detail if good else 'FAILED: ' + detail}")
            ok = ok and good
    else:
        print("\n[4/4 SMOKE] skipped (add --smoke to run a real 1s render)")

    print("\n" + ("PREFLIGHT PASSED - safe to render." if ok else
                  "PREFLIGHT FAILED - fix the items above BEFORE paying for GPU."))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
