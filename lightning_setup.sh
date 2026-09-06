#!/usr/bin/env bash
# =====================================================================
# FilmForge - one-time ComfyUI setup on a Lightning AI Studio
# Run this ONCE inside a Studio terminal. It persists on the Studio disk.
#
#   bash lightning_setup.sh ltx23     # or: bash lightning_setup.sh wan22
# =====================================================================
set -e
MODEL="${1:-ltx23}"
COMFY_DIR="${COMFY_DIR:-$HOME/ComfyUI}"

# ---------------------------------------------------------------------
# Locate a Python interpreter. Over a NON-interactive SSH session the
# Studio's conda env is often NOT on PATH, and a bare `pip` may not exist
# at all. So find python explicitly, add it to PATH, and remember it in
# ~/.filmforge_env so the later download + launch steps reuse the exact
# same interpreter. Always call pip as `"$PY" -m pip`, never bare `pip`.
# ---------------------------------------------------------------------
PY="$(command -v python || command -v python3 || true)"
if [ -z "$PY" ]; then
  for f in /home/zeus/miniconda3/envs/*/bin/python /home/zeus/miniconda3/bin/python \
           "$HOME"/miniconda3/envs/*/bin/python "$HOME"/miniconda3/bin/python \
           /opt/conda/envs/*/bin/python /opt/conda/bin/python \
           /usr/local/bin/python3 /usr/bin/python3; do
    if [ -x "$f" ]; then PY="$f"; break; fi
  done
fi
if [ -z "$PY" ]; then
  echo "[X] No Python interpreter found on the Studio. Aborting."
  exit 1
fi
export PATH="$(dirname "$PY"):$PATH"
printf 'export PATH="%s:$PATH"\n' "$(dirname "$PY")" > "$HOME/.filmforge_env"
echo "Using Python: $PY"

echo "== [1/4] Installing ComfyUI into $COMFY_DIR =="
# Reproducibility lockfile: records the exact commit of ComfyUI core + every
# node pack that actually gets installed, so you can freeze a known-good stack.
LOCK="$COMFY_DIR/ff_pack_lock.txt"
LOCKTMP="$HOME/.ff_lock.tmp"
: > "$LOCKTMP"
COMFY_PIN="${FF_PIN_COMFYUI:-}"   # set FF_PIN_COMFYUI=<commit> to freeze core
if [ ! -d "$COMFY_DIR" ]; then
  git clone https://github.com/comfyanonymous/ComfyUI "$COMFY_DIR"
fi
cd "$COMFY_DIR"
if [ -n "$COMFY_PIN" ]; then
  [ "$(git rev-parse --is-shallow-repository 2>/dev/null)" = "true" ] && git fetch --unshallow || true
  git fetch --tags --force origin || true
  if git checkout -q "$COMFY_PIN" 2>/dev/null; then echo "   [pin] ComfyUI core -> $COMFY_PIN"
  else echo "   [!] ComfyUI core: pin '$COMFY_PIN' not found - staying on $(git rev-parse --short HEAD)"; fi
else
  echo "   [!] ComfyUI core: UNPINNED (tracking upstream). Freeze from $LOCK once stable."
fi
printf 'ComfyUI(core) %s\n' "$(git rev-parse HEAD 2>/dev/null || echo UNKNOWN)" >> "$LOCKTMP"
"$PY" -m pip install -r requirements.txt

echo "== [2/4] Installing the HuggingFace downloader =="
"$PY" -m pip install "huggingface_hub[hf_transfer]"

echo "== [3/4] Installing custom nodes for $MODEL =="
mkdir -p "$COMFY_DIR/custom_nodes"
cd "$COMFY_DIR/custom_nodes"

# ---------------------------------------------------------------------
# REPRODUCIBILITY: pin every node pack to an EXACT commit.
# Unpinned `git clone --depth 1` was the ROOT CAUSE of the LTX loader drift -
# an upstream merge silently changed a node's inputs and broke the render.
#   * If a pin is set (PINS below, or env FF_PIN_<NAME>), check out that exact
#     commit - unshallowing first so old commits are reachable.
#   * Whatever commit ends up installed is recorded in ff_pack_lock.txt; copy
#     those hashes into PINS to freeze a known-good stack forever.
# Empty pin = track upstream (NOT reproducible) -> loud warning.
# ---------------------------------------------------------------------
declare -A PINS=(
  # Fill AFTER go_burst.sh + preflight.py pass once (values from ff_pack_lock.txt):
  # ["ComfyUI-LTXVideo"]="<gguf-compatible-commit>"
  # ["ComfyUI-VideoHelperSuite"]="<commit>"
  # ["ComfyUI-GGUF"]="<commit>"
  # ["ComfyUI-KJNodes"]="<commit>"
  # ["ComfyUI-MultiGPU"]="<commit>"
  # ["ComfyUI-Manager"]="<commit>"
)
pin_for() {   # env FF_PIN_<UPPER,_> overrides PINS[name]
  local name="$1" envk
  envk="FF_PIN_$(printf '%s' "$name" | tr 'a-z-' 'A-Z_')"
  if [ -n "${!envk:-}" ]; then printf '%s' "${!envk}"; else printf '%s' "${PINS[$name]:-}"; fi
}
clone() {
  local url name pin
  url="$1"; name="$(basename "$url")"
  pin="$(pin_for "$name")"
  if [ ! -d "$name" ]; then
    if [ -n "$pin" ]; then git clone "$url" "$name"; else git clone --depth 1 "$url" "$name"; fi
  fi
  ( set +e; cd "$name" || exit 0
    if [ -n "$pin" ]; then
      [ "$(git rev-parse --is-shallow-repository 2>/dev/null)" = "true" ] && git fetch --unshallow
      git fetch --tags --force origin
      if git checkout -q "$pin" 2>/dev/null; then echo "   [pin] $name -> $pin"
      else echo "   [!] $name: pin '$pin' not found - staying on $(git rev-parse --short HEAD)"; fi
    else
      echo "   [!] $name: UNPINNED (tracking upstream - not reproducible)."
    fi
    printf '%s %s\n' "$name" "$(git rev-parse HEAD 2>/dev/null || echo UNKNOWN)" >> "$LOCKTMP" )
}
clone https://github.com/ltdrdata/ComfyUI-Manager
clone https://github.com/city96/ComfyUI-GGUF
clone https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite
clone https://github.com/kijai/ComfyUI-KJNodes
if [ "$MODEL" = "ltx23" ]; then
  clone https://github.com/pollockjj/ComfyUI-MultiGPU
  clone https://github.com/Lightricks/ComfyUI-LTXVideo
fi

echo "== [4/4] Installing custom-node requirements =="
for d in */ ; do
  [ -f "$d/requirements.txt" ] && ("$PY" -m pip install -r "$d/requirements.txt" || true)
done

# Finalize the reproducibility lockfile.
if [ -f "$LOCKTMP" ]; then
  { echo "# FilmForge pack lock - $(date -u +%FT%TZ 2>/dev/null)"
    echo "# Copy these commits into PINS[] / FF_PIN_* to freeze this exact stack."
    sort "$LOCKTMP"; } > "$LOCK"
  rm -f "$LOCKTMP"
  echo "== pack lock written -> $LOCK =="
  sed 's/^/   /' "$LOCK"
fi

echo "== [5/5] Aligning torchaudio to torch (prevents ABI 'undefined symbol' crash) =="
# ComfyUI's requirements.txt may upgrade torch, orphaning the prebuilt torchaudio.
# Realign torchaudio to the torch that is now installed so ComfyUI can import it.
if ! "$PY" -c "import torchaudio" >/dev/null 2>&1; then
  TVER="$("$PY" -c 'import torch;print(torch.__version__.split("+")[0])' 2>/dev/null)"
  TCU="$("$PY" -c 'import torch;print((torch.version.cuda or "").replace(".",""))' 2>/dev/null)"
  if [ -n "$TVER" ]; then
    if [ -n "$TCU" ]; then IDX="https://download.pytorch.org/whl/cu${TCU}"; else IDX="https://download.pytorch.org/whl/cpu"; fi
    echo "   torch=$TVER cuda=${TCU:-none} -> torchaudio==$TVER from $IDX"
    "$PY" -m pip install --force-reinstall --no-deps "torchaudio==$TVER" --index-url "$IDX" || \
    "$PY" -m pip install --force-reinstall --no-deps torchaudio --index-url "$IDX" || true
  fi
fi
"$PY" -c "import torchaudio; print('   torchaudio OK')" || echo "[!] torchaudio still not importable - go_burst.sh will retry at gate 2"

echo ""
echo "== DONE. ComfyUI + nodes installed for $MODEL (python: $PY) =="
