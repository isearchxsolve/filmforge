#!/usr/bin/env bash
# =============================================================================
# setup.sh — one-shot FilmForge backend setup
# Deploys the LTX-2.3 + Wan 2.2 ComfyUI backends on Modal so filmforge.py can
# drive them. Run once; re-run only to update.
#
# Prereqs you provide:
#   - a FRESH Hugging Face token (regenerate the one you pasted earlier!)
#   - modal_backend.py in this folder (the headless generate() backend)
# =============================================================================
set -euo pipefail

echo "==> Installing client deps"
pip install --quiet --upgrade modal comfy-cli requests

echo "==> Modal auth (opens browser if not logged in)"
modal setup || true

if [ -z "${HF_TOKEN:-}" ]; then
  read -rsp "Paste your FRESH Hugging Face token (hf_...): " HF_TOKEN
  echo
fi

echo "==> Creating/So updating Modal secret 'huggingface'"
modal secret create huggingface HF_TOKEN="$HF_TOKEN" 2>/dev/null || \
  modal secret create huggingface HF_TOKEN="$HF_TOKEN" --force

echo "==> Pre-downloading model weights into Modal Volumes (one-time, ~minutes)"
FF_MODEL=ltx23 modal run modal_backend.py::download_models
FF_MODEL=wan22 modal run modal_backend.py::download_models

echo "==> Deploying warm ComfyUI backends"
FF_MODEL=ltx23 modal deploy modal_backend.py
FF_MODEL=wan22 FF_GPU=A100-40GB modal deploy modal_backend.py

echo "==> (Optional) Beam failover: set these before running filmforge.py"
echo "    export BEAM_ENDPOINT=https://<your-beam-app>.app.beam.cloud/generate"
echo "    export BEAM_TOKEN=<your-beam-token>"

echo ""
echo "Setup complete. Test the pipeline offline first:"
echo "    python3 filmforge.py --shots shots.json --dry-run --transition crossfade"
echo "Then go live:"
echo "    python3 filmforge.py --shots shots.json --out film.mp4 --transition crossfade"
