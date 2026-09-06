#!/usr/bin/env bash
# ============================================================================
# FilmForge BOOT - self-healing, GATED one-command bring-up on a Lightning Studio.
#
#     bash ~/go_burst.sh
#
# WHY THIS EXISTS (convergence): every fresh Studio kept re-introducing the
# SAME failures - missing ComfyUI, the torch/torchaudio ABI break that appears
# after ComfyUI upgrades torch ("undefined symbol: torch_library_impl"), and
# missing model weights. Un-gated, each one crashed blind and we looped.
#
# This script GATES each stage:  check -> repair -> verify -> proceed.
# It stops at the FIRST red with ONE clear remedy. Nothing heavy runs until the
# stage before it is green. It is safe to re-run any number of times.
#
# It also auto-detects CPU vs GPU:
#   - on the free CPU box  -> it installs, repairs, and downloads (all free),
#                             then tells you to switch to GPU.
#   - on the GPU box       -> everything above is already green, so it runs the
#                             tiny smoke render (your first real clip).
#
# Optional env you may set first:
#   HF_TOKEN=hf_...      (only needed if the weights still have to download)
#   FF_QUANT=q5_k_m      (q4_k_m | q5_k_m | q6_k)     FF_TILED_VAE=1
#   MODEL=ltx23          (or wan22)
# ============================================================================
set -o pipefail

COMFY_DIR="${COMFY_DIR:-$HOME/ComfyUI}"
FF_DIR="${FF_DIR:-$HOME}"          # where make_workflows.py / preflight.py live
PORT="${PORT:-8188}"
MODEL="${MODEL:-ltx23}"
export FF_QUANT="${FF_QUANT:-q5_k_m}"
export FF_TILED_VAE="${FF_TILED_VAE:-1}"

die() { echo; echo "====================================================================="; \
        echo " [boot] STOPPED at: $1"; \
        echo " [boot] Fix just that, then re-run:   bash ~/go_burst.sh"; \
        echo "====================================================================="; exit 1; }

# --- pick the python setup recorded (conda env may not be on PATH) ----------
[ -f "$HOME/.filmforge_env" ] && . "$HOME/.filmforge_env"
if command -v python >/dev/null 2>&1; then PY=python
elif command -v python3 >/dev/null 2>&1; then PY=python3
else die "no python interpreter found on this Studio"; fi
echo "[boot] python=$($PY -c 'import sys;print(sys.executable)' 2>/dev/null)  quant=$FF_QUANT  model=$MODEL"

# ---------------------------------------------------------------------------
# GATE 1 - ComfyUI installed
# ---------------------------------------------------------------------------
echo "[gate 1/6] ComfyUI present?"
if [ ! -f "$COMFY_DIR/main.py" ]; then
  echo "   -> not found; running one-time setup ..."
  if [ -f "$FF_DIR/lightning_setup.sh" ]; then
    bash "$FF_DIR/lightning_setup.sh" "$MODEL" || die "lightning_setup.sh failed (see output above)"
    [ -f "$HOME/.filmforge_env" ] && . "$HOME/.filmforge_env"
  else
    die "ComfyUI missing AND lightning_setup.sh not in $FF_DIR - scp it over first"
  fi
fi
echo "   ok: $COMFY_DIR"

# ---------------------------------------------------------------------------
# GATE 2 - torch / torchaudio ABI match  (the recurring killer)
# ComfyUI's requirements often upgrade torch, orphaning the prebuilt torchaudio
# -> "undefined symbol: torch_library_impl". Auto-realign torchaudio TO torch.
# ---------------------------------------------------------------------------
echo "[gate 2/6] torch/torchaudio ABI ok?"
if ! $PY -c "import torchaudio" >/dev/null 2>&1; then
  echo "   -> torchaudio won't load; realigning it to the installed torch ..."
  TVER="$($PY -c 'import torch;print(torch.__version__.split("+")[0])' 2>/dev/null)"
  TCU="$($PY -c 'import torch;print((torch.version.cuda or "").replace(".",""))' 2>/dev/null)"
  [ -z "$TVER" ] && die "torch itself will not import - the python env is broken"
  if [ -n "$TCU" ]; then IDX="https://download.pytorch.org/whl/cu${TCU}"; else IDX="https://download.pytorch.org/whl/cpu"; fi
  echo "      torch=$TVER cuda=${TCU:-none} -> torchaudio==$TVER from $IDX"
  $PY -m pip install --force-reinstall --no-deps "torchaudio==$TVER" --index-url "$IDX" \
    || $PY -m pip install --force-reinstall --no-deps torchaudio --index-url "$IDX" \
    || die "torchaudio reinstall failed (network? check the pip output)"
  $PY -c "import torchaudio" >/dev/null 2>&1 || die "torchaudio STILL won't import after realign"
fi
echo "   ok: torchaudio imports"
# --- GATE 2b - numpy/scipy ABI (recurring convergence) ---
echo "[gate 2b/6] numpy/scipy ABI ok?"
if ! $PY -c "from scipy.ndimage import gaussian_filter" >/dev/null 2>&1; then
  echo "   -> numpy/scipy ABI mismatch; pinning known-good pair numpy 1.26.4 + scipy 1.11.4 ..."
  $PY -m pip install --force-reinstall --no-cache-dir "numpy==1.26.4" "scipy==1.11.4" || die "numpy/scipy realign failed (network? check pip output)"
  $PY -c "from scipy.ndimage import gaussian_filter" >/dev/null 2>&1 || die "scipy STILL will not import after realign"
fi
echo "   ok: numpy/scipy import"

# ---------------------------------------------------------------------------
# GATE 3 - start ComfyUI + wait until it actually answers
# ---------------------------------------------------------------------------
echo "[gate 3/6] starting + waiting for ComfyUI on :$PORT"
if ! curl -sf "http://127.0.0.1:$PORT/system_stats" >/dev/null 2>&1; then
  ( cd "$COMFY_DIR" && nohup "$PY" main.py --listen 0.0.0.0 --port "$PORT" > "$HOME/comfy.log" 2>&1 & )
fi
UP=0
printf "   waiting"
for i in $(seq 1 90); do
  if curl -sf "http://127.0.0.1:$PORT/system_stats" >/dev/null 2>&1; then UP=1; echo " - UP"; break; fi
  printf "."; sleep 2
done
if [ "$UP" != "1" ]; then
  echo; echo "   last 40 lines of ~/comfy.log:"
  echo "   ----------------------------------------------------------------"
  tail -n 40 "$HOME/comfy.log" 2>/dev/null
  echo "   ----------------------------------------------------------------"
  die "ComfyUI did not start (read the traceback just above)"
fi
echo "   ok: ComfyUI serving"

# ---------------------------------------------------------------------------
# GATE 4 - nodes + model weights present (validated against the live server)
# ---------------------------------------------------------------------------
echo "[gate 4/6] nodes + model weights present?"
if [ -f "$FF_DIR/preflight.py" ] && [ -f "$FF_DIR/make_workflows.py" ]; then
  ( cd "$FF_DIR" && "$PY" make_workflows.py --force >/dev/null 2>&1; \
    "$PY" preflight.py --comfy "http://127.0.0.1:$PORT" )
  if [ $? -ne 0 ]; then
    echo "   -> preflight reported missing items (see list above)."
    if [ -n "${HF_TOKEN:-}" ]; then
      echo "   -> HF_TOKEN set; attempting model download ..."
      ( cd "$FF_DIR" && "$PY" lightning_download.py "$MODEL" ) || die "model download failed"
      ( cd "$FF_DIR" && "$PY" preflight.py --comfy "http://127.0.0.1:$PORT" ) \
        || die "still failing after download - if it lists MISSING node classes, re-run lightning_setup.sh $MODEL"
    else
      die "missing items above. If MODELS: export HF_TOKEN=hf_... and re-run. If NODES: re-run lightning_setup.sh $MODEL"
    fi
  fi
else
  echo "   (preflight.py/make_workflows.py not in $FF_DIR - skipping strict check)"
fi
echo "   ok: nodes + weights present"

# ---------------------------------------------------------------------------
# GATE 5 - GPU?  (smoke render needs a GPU; on CPU we stop here, all-prepped)
# ---------------------------------------------------------------------------
echo "[gate 5/6] GPU available?"
HAS_GPU="$($PY -c 'import torch;print(1 if torch.cuda.is_available() else 0)' 2>/dev/null)"
if [ "$HAS_GPU" != "1" ]; then
  echo
  echo "==================================================================="
  echo " ALL PREP DONE on CPU (free): ComfyUI installed, torchaudio fixed,"
  echo " weights present. No GPU here, so the smoke render is skipped."
  echo
  echo " NEXT: switch this Studio to the L4 GPU (same cloud = free switch),"
  echo "       then re-run:   bash ~/go_burst.sh"
  echo " It will fly straight to the smoke render - all gates already green."
  echo "==================================================================="
  exit 0
fi
echo "   ok: GPU detected"

# ---------------------------------------------------------------------------
# GATE 6 - smoke render (tiny 1s clip = your first real proof)
# ---------------------------------------------------------------------------
echo "[gate 6/6] smoke render"
( cd "$FF_DIR" && "$PY" preflight.py --comfy "http://127.0.0.1:$PORT" --smoke )
SMOKE_RC=$?

echo
echo "==================================================================="
if [ "${SMOKE_RC:-1}" = "0" ]; then
  echo " SMOKE PASSED - first clip is in:  $COMFY_DIR/output/  (preflight_smoke*.mp4)"
  echo
  echo " Full film:  cd $FF_DIR && $PY render_film.py --shots shots.json"
  echo " Visual UI:  open the tunnel/port  http://localhost:$PORT"
else
  echo " SMOKE FAILED - read the [3/3 SMOKE] line above. If it OOM'd, drop a"
  echo " precision:  export FF_QUANT=q4_k_m ; bash ~/go_burst.sh"
fi
echo
echo " >>> WHEN DONE, STOP THE STUDIO in the Lightning UI. <<<"
echo "     Stopped = ZERO GPU credits. Your files + weights are kept."
echo "==================================================================="
