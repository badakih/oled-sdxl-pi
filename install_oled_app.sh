# ─────────────────────────────────────────────────────────────────────────────
#  OLED SSD1306 Web Controller + Stable Diffusion — one-shot installer
#
#  Reproducibly installs, on a fresh Raspberry Pi OS (Bookworm / Trixie):
#    • OS drivers: I2C stack (i2c-tools, python3-smbus), PIL, desktop
#    • I2C enabled in the firmware (correct dtparam for Pi 4 vs Pi 5)
#    • Python deps (pinned): luma.oled 3.15.0, luma.core 2.5.3,
#                            Flask 3.1.3, Pillow 10.4.0
#    • the app:  <user-home>/oled-web/  (app.py + templates/index.html)
#    • Stable Diffusion: OnnxStream `sd` binary + SDXL-Turbo 1.0 ONNX models
#      (live model-download progress bar, bytes on disk, tty-aware)
#      (<user-home>/onnxstream/, ~9.3 GB)
#    • a systemd service (auto-start) on port 5000
#
#  Usage:
#      sudo bash install_oled_app.sh [--user sysadmin] [--bus 1] [--reboot] [--skip-sd] [--skip-sdxl]
#        --reboot    reboot at the end (recommended on a fresh flash so the
#                    firmware I2C node exists when the service starts at boot)
#        --skip-sd   skip the Stable Diffusion build + model download
#        --skip-sdxl  skip the SDXL-Turbo model download
#
#  After install (or a reboot if I2C needed to come up): open http://<pi-ip>:5000
#
#  Reference hardware: Raspberry Pi 5 (BCM2712), SSD1306 128x64 I2C bus 1 @ 0x3C
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ── args ─────────────────────────────────────────────────────────────────────
USER_NAME="sysadmin"
BUS="1"
REBOOT=""
SKIP_SD=""
SKIP_SDXL=""
CONFIG_CHANGED=0
while [ $# -gt 0 ]; do
  case "$1" in
    --user)       USER_NAME="$2"; shift 2 ;;
    --bus)        BUS="$2";       shift 2 ;;
    --reboot)     REBOOT=1; shift ;;
    --skip-sd)    SKIP_SD=1; shift ;;
    --skip-sdxl)  SKIP_SDXL=1; shift ;;
    -h|--help)    grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ "$(id -u)" -eq 0 ] || { echo "Run as root (sudo)."; exit 1; }
command -v raspi-config >/dev/null || { echo "raspi-config not found — is this a Raspberry Pi?"; exit 1; }

USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6)"
[ -n "$USER_HOME" ] || { echo "No such user: $USER_NAME"; exit 1; }
APP_DIR="$USER_HOME/oled-web"
PYTHON_BIN="$(command -v python3)"

echo "==> Target user : $USER_NAME ($USER_HOME)"
echo "==> Python      : $PYTHON_BIN"
echo "==> I2C bus     : $BUS   (device node /dev/i2c-$BUS, address 0x3C)"
if [ -n "$SKIP_SD" ]; then
  _sd_desc='skipped (--skip-sd)'
else
  _sd_desc='OnnxStream + SDXL-Turbo'
fi
echo "==> SD backend  : $_sd_desc"
echo

# ── 1. OS packages ───────────────────────────────────────────────────────────
echo "==> [1/7] Installing OS packages (I2C, PIL, desktop, SD build toolchain) ..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
  i2c-tools \
  python3-smbus \
  python3-pil \
  python3-pip \
  lightdm \
  labwc \
  pcmanfm-pi \
  build-essential \
  git \
  cmake \
  git-lfs \
  curl \
  ca-certificates

# ── 2. Enable I2C in the firmware ───────────────────────────────────────────
echo "==> [2/7] Enabling I2C (firmware dtparam) ..."
# Deterministic I2C enable. We deliberately do NOT call `raspi-config nonint
# do_i2c` — on Bookworm/Trixie it can hang waiting on a TTY, and (worse) it can
# leave a stray `dtparam=i2c_arm=off` in config.txt that silently disables the
# firmware I2C mux the SSD1306 sits on. We sanitise config.txt directly instead.

DT_FILE=""
for d in /boot/firmware/config.txt /boot/config.txt; do
  [ -f "$d" ] && { DT_FILE="$d"; break; }
done

# Pi 5 (BCM2712) exposes the firmware I2C (bus 1, where the OLED lives) via
# dtparam i2c1; older Pis use i2c_arm.
DT_PARAM="i2c_arm"
if grep -qi "bcm2712" /proc/device-tree/compatible 2>/dev/null; then
  DT_PARAM="i2c1"
fi

if [ -n "$DT_FILE" ]; then
  if grep -qE "^[[:space:]]*dtparam=$DT_PARAM=on[[:space:]]*$" "$DT_FILE"; then
    echo "    $DT_FILE already has dtparam=$DT_PARAM=on — no change needed."
  else
    [ -f "${DT_FILE}.bak-oled" ] || cp "$DT_FILE" "${DT_FILE}.bak-oled"
    # Remove any pre-existing i2c_arm / i2c1 dtparams (on or off).
    sed -i -E "s/^[[:space:]]*dtparam=i2c_arm=[a-z]+/# (oled-installer) removed: dtparam=i2c_arm=<val>/" "$DT_FILE"
    sed -i -E "s/^[[:space:]]*dtparam=i2c1=[a-z]+/# (oled-installer) removed: dtparam=i2c1=<val>/" "$DT_FILE"
    echo "dtparam=$DT_PARAM=on" >> "$DT_FILE"
    CONFIG_CHANGED=1
    echo "    Sanitised $DT_FILE; set dtparam=$DT_PARAM=on  (backup at ${DT_FILE}.bak-oled)"
    echo "    (config.txt changed -> a reboot is required for /dev/i2c-$BUS to appear)"
  fi
else
  echo "    WARN: no /boot*/config.txt found (unusual) — cannot set dtparam."
fi
# Ensure the i2c kernel module is loaded now and at boot.
modprobe i2c_dev 2>/dev/null || true
grep -qx "i2c_dev" /etc/modules 2>/dev/null || echo "i2c_dev" >> /etc/modules

# The I2C node is owned root:i2c (mode 0660). The app user must be in the i2c
# group or the service (running as that user) cannot open /dev/i2c-$BUS.
if getent group i2c >/dev/null; then
  usermod -aG i2c "$USER_NAME"
  echo "    $USER_NAME added to group 'i2c'"
else
  groupadd i2c
  usermod -aG i2c "$USER_NAME"
  echo "    created group 'i2c' and added $USER_NAME"
fi

# ── 3. Python dependencies (pinned) ─────────────────────────────────────────
echo "==> [3/7] Installing Python dependencies (pinned) ..."
# Debian 12/13 mark the system python EXTERNALLY-MANAGED, so install into the
# target user's site (matches the reference build). Pillow 10.4.0 is required —
# the app uses Image.LANCZOS, which was removed in Pillow 12+.
if ! sudo -u "$USER_NAME" "$PYTHON_BIN" -m pip install --user --break-system-packages \
    "luma.oled==3.15.0" "luma.core==2.5.3" "Flask==3.1.3" "Pillow==10.4.0"; then
  echo "    WARN: user-level pip install failed; retrying system-wide ..."
  "$PYTHON_BIN" -m pip install --break-system-packages \
    "luma.oled==3.15.0" "luma.core==2.5.3" "Flask==3.1.3" "Pillow==10.4.0"
fi

# ── 4. Install the application (byte-faithful app.py + index.html) ──────────
echo "==> [4/7] Writing application to $APP_DIR ..."
mkdir -p "$APP_DIR/templates" "$APP_DIR/wallpapers" "$APP_DIR/sd-output" "$APP_DIR/uploads"

cat > "$APP_DIR/app.py" <<'APP_PY_EOF'
#!/usr/bin/env python3
"""OLED SSD1306 Web Controller + Stable Diffusion (OnnxStream) — Flask app on Raspberry Pi."""

import io
import os
import re
import time
import uuid
import subprocess
import threading
from pathlib import Path
from flask import Flask, render_template, request, jsonify, send_file
from PIL import Image
from luma.oled.device import ssd1306 as oled_device
from luma.core.interface import serial
from luma.core.render import canvas as oled_canvas

# ── OLED setup ──────────────────────────────────────────────
I2C_BUS = 1
I2C_ADDR = 0x3C
WIDTH, HEIGHT = 128, 64

i2c_iface = serial.i2c(port=I2C_BUS, address=I2C_ADDR)
oled = oled_device(i2c_iface, width=WIDTH, height=HEIGHT)
oled_lock = threading.Lock()

app = Flask(__name__)

# ── pixel canvas (in-memory bitmap) ────────────────────────
# True = white (pixel on), False = black
pixel_grid = [[False] * WIDTH for _ in range(HEIGHT)]


def grid_to_image(grid):
    """Convert pixel grid to PIL image."""
    img = Image.new("1", (WIDTH, HEIGHT))
    for y in range(HEIGHT):
        for x in range(WIDTH):
            img.putpixel((x, y), 255 if grid[y][x] else 0)
    return img


def show_on_oled(img):
    """Push a PIL image to the OLED."""
    try:
        with oled_lock:
            oled.display(img)
        return True
    except Exception as e:
        print(f"OLED error: {type(e).__name__}: {e}", flush=True)
        return False

# ── wallpaper dir ──────────────────────────────────────────
WALLPAPER_DIR = Path.home() / "oled-web" / "wallpapers"
WALLPAPER_DIR.mkdir(exist_ok=True)


def set_as_wallpaper(img):
    """Save image as PNG and set as desktop wallpaper via pcmanfm. Only the latest image is kept."""
    fname = f"oled-{uuid.uuid4().hex[:12]}.png"
    path = WALLPAPER_DIR / fname
    # Save as RGB PNG (pcmanfm doesn't like 1-bit)
    rgb_img = img.convert("RGB")
    rgb_img.save(str(path))

    # Check aspect ratio: 16:9 = 1.777...
    w, h = rgb_img.size
    ratio = w / h
    # Use stretch for ~16:9, fit (seitenverhältnis) for others
    mode = "stretch" if abs(ratio - 16 / 9) < 0.1 else "fit"

    # Remove old wallpapers, keep only the current one
    for old in WALLPAPER_DIR.glob("oled-*.png"):
        if old.name != fname:
            old.unlink(missing_ok=True)

    try:
        subprocess.run(
            ["pcmanfm", "-w", str(path), f"--wallpaper-mode={mode}"],
            check=True, capture_output=True, timeout=5
        )
        print(f"🖼️  Wallpaper set ({mode}): {path} [{w}x{h}]")
        return str(path)
    except Exception as e:
        print(f"Wallpaper error: {e}")
        return None

# ── Stable Diffusion (OnnxStream) ──────────────────────────
HOME = Path.home()
SD_BINARY = HOME / "onnxstream" / "OnnxStream" / "src" / "build" / "sd"
SD_OUTPUT_DIR = HOME / "oled-web" / "sd-output"
SD_OUTPUT_DIR.mkdir(exist_ok=True)
SD_LOG_FILE = HOME / "oled-web" / "sd-run.log"

# Available model sets. Each model has:
#   label          - human name for the GUI
#   path           - absolute model directory (absolute required: sd rejects nesting)
#   steps (min,max,def) - clamped step range + default (turbo = few-step distilled)
#   flags_fast     - extra flags for the (only) generation mode: --ram / fp16
#   supports_res   - True if the sd binary accepts --res (anyshape / turbo only)
#   recommend      - short GUI hint shown under the Steps field
# NOTE: the app always runs in Fast mode (--ram / fp16); there is no separate
# quality mode, so only one flag set is defined.
SD_MODELS = {
    "sdxl_turbo": {
        "label": "SDXL Turbo",
        "path": HOME / "onnxstream" / "models-sdxl-turbo",
        "steps": (1, 8, 4),
        "flags_fast": ["--xl", "--turbo", "--ram"],
        "supports_res": True,
        "recommend": "Recommended 2–4; up to 8 = more detail",
    },
}
SD_MODEL_DEFAULT = "sdxl_turbo"
# Default aspect ratio ("WxH") for models that support --res (16:9).
SD_RES_DEFAULT = "896x512"
# All generations run in Fast mode (--ram / fp16). There is no Quality option.
SD_FAST_DEFAULT = True

# ── SD state (protected by sd_lock) ────────────────────────
sd_lock = threading.Lock()
sd_state = {
    "running": False,
    "phase": "idle",          # idle | running | done | error
    "prompt": "",
    "steps": 10,
    "current_step": 0,
    "total_steps": 10,
    "output": None,           # path of last generated image
    "error": None,
    "started": None,
    "elapsed": None,
    "fast": SD_FAST_DEFAULT,
    "res": None,
    "model": SD_MODEL_DEFAULT,
}


def _sd_log(msg):
    ts = time.strftime("%H:%M:%S")
    line = f"[{ts}] {msg}\n"
    print(line, end="", flush=True)
    try:
        with open(SD_LOG_FILE, "a") as f:
            f.write(line)
    except Exception:
        pass


def _update_oled_status(phase, current=0, total=0, msg=None):
    """Draw a simple status line on the OLED (text mode)."""
    try:
        lines = []
        if phase == "running":
            pct = int(100 * current / total) if total else 0
            lines = [f"SD: step {current}/{total}", f"{pct:3d}%  {(msg or '')[:16]}"]
        elif phase == "done":
            lines = ["SD: done", f"elapsed {sd_state['elapsed']:.0f}s"]
        elif phase == "error":
            lines = ["SD: ERROR", (sd_state["error"] or "")[:18]]
        else:
            lines = ["SD: idle", "POST /sd/generate"]

        with oled_lock:
            with oled_canvas(oled) as c:
                for i, ln in enumerate(lines[:2]):
                    c.text((2, i * 13 + 2), ln[:20], fill="white")
    except Exception as e:
        _sd_log(f"OLED status error: {e}")


def _parse_sd_progress(line):
    """Parse a line of `sd` stdout and return the current step index (0-based) or None.
    OnnxStream prints lines like:  'step:0\t\t42322ms'  (one per UNet step)."""
    m = re.match(r"^step:\s*(\d+)\b", line.strip())
    if m:
        return int(m.group(1))
    return None


def _sd_worker(prompt, steps, seed, model="sdxl_turbo", res=None):
    """Run the OnnxStream `sd` binary; update state + OLED as it goes.

    model = key in SD_MODELS (e.g. "sdxl_turbo").
    Always runs in Fast mode (--ram / fp16) — there is no quality option.
    res = optional "WxH" (e.g. "768x576"); only SDXL-Turbo supports it
    (the binary rejects --res for non-turbo models), so it's ignored for others.
    """
    global sd_state
    fast = True  # fixed: all generations use Fast mode
    cfg = SD_MODELS.get(model)
    if cfg is None:
        cfg = SD_MODELS[SD_MODEL_DEFAULT]
        model = SD_MODEL_DEFAULT
    # Only the turbo branch of the sd binary accepts --res; ignore it otherwise.
    if res and not cfg.get("supports_res", False):
        res = None
    t0 = time.time()
    _sd_log(f"START model={model} prompt={prompt!r} steps={steps} seed={seed} fast={fast} res={res}")
    with sd_lock:
        sd_state.update(running=True, phase="running", prompt=prompt,
                        steps=steps, total_steps=steps, current_step=0,
                        error=None, started=t0, elapsed=None, fast=fast,
                        model=model, res=res)
    _update_oled_status("running", 0, steps, prompt[:16])

    out_file = SD_OUTPUT_DIR / f"sd-{uuid.uuid4().hex[:12]}.png"
    cmd = [
        str(SD_BINARY),
        "--models-path", str(cfg["path"]),
        "--prompt", prompt,
        "--steps", str(steps),
        "--output", str(out_file),
        "--download", "never",
    ]
    cmd += list(cfg["flags_fast"])
    if res:
        cmd += ["--res", res]
    if seed is not None:
        cmd += ["--seed", str(seed)]
    _sd_log("CMD: " + " ".join(f'"{c}"' if " " in c else c for c in cmd))

    proc = None
    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, bufsize=1)
        for line in proc.stdout:
            line = line.rstrip()
            if line:
                _sd_log(f"sd> {line}")
            prog = _parse_sd_progress(line)
            if prog is not None:
                cur = min(steps, prog + 1)  # step:N just finished -> N+1 completed
                with sd_lock:
                    if not sd_state["running"]:
                        break
                    sd_state["current_step"] = cur
                    sd_state["phase"] = "running"
                _update_oled_status("running", cur, steps, sd_state["prompt"][:16])
        proc.wait()
    except Exception as e:
        _sd_log(f"EXC: {e}")
        with sd_lock:
            sd_state.update(running=False, phase="error", error=str(e)[:200])
        _update_oled_status("error")
        return

    elapsed = time.time() - t0
    if proc.returncode == 0 and out_file.exists():
        with sd_lock:
            sd_state.update(running=False, phase="done", output=str(out_file),
                            current_step=steps, elapsed=elapsed)
        _sd_log(f"DONE in {elapsed:.1f}s -> {out_file}")
        # Show the finished image on the OLED and KEEP it there until the next
        # action (new generation, upload, wallpaper, pixel edit, ...) replaces it.
        image_shown = False
        try:
            image_shown = bool(_sd_push_active(out_file, sd_active["threshold"]))
            sd_active["active"] = out_file
            _sd_log(f"Finished image on OLED: {'shown (persistent)' if image_shown else 'FAILED'}")
        except Exception as e:
            _sd_log(f"OLED final image error: {e}")
        if not image_shown:
            _update_oled_status("done")
    else:
        err = f"exit code {proc.returncode}"
        with sd_lock:
            sd_state.update(running=False, phase="error", error=err)
        _sd_log(f"FAILED: {err}. Last log lines:")
        _update_oled_status("error")


@app.route("/")
def index():
    return render_template("index.html")


@app.route("/sd/status", methods=["GET"])
def sd_status():
    with sd_lock:
        return jsonify(sd_state)


@app.route("/sd/models", methods=["GET"])
def sd_models():
    """List available SD model sets with their step ranges and defaults."""
    out = []
    for key, cfg in SD_MODELS.items():
        lo, hi, dflt = cfg["steps"]
        out.append({
            "id": key,
            "label": cfg["label"],
            "default": dflt,
            "min": lo,
            "max": hi,
            "installed": cfg["path"].exists(),
            "supports_res": bool(cfg.get("supports_res", False)),
            "recommend": cfg.get("recommend", ""),
            "fast": True,
        })
    return jsonify({"ok": True, "default": SD_MODEL_DEFAULT, "models": out})


@app.route("/sd/generate", methods=["POST"])
def sd_generate():
    data = request.get_json(silent=True) or {}
    prompt = (data.get("prompt") or "").strip()
    if not prompt:
        return jsonify({"ok": False, "error": "prompt required"}), 400

    model = (data.get("model") or SD_MODEL_DEFAULT).strip()
    if model not in SD_MODELS:
        return jsonify({"ok": False, "error": f"unknown model '{model}'"}), 400
    cfg = SD_MODELS[model]
    lo, hi, dflt = cfg["steps"]
    try:
        steps = int(data.get("steps", dflt))
    except (TypeError, ValueError):
        steps = dflt
    steps = max(lo, min(hi, steps))

    seed = data.get("seed")
    seed = int(seed) if seed not in (None, "", "random") else None
    # Always Fast mode (--ram / fp16). The "fast" field in the request is
    # ignored: there is no quality option.
    fast = True

    # Optional "WxH" resolution (e.g. "768x576"). Only SDXL-Turbo honours it;
    # the sd binary requires W>=40, W and H positive multiples of 8. When the
    # model supports it and none is given, fall back to SD_RES_DEFAULT (16:9).
    res = (data.get("res") or "").strip()
    if res:
        mres = re.fullmatch(r"(\d+)x(\d+)", res)
        if not mres or int(mres.group(1)) % 8 or int(mres.group(2)) % 8 or \
           int(mres.group(1)) < 40 or int(mres.group(2)) < 8:
            return jsonify({"ok": False,
                            "error": "res must be 'WIDTHxHEIGHT', multiples of 8, W>=40, H>=8 (e.g. 768x576)"}), 400
        res = res.lower()
    elif cfg.get("supports_res", False):
        res = SD_RES_DEFAULT
    else:
        res = None

    if not SD_BINARY.exists():
        return jsonify({"ok": False, "error": f"sd binary not found at {SD_BINARY}"}), 500
    if not cfg["path"].exists():
        return jsonify({"ok": False, "error": f"models not found at {cfg['path']}"}), 500

    with sd_lock:
        if sd_state["running"]:
            return jsonify({"ok": False, "error": "generation already running"}), 409

    threading.Thread(target=_sd_worker,
                     args=(prompt, steps, seed, model, res), daemon=True).start()
    return jsonify({"ok": True})


@app.route("/sd/latest", methods=["GET"])
def sd_latest():
    with sd_lock:
        out = sd_state.get("output")
    if not out or not Path(out).exists():
        return jsonify({"ok": False, "error": "no image yet"}), 404
    return Path(out).read_bytes(), 200, {"Content-Type": "image/png"}


@app.route("/sd/result/<name>")
def sd_result(name):
    p = SD_OUTPUT_DIR / name
    if not p.is_file():
        return "not found", 404
    return send_file(p)


# ── SD: remember last images + live threshold ─────────────
SD_KEEP = 8
sd_active = {"active": None, "threshold": 96}


def _sd_recent():
    files = [p for p in SD_OUTPUT_DIR.iterdir()
             if p.suffix.lower() in UPLOAD_EXTS and p.is_file()]
    files.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    for p in files[SD_KEEP:]:      # keep the last SD_KEEP images
        try:
            p.unlink()
        except OSError:
            pass
    return [{"name": p.name, "url": f"/sd/result/{p.name}",
             "ts": p.stat().st_mtime} for p in files[:SD_KEEP]]


@app.route("/sd/list", methods=["GET"])
def sd_list():
    return jsonify(_sd_recent())


def _sd_push_active(path, threshold):
    """Render an SD image onto the OLED (2:1 center-crop, full-bleed),
    binarized with the given threshold. Returns True on success."""
    img = Image.open(path).convert("L")
    if img.width / img.height > WIDTH / HEIGHT:
        new_w = int(img.height * WIDTH / HEIGHT)
        left = (img.width - new_w) // 2
        img = img.crop((left, 0, left + new_w, img.height))
    else:
        new_h = int(img.width * HEIGHT / WIDTH)
        top = (img.height - new_h) // 2
        img = img.crop((0, top, img.width, top + new_h))
    img = img.resize((WIDTH, HEIGHT), Image.LANCZOS)
    img = img.point(lambda p: 255 if p > threshold else 0, "1")
    return show_on_oled(img)


@app.route("/sd/threshold", methods=["POST"])
def sd_threshold():
    """Live-adjust the currently shown SD image (no re-generation)."""
    data = request.get_json(silent=True) or {}
    try:
        threshold = max(0, min(255, int(data.get("threshold", 96))))
    except (TypeError, ValueError):
        return jsonify({"ok": False, "error": "invalid value"}), 400
    with sd_lock:
        running = sd_state.get("running", False)
    if running:
        return jsonify({"ok": False, "error": "generation is currently running"}), 409
    active = sd_active.get("active")
    if not active or not Path(active).is_file():
        recent = _sd_recent()
        if not recent:
            return jsonify({"ok": False, "error": "no active image"}), 404
        active = str(SD_OUTPUT_DIR / recent[0]["name"])
        sd_active["active"] = active
    try:
        if not _sd_push_active(active, threshold):
            raise OSError("OLED update failed")
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)}), 500
    sd_active["threshold"] = threshold
    return jsonify({"ok": True, "threshold": threshold})


@app.route("/sd/select", methods=["POST"])
def sd_select():
    """Make one of the remembered SD images the active image on the OLED."""
    data = request.get_json(silent=True) or {}
    name = Path(str(data.get("name", ""))).name
    p = SD_OUTPUT_DIR / name
    if not p.is_file():
        return jsonify({"ok": False, "error": "unknown image"}), 404
    with sd_lock:
        running = sd_state.get("running", False)
    if running:
        return jsonify({"ok": False, "error": "generation is currently running"}), 409
    try:
        if not _sd_push_active(str(p), sd_active["threshold"]):
            raise OSError("OLED update failed")
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)}), 500
    sd_active["active"] = str(p)
    return jsonify({"ok": True, "name": name})


@app.route("/sd/delete", methods=["POST"])
def sd_delete():
    """Delete a remembered SD image from the gallery (and SD card)."""
    data = request.get_json(silent=True) or {}
    name = Path(str(data.get("name", ""))).name
    p = SD_OUTPUT_DIR / name
    if not p.is_file() or not name.startswith("sd-"):
        return jsonify({"ok": False, "error": "unknown image"}), 404
    with sd_lock:
        running = sd_state.get("running", False)
    if running:
        return jsonify({"ok": False, "error": "generation is currently running"}), 409
    try:
        p.unlink()
    except OSError as e:
        return jsonify({"ok": False, "error": str(e)}), 500
    if sd_active.get("active") == str(p):
        sd_active["active"] = None
    return jsonify({"ok": True})


# ── Uploads (GUI gallery) ─────────────────────────────────
UPLOAD_DIR = Path.home() / "oled-web" / "uploads"
UPLOAD_DIR.mkdir(exist_ok=True)
UPLOAD_KEEP = 12
UPLOAD_EXTS = {".png", ".jpg", ".jpeg", ".webp", ".gif", ".bmp"}
upload_state = {"active": None, "threshold": 128}  # last uploaded image, live-adjustable


def _prune_uploads():
    files = sorted(UPLOAD_DIR.iterdir(), key=lambda p: p.stat().st_mtime, reverse=True)
    for p in files[UPLOAD_KEEP:]:
        p.unlink(missing_ok=True)


def _push_to_oled(img, threshold=96, set_wallpaper=True):
    """Fit image into 128x64 (letterboxed), binarize, show on OLED (+ set wallpaper)."""
    original = img.convert("RGB")
    img_gray = img.convert("L")
    img_gray.thumbnail((WIDTH, HEIGHT), Image.LANCZOS)
    canvas_img = Image.new("L", (WIDTH, HEIGHT), 0)
    canvas_img.paste(img_gray, ((WIDTH - img_gray.width) // 2, (HEIGHT - img_gray.height) // 2))
    img_oled = canvas_img.point(lambda p: 255 if p > threshold else 0, "1")
    show_on_oled(img_oled)
    if set_wallpaper:
        set_as_wallpaper(original)


@app.route("/uploads/list", methods=["GET"])
def uploads_list():
    items = []
    for p in UPLOAD_DIR.iterdir():
        if p.suffix.lower() in UPLOAD_EXTS:
            items.append({"name": p.name, "url": f"/uploads/{p.name}",
                          "ts": p.stat().st_mtime})
    items.sort(key=lambda x: x["ts"], reverse=True)
    return jsonify(items)


@app.route("/uploads/<path:name>", methods=["GET"])
def uploads_get(name):
    p = (UPLOAD_DIR / name).resolve()
    if not str(p).startswith(str(UPLOAD_DIR)) or not p.is_file():
        return "not found", 404
    return send_file(p)


@app.route("/upload/redisplay", methods=["POST"])
def upload_redisplay():
    """Push a previously uploaded (saved) image back to the OLED + wallpaper."""
    data = request.get_json(silent=True) or {}
    name = (data.get("name") or "").strip()
    p = UPLOAD_DIR / name
    if not p.is_file() or p.suffix.lower() not in UPLOAD_EXTS:
        return jsonify({"ok": False, "error": "unknown image"}), 404
    try:
        _push_to_oled(Image.open(p), threshold=upload_state["threshold"])
        upload_state["active"] = str(p)
        return jsonify({"ok": True})
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)}), 500


@app.route("/upload/delete", methods=["POST"])
def upload_delete():
    """Delete a saved upload from the gallery (and SD card)."""
    data = request.get_json(silent=True) or {}
    name = (data.get("name") or "").strip()
    if not re.fullmatch(r"[A-Za-z0-9._\-]+", name):
        return jsonify({"ok": False, "error": "invalid name"}), 400
    p = UPLOAD_DIR / name
    if not p.is_file() or p.suffix.lower() not in UPLOAD_EXTS:
        return jsonify({"ok": False, "error": "unknown image"}), 404
    try:
        p.unlink()
    except OSError as e:
        return jsonify({"ok": False, "error": str(e)}), 500
    if upload_state.get("active") == str(p):
        upload_state["active"] = None
    return jsonify({"ok": True})


@app.route("/upload/threshold", methods=["POST"])
def upload_threshold():
    """Live re-binarize the currently active image with a new threshold (no wallpaper reset)."""
    data = request.get_json(silent=True) or {}
    try:
        threshold = int(data.get("threshold", 128))
    except (TypeError, ValueError):
        return jsonify({"ok": False, "error": "invalid threshold"}), 400
    threshold = max(0, min(255, threshold))
    active = upload_state.get("active")
    if not active or not Path(active).is_file():
        # Fallback (e.g. after service restart): the most recently uploaded image
        files = [p for p in UPLOAD_DIR.iterdir() if p.suffix.lower() in UPLOAD_EXTS]
        if not files:
            return jsonify({"ok": False, "error": "no active image"}), 404
        active = str(max(files, key=lambda p: p.stat().st_mtime))
        upload_state["active"] = active
    try:
        _push_to_oled(Image.open(active), threshold=threshold, set_wallpaper=False)
        upload_state["threshold"] = threshold
        return jsonify({"ok": True, "threshold": threshold})
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)}), 500


@app.route("/upload", methods=["POST"])
def upload():
    if "file" not in request.files:
        return jsonify({"ok": False, "error": "no file"}), 400

    f = request.files["file"]
    if not f.filename:
        return jsonify({"ok": False, "error": "empty filename"}), 400

    try:
        img = Image.open(io.BytesIO(f.read()))
        # Store the upload so it is visible in the webGUI gallery
        safe_name = re.sub(r"[^A-Za-z0-9._-]", "_", f.filename)[:80] or "image.png"
        ext = os.path.splitext(safe_name)[1].lower() or ".png"
        stored = UPLOAD_DIR / f"up-{time.strftime('%Y%m%d-%H%M%S')}-{uuid.uuid4().hex[:6]}{ext}"
        img.convert("RGB").save(stored, "PNG")
        _prune_uploads()
        threshold = request.form.get("threshold", 128, type=int)
        _push_to_oled(img, threshold)
        upload_state["active"] = str(stored)
        upload_state["threshold"] = threshold
        return jsonify({"ok": True, "name": safe_name,
                        "url": f"/uploads/{stored.name}", "ts": stored.stat().st_mtime})
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)}), 500


@app.route("/draw/set", methods=["POST"])
def draw_set():
    """Set/clear pixels. Body: {x, y, color}"""
    data = request.get_json()
    x = int(data.get("x", 0))
    y = int(data.get("y", 0))
    color = data.get("color", True)
    if 0 <= x < WIDTH and 0 <= y < HEIGHT:
        pixel_grid[y][x] = bool(color)
    return jsonify({"ok": True})


@app.route("/draw/batch", methods=["POST"])
def draw_batch():
    """Bulk pixel update. Body: {pixels: [[x, y, color], ...]}"""
    data = request.get_json()
    for px, py, col in data.get("pixels", []):
        if 0 <= px < WIDTH and 0 <= py < HEIGHT:
            pixel_grid[py][px] = bool(col)
    return jsonify({"ok": True})


@app.route("/draw/clear", methods=["POST"])
def draw_clear():
    for row in pixel_grid:
        for i in range(len(row)):
            row[i] = False
    img = grid_to_image(pixel_grid)
    show_on_oled(img)
    set_as_wallpaper(img)
    return jsonify({"ok": True})


@app.route("/draw/send", methods=["POST"])
def draw_send():
    img = grid_to_image(pixel_grid)
    show_on_oled(img)
    set_as_wallpaper(img)
    return jsonify({"ok": True})


# ── Main ────────────────────────────────────────────────────
if __name__ == "__main__":
    # Clear display on startup
    show_on_oled(grid_to_image(pixel_grid))
    app.run(host="0.0.0.0", port=5000, debug=False, threaded=True)
APP_PY_EOF

cat > "$APP_DIR/templates/index.html" <<'INDEX_HTML_EOF'
<!DOCTYPE html>
<html lang="en">

<head>
  <meta http-equiv="Cache-Control" content="no-cache, no-store, must-revalidate">  <meta http-equiv="Pragma" content="no-cache">  <meta http-equiv="Expires" content="0">
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>OLED Controller</title>
  <style>
    :root {
      --bg: #1a1a2e;
      --surface: #16213e;
      --primary: #0f3460;
      --accent: #e94560;
      --text: #eee;
      --dim: #888;
    }

    * {
      margin: 0;
      padding: 0;
      box-sizing: border-box;
    }

    body {
      font-family: 'Segoe UI', system-ui, sans-serif;
      background: var(--bg);
      color: var(--text);
      min-height: 100vh;
      display: flex;
      flex-direction: column;
      align-items: center;
    }

    header {
      width: 100%;
      background: var(--surface);
      padding: 1.2rem 2rem;
      text-align: center;
      border-bottom: 2px solid var(--accent);
    }

    header h1 {
      font-size: 1.6rem;
      font-weight: 600;
    }

    header p {
      color: var(--dim);
      font-size: 0.85rem;
      margin-top: .3rem;
    }

    main {
      flex: 1;
      width: 100%;
      max-width: 900px;
      padding: 2rem 1rem;
    }

    .tabs {
      display: flex;
      gap: 0;
      margin-bottom: 1.5rem;
    }

    .tab-btn {
      flex: 1;
      padding: .85rem;
      border: none;
      background: var(--surface);
      color: var(--dim);
      font-size: 1rem;
      cursor: pointer;
      transition: .2s;
      border-bottom: 3px solid transparent;
    }

    .tab-btn.active {
      color: var(--accent);
      border-bottom-color: var(--accent);
      background: var(--primary);
    }

    .tab-btn:hover:not(.active) {
      background: var(--primary);
    }

    .tab-content {
      display: none;
    }

    .tab-content.active {
      display: block;
    }

    .panel {
      background: var(--surface);
      border-radius: 10px;
      padding: 1.5rem;
    }

    /* ── Upload ── */
    .drop-zone {
      border: 2px dashed var(--dim);
      border-radius: 8px;
      padding: 2.5rem;
      text-align: center;
      cursor: pointer;
      transition: .2s;
      margin-bottom: 1rem;
    }

    .drop-zone:hover,
    .drop-zone.drag-over {
      border-color: var(--accent);
      background: rgba(233, 69, 96, .05);
    }

    .drop-zone p {
      color: var(--dim);
      margin-top: .5rem;
    }

    .drop-zone .icon {
      font-size: 2.5rem;
    }

    #file-input {
      display: none;
    }

    .status-bar {
      margin-top: 1rem;
      padding: .6rem 1rem;
      border-radius: 6px;
      font-size: .9rem;
      display: none;
    }

    .status-bar.ok {
      display: block;
      background: #1b5e20;
      color: #a5d6a7;
    }

    .status-bar.err {
      display: block;
      background: #b71c1c;
      color: #ef9a9a;
    }

    .threshold-row {
      display: flex;
      align-items: center;
      gap: 1rem;
      margin-top: 1rem;
    }

    .threshold-row label {
      color: var(--dim);
      font-size: .9rem;
      min-width: 80px;
    }

    .threshold-row input[type=range] {
      flex: 1;
      accent-color: var(--accent);
    }

    /* ── Canvas (Pixel Editor) ── */
    .canvas-area {
      display: flex;
      gap: 1.5rem;
      align-items: flex-start;
      flex-wrap: wrap;
    }

    .canvas-wrap {
      position: relative;
    }

    #pixel-canvas {
      background: #000;
      image-rendering: pixelated;
      width: 256px;
      height: 128px;
      border-radius: 6px;
      cursor: crosshair;
      border: 2px solid var(--primary);
    }

    .tools {
      flex: 1;
      min-width: 200px;
    }

    .tools h3 {
      margin-bottom: .8rem;
      font-size: 1rem;
    }

    .tools button {
      display: block;
      width: 100%;
      padding: .7rem 1rem;
      margin-bottom: .5rem;
      border: none;
      border-radius: 6px;
      font-size: .9rem;
      cursor: pointer;
      transition: .2s;
    }

    .btn-accent {
      background: var(--accent);
      color: #fff;
    }

    .btn-accent:hover {
      background: #d63851;
    }

    .btn-secondary {
      background: var(--primary);
      color: var(--text);
    }

    .btn-secondary:hover {
      background: #1a4a7a;
    }

    .color-toggle {
      display: flex;
      gap: .5rem;
      margin-bottom: 1rem;
    }

    .color-toggle button {
      flex: 1;
      padding: .5rem;
      border: 2px solid var(--primary);
      border-radius: 6px;
      cursor: pointer;
      font-size: .85rem;
      transition: .2s;
    }

    .color-toggle button.active-white {
      background: #fff;
      color: #000;
      border-color: #fff;
    }

    .color-toggle button.active-black {
      background: #000;
      color: #fff;
      border-color: var(--accent);
    }

    .hint {
      color: var(--dim);
      font-size: .8rem;
      margin-top: .8rem;
      line-height: 1.4;
    }

    .live-preview {
      margin-top: 1rem;
      text-align: center;
    }

    .live-preview img {
      border-radius: 6px;
      border: 2px solid var(--primary);
      image-rendering: pixelated;
    }

    /* ── Stable Diffusion ── */
    .sd-form label {
      display: block;
      color: var(--dim);
      font-size: .85rem;
      margin: .8rem 0 .3rem;
    }

    .sd-form textarea {
      width: 100%;
      min-height: 70px;
      background: var(--bg);
      color: var(--text);
      border: 2px solid var(--primary);
      border-radius: 6px;
      padding: .7rem;
      font-size: .95rem;
      font-family: inherit;
      resize: vertical;
    }

    .sd-form textarea:focus {
      outline: none;
      border-color: var(--accent);
    }

    .sd-options {
      display: flex;
      gap: 1.2rem;
      flex-wrap: wrap;
      margin-top: .3rem;
    }

    .sd-options label {
      margin-top: .5rem;
      display: flex;
      align-items: center;
      gap: .5rem;
    }

    .sd-options input {
      width: 80px;
      background: var(--bg);
      color: var(--text);
      border: 2px solid var(--primary);
      border-radius: 6px;
      padding: .4rem .6rem;
      font-size: .9rem;
    }

    .sd-options input:focus {
      outline: none;
      border-color: var(--accent);
    }

    #sd-generate {
      margin-top: 1rem;
      width: 100%;
      padding: .85rem;
      font-size: 1rem;
    }

    #sd-generate:disabled {
      background: var(--primary);
      color: var(--dim);
      cursor: wait;
    }

    .sd-progress {
      margin-top: 1rem;
      display: none;
    }

    .sd-progress.visible {
      display: block;
    }

    .progress-track {
      height: 14px;
      background: var(--bg);
      border-radius: 7px;
      overflow: hidden;
      border: 1px solid var(--primary);
    }

    .progress-fill {
      height: 100%;
      width: 0%;
      background: var(--accent);
      transition: width .4s;
    }

    .sd-progress-text {
      margin-top: .4rem;
      color: var(--dim);
      font-size: .85rem;
    }

    .sd-result {
      margin-top: 1.2rem;
      text-align: center;
      display: none;
    }

    .sd-result.visible {
      display: block;
    }

    .sd-result img {
      max-width: 100%;
      border-radius: 8px;
      border: 2px solid var(--primary);
    }

    .sd-result a {
      display: inline-block;
      margin-top: .6rem;
      color: var(--accent);
      font-size: .9rem;
    }

    /* ── Upload gallery ── */
    .upload-gallery {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(140px, 1fr));
      gap: .8rem;
      margin-top: .8rem;
    }

    .upload-card {
      background: var(--bg);
      border: 1px solid var(--primary);
      border-radius: 8px;
      overflow: hidden;
      text-align: center;
    }

    .upload-card img {
      width: 100%;
      display: block;
    }

    .upload-card .card-body {
      padding: .5rem;
    }

    .upload-card .card-name {
      font-size: .72rem;
      color: var(--text);
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }

    .upload-card .card-date {
      font-size: .68rem;
      color: var(--dim);
      margin-top: .15rem;
    }

    .upload-card button {
      margin-top: .4rem;
      padding: .3rem .7rem;
      border: none;
      border-radius: 5px;
      background: var(--primary);
      color: var(--text);
      font-size: .75rem;
      cursor: pointer;
    }

    .upload-card button:hover {
      background: var(--accent);
    }

    .card-actions {
      display: flex;
      gap: .4rem;
      justify-content: center;
    }

    .card-actions button {
      margin-top: .4rem;
      flex: 1;
    }

    .card-actions .del-btn {
      background: transparent;
      border: 1px solid var(--dim);
      color: var(--dim);
    }

    .card-actions .del-btn:hover {
      border-color: #e05555;
      color: #e05555;
      background: rgba(224, 85, 85, .12);
    }

    .upload-gallery-empty {
      color: var(--dim);
      font-size: .85rem;
      margin-top: .5rem;
    }
  </style>
</head>

<body>
  <header>
    <h1>OLED Controller — SSD1306</h1>
    <p>Pixel Paint · Upload Image · Stable Diffusion on ARM</p>
  </header>

  <main>
    <div class="tabs">
      <button class="tab-btn active" onclick="showTab('draw', this)">🎨 Pixel Paint</button>
      <button class="tab-btn" onclick="showTab('upload', this)">📤 Upload Image</button>
      <button class="tab-btn" onclick="showTab('sd', this)">✨ Stable Diffusion</button>
    </div>

    <!-- Upload tab -->
    <div id="tab-upload" class="tab-content">
      <div class="panel">
        <div class="drop-zone" id="drop-zone" onclick="document.getElementById('file-input').click()">
          <div class="icon">🖼️</div>
          <p>Drag & Drop or <strong>click to select</strong></p>
          <p style="font-size:.8rem;color:#666">JPEG, PNG, GIF — automatically scaled to 128×64</p>
        </div>
        <input type="file" id="file-input" accept="image/*">

        <div class="threshold-row">
          <label>Threshold:</label>
          <input type="range" id="threshold" min="0" max="255" value="128">
          <span id="threshold-val" style="min-width:40px;text-align:right;color:var(--dim)">128</span>
        </div>

        <div id="upload-status" class="status-bar"></div>

        <h3 style="margin-top:1.4rem;font-size:1rem;color:var(--dim)">Recently uploaded</h3>
        <p class="hint" style="margin-top:.2rem">All uploaded images appear here. "On OLED" re-displays the image on the screen.</p>
        <div id="upload-gallery" class="upload-gallery"></div>
      </div>
    </div>

    <!-- Draw tab -->
    <div id="tab-draw" class="tab-content active">
      <div class="panel">
        <div class="canvas-area">
          <div class="canvas-wrap">
            <canvas id="pixel-canvas" width="128" height="64"></canvas>
            <div class="live-preview">
              <p style="color:var(--dim);font-size:.8rem;margin-top:.5rem">
                Live Preview (1:1 scale)
              </p>
            </div>
          </div>
          <div class="tools">
            <h3>Tools</h3>
            <div class="color-toggle">
              <button id="pen-white" class="active-white" onclick="setPen(true)">⬜ White</button>
              <button id="pen-black" onclick="setPen(false)">⬛ Black</button>
            </div>
            <button class="btn-accent" onclick="sendToOLED()">Send to Display</button>
            <button class="btn-secondary" onclick="clearCanvas()">🗑️ Clear</button>
            <button class="btn-secondary" onclick="exportCanvas()">💾 Save as PNG</button>
            <p class="hint">
              Click or drag the mouse on the canvas to draw.
              "Send to Display" sends the image to the OLED.
            </p>
          </div>
        </div>
      </div>
    </div>

    <!-- Stable Diffusion tab -->
    <div id="tab-sd" class="tab-content">
      <div class="panel sd-form">
        <div style="font-size:1rem;margin-bottom:.3rem">✨ Stable Diffusion <span style="color:var(--dim);font-size:.8rem">(OnnxStream, CPU)</span></div>
        <p class="hint" style="margin:0 0 .8rem">Generation runs directly on the Raspberry Pi (CPU, ~1 minute/step, depending on resolution). Progress is shown on the OLED display.</p>

        <label for="sd-prompt">Prompt</label>
        <textarea id="sd-prompt" placeholder="e.g. a cozy cabin in the mountains at sunset, photorealistic, soft light"></textarea>

        <div class="sd-options" id="sd-row">
          <label>Format:
            <select id="sd-res">
              <option value="">Square (512×512)</option>
              <option value="768x576">4:3 — 768×576</option>
              <option value="896x512" selected>16:9 — 896×512</option>
              <option value="768x512">3:2 — 768×512</option>
              <option value="custom">…custom</option>
            </select>
          </label>
          <label id="sd-res-custom" style="display:none">Custom (W×H):
            <input type="text" id="sd-res-custom-val" placeholder="z. B. 1024x768" size="14">
          </label>
          <label>Steps: <input type="number" id="sd-steps" value="4" min="1" max="8"></label>
          <label>Seed (empty = random): <input type="text" id="sd-seed" placeholder="random"></label>
        </div>

        <p class="hint" id="sd-steps-hint" style="margin-top:.4rem"></p>

        <button id="sd-generate" class="btn-accent" onclick="sdStart()">Generate</button>

        <div id="sd-status" class="status-bar"></div>

        <div id="sd-progress" class="sd-progress">
          <div class="progress-track"><div id="sd-progress-fill" class="progress-fill"></div></div>
          <div id="sd-progress-text" class="sd-progress-text">Preparing…</div>
        </div>

        <div id="sd-result" class="sd-result">
          <img id="sd-result-img" src="" alt="Result">
          <br>
          <a id="sd-result-link" href="#" target="_blank">📥 Download PNG</a>
        </div>

        <div class="threshold-row">
          <label>Threshold:</label>
          <input type="range" id="sd-threshold" min="0" max="255" value="128">
          <span id="sd-threshold-val" style="min-width:40px; text-align:right; color:var(--dim)">128</span>
        </div>
        <p class="hint" style="margin-top:.4rem">Adjusts the Stable Diffusion image currently shown on the OLED without regenerating.</p>

        <h3 style="margin-top:1.4rem;font-size:1rem;color:var(--dim)">Recent Images</h3>
        <p class="hint" style="margin-top:.2rem">The last 8 generated images. The "On OLED" button loads an image onto the OLED.</p>
        <div class="upload-gallery" id="sd-gallery"></div>
      </div>
    </div>
  </main>

  <script>
    // ── Tab switching ──
    function showTab(name, btn) {
      document.querySelectorAll('.tab-content').forEach(t => t.classList.remove('active'));
      document.querySelectorAll('.tab-btn').forEach(b => b.classList.remove('active'));
      document.getElementById('tab-' + name).classList.add('active');
      (btn || event.target).classList.add('active');
      if (name === 'sd') sdPoll(true);
      if (name === 'upload') loadUploadGallery(false);
      if (name === 'sd') loadSdGallery();
    }

    // ── Upload ──
    const fileInput = document.getElementById('file-input');
    const dropZone = document.getElementById('drop-zone');
    const thresholdSlider = document.getElementById('threshold');
    const thresholdVal = document.getElementById('threshold-val');
    const uploadStatus = document.getElementById('upload-status');

    thresholdSlider.addEventListener('input', () => {
      thresholdVal.textContent = thresholdSlider.value;
      // Live-adjust the currently displayed image on the OLED (server-side, debounced)
      clearTimeout(thresholdTimer);
      thresholdTimer = setTimeout(sendThreshold, 120);
    });

    let thresholdTimer = null;
    function sendThreshold() {
      fetch('/upload/threshold', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ threshold: parseInt(thresholdSlider.value, 10) })
      }).then(r => r.json()).then(d => {
        if (!d.ok && d.error === 'no active image') {
          // nothing uploaded in this session — harmless, keep the value
        }
      }).catch(() => {});
    }

    ['dragover', 'dragenter'].forEach(e => {
      dropZone.addEventListener(e, ev => { ev.preventDefault(); dropZone.classList.add('drag-over'); });
    });
    ['dragleave', 'drop'].forEach(e => {
      dropZone.addEventListener(e, () => dropZone.classList.remove('drag-over'));
    });
    dropZone.addEventListener('drop', e => {
      e.preventDefault();
      const file = e.dataTransfer.files[0];
      if (file && file.type.startsWith('image/')) uploadFile(file);
    });
    fileInput.addEventListener('change', () => {
      if (fileInput.files[0]) uploadFile(fileInput.files[0]);
    });

    function uploadFile(file) {
      const fd = new FormData();
      fd.append('file', file);
      fd.append('threshold', thresholdSlider.value);

      uploadStatus.className = 'status-bar';
      uploadStatus.textContent = 'Uploading...';

      fetch('/upload', { method: 'POST', body: fd })
        .then(r => r.json())
        .then(data => {
          if (data.ok) {
            uploadStatus.className = 'status-bar ok';
            uploadStatus.textContent = '✅ Image is shown on the OLED!';
            loadUploadGallery(true, data.url);
          } else {
            uploadStatus.className = 'status-bar err';
            uploadStatus.textContent = '❌ ' + (data.error || 'Error');
          }
        })
        .catch(err => {
          uploadStatus.className = 'status-bar err';
          uploadStatus.textContent = '❌ ' + err;
        });
    }

    // ── Upload gallery ──
    function uploadDate(ts) {
      const d = new Date(ts * 1000);
      return d.toLocaleDateString('en-GB', { day: '2-digit', month: '2-digit', year: '2-digit' })
        + ' ' + d.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' });
    }

    function loadUploadGallery(highlightNew, newUrl) {
      fetch('/uploads/list?t=' + Date.now())
        .then(r => r.json())
        .then(items => {
          const gallery = document.getElementById('upload-gallery');
          if (!items.length) {
            gallery.innerHTML = '<div class="upload-gallery-empty">No images uploaded yet.</div>';
            return;
          }
          gallery.innerHTML = '';
          items.forEach(it => {
            const card = document.createElement('div');
            card.className = 'upload-card';
            const img = document.createElement('img');
            img.src = it.url + '?t=' + it.ts;
            img.alt = it.name;
            img.loading = 'lazy';
            const body = document.createElement('div');
            body.className = 'card-body';
            const name = document.createElement('div');
            name.className = 'card-name';
            name.textContent = it.name;
            name.title = it.name;
            const date = document.createElement('div');
            date.className = 'card-date';
            date.textContent = uploadDate(it.ts);
            const actions = document.createElement('div');
            actions.className = 'card-actions';
            const btn = document.createElement('button');
            btn.textContent = 'On OLED';
            btn.onclick = () => redisplayUpload(it.url.replace(/t=\d+$/, ''), btn);
            const del = document.createElement('button');
            del.className = 'del-btn';
            del.textContent = '🗑';
            del.title = 'Delete';
            del.onclick = () => deleteUpload(it, card, del);
            actions.append(btn, del);
            body.append(name, date, actions);
            card.append(img, body);
            if (highlightNew && it.url === newUrl) {
              card.style.border = '2px solid var(--accent)';
              card.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
            }
            gallery.appendChild(card);
          });
        })
        .catch(() => {});
    }

    function redisplayUpload(url, btn) {
      const name = url.split('/').pop().split('?')[0];
      btn.textContent = '…';
      fetch('/upload/redisplay', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name })
      })
        .then(r => r.json())
        .then(d => {
          btn.textContent = d.ok ? '✅ On OLED' : '❌ Error';
          if (d.ok) uploadStatus.className = 'status-bar ok',
            uploadStatus.textContent = '✅ Image is shown on the OLED!';
        })
        .catch(() => { btn.textContent = 'On OLED'; });
      setTimeout(() => { if (btn.textContent.startsWith('✅')) btn.textContent = 'On OLED'; }, 1500);
    }

    function deleteUpload(it, card, del) {
      if (!confirm('Really delete "' + it.name + '"?')) return;
      const name = it.url.split('/').pop().split('?')[0];
      del.textContent = '…';
      fetch('/upload/delete', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name })
      })
        .then(r => r.json())
        .then(d => {
          if (d.ok) {
            card.remove();
            const g = document.getElementById('upload-gallery');
            if (!g.querySelector('.upload-card'))
              g.innerHTML = '<div class="upload-gallery-empty">No images uploaded yet.</div>';
          } else { del.textContent = '🗑'; }
        })
        .catch(() => { del.textContent = '🗑'; });
    }

    // ── SD gallery (recent images) + threshold slider ──
    const sdThresholdSlider = document.getElementById('sd-threshold');
    const sdThresholdVal = document.getElementById('sd-threshold-val');
    let sdThresholdTimer = null;

    sdThresholdSlider.addEventListener('input', () => {
      sdThresholdVal.textContent = sdThresholdSlider.value;
      // Live-adjust the currently shown SD image (debounced, server-side)
      clearTimeout(sdThresholdTimer);
      sdThresholdTimer = setTimeout(() => {
        fetch('/sd/threshold', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ threshold: parseInt(sdThresholdSlider.value, 10) })
        }).then(r => r.json()).catch(() => {});
      }, 120);
    });

    function loadSdGallery() {
      fetch('/sd/list?t=' + Date.now())
        .then(r => r.json())
        .then(items => {
          const gallery = document.getElementById('sd-gallery');
          if (!items.length) {
            gallery.innerHTML = '<div class="upload-gallery-empty">No images generated yet.</div>';
            return;
          }
          gallery.innerHTML = '';
          items.forEach(it => {
            const card = document.createElement('div');
            card.className = 'upload-card';
            const img = document.createElement('img');
            img.src = it.url + '?t=' + it.ts;
            img.alt = it.name;
            img.loading = 'lazy';
            const body = document.createElement('div');
            body.className = 'card-body';
            const name = document.createElement('div');
            name.className = 'card-name';
            name.textContent = it.name;
            name.title = it.name;
            const date = document.createElement('div');
            date.className = 'card-date';
            date.textContent = uploadDate(it.ts);
            const actions = document.createElement('div');
            actions.className = 'card-actions';
            const btn = document.createElement('button');
            btn.textContent = 'On OLED';
            btn.onclick = () => sdSelectImage(it.name, btn);
            const del = document.createElement('button');
            del.className = 'del-btn';
            del.textContent = '🗑';
            del.title = 'Delete';
            del.onclick = () => sdDeleteImage(it, card, del);
            actions.append(btn, del);
            body.append(name, date, actions);
            card.append(img, body);
            gallery.appendChild(card);
          });
        })
        .catch(() => {});
    }

    function sdSelectImage(name, btn) {
      btn.textContent = '…';
      fetch('/sd/select', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name })
      })
        .then(r => r.json())
        .then(d => {
          btn.textContent = d.ok ? '✅ On OLED' : '❌ Error';
        })
        .catch(() => { btn.textContent = 'On OLED'; });
      setTimeout(() => { if (btn.textContent.startsWith('✅')) btn.textContent = 'On OLED'; }, 1500);
    }

    function sdDeleteImage(it, card, del) {
      if (!confirm('Really delete "' + it.name + '"?')) return;
      del.textContent = '…';
      fetch('/sd/delete', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name: it.name })
      })
        .then(r => r.json())
        .then(d => {
          if (d.ok) {
            card.remove();
            const g = document.getElementById('sd-gallery');
            if (!g.querySelector('.upload-card'))
              g.innerHTML = '<div class="upload-gallery-empty">No images generated yet.</div>';
          } else { del.textContent = '🗑'; }
        })
        .catch(() => { del.textContent = '🗑'; });
    }

    // ── Pixel Canvas ──
    const canvas = document.getElementById('pixel-canvas');
    const ctx = canvas.getContext('2d');
    let isDrawing = false;
    let isWhite = true;

    function setPen(white) {
      isWhite = white;
      document.getElementById('pen-white').className = white ? 'active-white' : '';
      document.getElementById('pen-black').className = white ? '' : 'active-black';
    }

    function getPixelPos(e) {
      const r = canvas.getBoundingClientRect();
      const x = Math.floor((e.clientX - r.left) / r.width * 128);
      const y = Math.floor((e.clientY - r.top) / r.height * 64);
      return [Math.max(0, Math.min(127, x)), Math.max(0, Math.min(63, y))];
    }

    function paint(x, y) {
      ctx.fillStyle = isWhite ? '#fff' : '#000';
      ctx.fillRect(x, y, 1, 1);
    }

    canvas.addEventListener('mousedown', e => {
      isDrawing = true;
      const [x, y] = getPixelPos(e);
      paint(x, y);
    });
    canvas.addEventListener('mousemove', e => {
      if (!isDrawing) return;
      const [x, y] = getPixelPos(e);
      paint(x, y);
    });
    canvas.addEventListener('mouseup', () => isDrawing = false);
    canvas.addEventListener('mouseleave', () => isDrawing = false);

    // Touch support
    canvas.addEventListener('touchstart', e => {
      e.preventDefault();
      isDrawing = true;
      const touch = e.touches[0];
      const [x, y] = getPixelPos(touch);
      paint(x, y);
    });
    canvas.addEventListener('touchmove', e => {
      e.preventDefault();
      const touch = e.touches[0];
      const [x, y] = getPixelPos(touch);
      paint(x, y);
    });
    canvas.addEventListener('touchend', () => isDrawing = false);

    function sendToOLED() {
      const imgData = ctx.getImageData(0, 0, 128, 64);
      const pixels = [];
      for (let y = 0; y < 64; y++) {
        for (let x = 0; x < 128; x++) {
          const i = (y * 128 + x) * 4;
          pixels.push([x, y, imgData.data[i] > 128]);
        }
      }
      fetch('/draw/batch', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ pixels })
      }).then(r => r.json()).then(() => {
        return fetch('/draw/send', { method: 'POST' });
      }).then(r => r.json()).then(d => {
        // Success is reflected on the OLED itself — no popup.
      }).catch(err => {
        console.error('send to OLED failed:', err);
      });
    }

    function clearCanvas() {
      ctx.fillStyle = '#000';
      ctx.fillRect(0, 0, 128, 64);
      fetch('/draw/clear', { method: 'POST' });
    }

    function exportCanvas() {
      const link = document.createElement('a');
      link.download = 'oled-image.png';
      link.href = canvas.toDataURL('image/png');
      link.click();
    }

    // ── Stable Diffusion ──
    const sdStatus = document.getElementById('sd-status');
    const sdProgress = document.getElementById('sd-progress');
    const sdProgressFill = document.getElementById('sd-progress-fill');
    const sdProgressText = document.getElementById('sd-progress-text');
    const sdResult = document.getElementById('sd-result');
    const sdResultImg = document.getElementById('sd-result-img');
    const sdResultLink = document.getElementById('sd-result-link');
    const sdGenerateBtn = document.getElementById('sd-generate');
    const sdStepsEl = document.getElementById('sd-steps');
    let sdPollTimer = null;
    let sdDoneShown = null;

    // There is a single model (SDXL Turbo). Fetch /sd/models to learn its step
    // range, whether it supports --res, and the recommended-steps hint.
    let sdModel = null;
    function sdModelConfig() { return sdModel; }

    function sdUpdateStepsHint() {
      const m = sdModelConfig();
      if (!m) return;
      const rec = m.recommend || '';
      document.getElementById('sd-steps-hint').textContent = rec ? `💡 ${rec}` : '';
    }
    function sdLoadModels() {
      fetch('/sd/models').then(r => r.json()).then(d => {
        if (!d.ok || !d.models || !d.models.length) return;
        sdModel = d.models.find(x => x.id === d.default) || d.models[0];
        if (sdModel) sdApplyModelSteps(sdModel);
        document.getElementById('sd-res').addEventListener('change', sdToggleResCustom);
        sdUpdateStepsHint();
      }).catch(() => {});
    }

    function sdApplyModelSteps(m) {
      sdStepsEl.min = m.min;
      sdStepsEl.max = m.max;
      sdStepsEl.value = m.default;
      sdUpdateResRow();
    }

    // Show the Format control (in the merged row) only for models that
    // support --res. The whole row (Format / Steps / Seed) stays visible.
    function sdUpdateResRow() {
      const m = sdModelConfig();
      const fmt = document.querySelector('#sd-row > label:has(#sd-res)')
        || document.getElementById('sd-row').children[0];
      const custom = document.getElementById('sd-res-custom');
      if (m && m.supports_res) {
        if (fmt) fmt.style.display = '';
        sdToggleResCustom();
      } else if (fmt) {
        fmt.style.display = 'none';
        custom.style.display = 'none';
      }
    }
    function sdToggleResCustom() {
      const sel = document.getElementById('sd-res').value;
      document.getElementById('sd-res-custom').style.display = sel === 'custom' ? '' : 'none';
    }
    function sdGetRes() {
      const m = sdModelConfig();
      if (!m || !m.supports_res) return '';
      const sel = document.getElementById('sd-res').value;
      if (sel === 'custom') {
        const v = (document.getElementById('sd-res-custom-val').value || '').trim();
        return v;
      }
      return sel; // '' (square) or a fixed "WxH"
    }

    sdLoadModels();

    function sdStart() {
      const prompt = document.getElementById('sd-prompt').value.trim();
      if (!prompt) { sdShowStatus('err', 'Please enter a prompt.'); return; }
      const model = sdModel ? sdModel.id : 'sdxl_turbo';
      const steps = parseInt(sdStepsEl.value, 10);
      const seedRaw = document.getElementById('sd-seed').value.trim();
      const res = sdGetRes();

      sdShowStatus('', '');
      sdResult.classList.remove('visible');
      sdProgress.classList.add('visible');
      sdProgressFill.style.width = '0%';
      sdProgressText.textContent = 'Starting generation…';
      sdGenerateBtn.disabled = true;
      sdDoneShown = null;

      fetch('/sd/generate', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ prompt, model, steps, seed: seedRaw || 'random', res: res || '' })
      }).then(r => r.json()).then(d => {
        if (!d.ok) {
          sdShowStatus('err', d.error || 'Failed to start');
          sdGenerateBtn.disabled = false;
        }
      }).catch(err => {
        sdShowStatus('err', String(err));
        sdGenerateBtn.disabled = false;
      });

      sdPoll(false);
    }

    function sdShowStatus(cls, msg) {
      sdStatus.className = 'status-bar' + (cls ? ' ' + cls : '');
      sdStatus.textContent = msg || '';
    }

    function sdPoll(immediate) {
      if (sdPollTimer) { clearInterval(sdPollTimer); sdPollTimer = null; }
      const tick = () => {
        fetch('/sd/status').then(r => r.json()).then(s => {
          if (s.running) {
            const pct = s.total_steps ? Math.round(100 * s.current_step / s.total_steps) : 0;
            sdProgressFill.style.width = pct + '%';
            sdProgressText.textContent = `Step ${s.current_step}/${s.total_steps} · ${pct}%`;
            const mLabel = (sdModel && sdModel.label) || s.model || 'SDXL Turbo';
            sdShowStatus('', `Generating (${mLabel}): "${s.prompt}"`);
          } else if (s.phase === 'done') {
            sdProgressFill.style.width = '100%';
            sdProgressText.textContent = `Done in ${Math.round(s.elapsed || 0)} s`;
            sdShowStatus('ok', '✅ Done!');
            sdGenerateBtn.disabled = false;
            loadSdGallery();
            if (s.output && s.output !== sdDoneShown) {
              sdDoneShown = s.output;
              const url = '/sd/latest?t=' + Date.now();
              sdResultImg.src = url;
              sdResultLink.href = '/sd/latest?t=' + Date.now();
              sdResult.classList.add('visible');
            }
            sdPollTimer && clearInterval(sdPollTimer);
            sdPollTimer = null;
          } else if (s.phase === 'error') {
            sdShowStatus('err', '❌ ' + (s.error || 'Error'));
            sdGenerateBtn.disabled = false;
            sdPollTimer && clearInterval(sdPollTimer);
            sdPollTimer = null;
          } else if (s.phase === 'idle') {
            // only reset the button if a fresh idle follows our run
            sdGenerateBtn.disabled = false;
          }
        }).catch(() => {});
      };
      if (immediate) tick();
      sdPollTimer = setInterval(tick, 2000);
    }

    // poll once on load to restore state after page refresh
    sdPoll(true);

    // Load upload gallery on page open
    loadUploadGallery(false);

    // Clear canvas on load
    clearCanvas();
  </script>
</body>

</html>
INDEX_HTML_EOF

chmod 755 "$APP_DIR/app.py"
chown -R "$USER_NAME:$USER_NAME" "$APP_DIR"

# ── 5. Stable Diffusion: build OnnxStream + download model(s) ────────────────
# Layout (matches the running app):
#   $USER_HOME/onnxstream/OnnxStream/src/build/sd   -> the generator binary
#   $USER_HOME/onnxstream/models-sdxl-turbo/        -> SDXL-Turbo 1.0 ONNX (~9.3 GB, only model)
# The `sd` binary links only libc/libstdc++/libm/libgcc (XNNPACK is static),
# so no extra runtime libraries are needed once it is built.
SD_ROOT="$USER_HOME/onnxstream"
SD_SRC="$SD_ROOT/OnnxStream"
SD_BIN="$SD_SRC/src/build/sd"
MODEL_XL_DIR="$SD_ROOT/models-sdxl-turbo"
MODEL_XL_REPO="https://huggingface.co/vitoplantamura/stable-diffusion-xl-turbo-1.0-anyshape-onnxstream"
ONNX_REPO="https://github.com/vitoplantamura/OnnxStream.git"

if [ -n "$SKIP_SD" ]; then
  echo "==> [5/7] Stable Diffusion: SKIPPED (--skip-sd)"
else
  echo "==> [5/7] Stable Diffusion: building OnnxStream + downloading model(s) ..."
  echo "    (the build and the ~9.3 GB model download run in parallel; a live"
  echo "     progress bar is shown below)"
  mkdir -p "$SD_ROOT"
  chown "$USER_NAME:$USER_NAME" "$SD_ROOT"

  # -- model-download progress bar ---------------------------------------------
  # git-lfs writes its own progress to a log (not the terminal), so we render
  # our own bar from a format-agnostic, version-proof signal: the bytes actually
  # downloaded into the model dir (du -sb of the LFS cache / working tree), which
  # grows monotonically. Totals are fixed for the pinned model sets and equal the
  # on-disk working-tree size, so the bar lands on 100% exactly at completion.
  MB=1048576
  SDXL_TOTAL=$(( 8844 * MB ))   # ~9.3 GiB SDXL-Turbo 1.0 working tree
  DL_IS_TTY=1
  [ -t 1 ] || DL_IS_TTY=0

  dl_bytes() {  # $1=model dir -> bytes downloaded so far (0 if none yet)
    local d="$1" b=""
    if [ -d "$d/.git/lfs" ]; then
      b=$(du -sb "$d/.git/lfs" 2>/dev/null | cut -f1)
    elif [ -d "$d" ]; then
      b=$(du -sb "$d" 2>/dev/null | cut -f1)
    fi
    case "$b" in (''|*[!0-9]*) echo 0 ;; (*) echo "$b" ;; esac
  }
  dl_human() {  # bytes -> "5.78 GiB"
    local b="${1:-0}"
    awk -v b="$b" 'BEGIN{split("B KiB MiB GiB TiB",U," ");v=b;i=0;
      while(v>=1024 && i<4){v/=1024;i++}
      if(v<10) printf "%.2f %s",v,U[i+1]; else printf "%.1f %s",v,U[i+1]}'
  }
  dl_rate() {  # $1=bytes, $2=seconds -> "1.2 MB/s"
    local b="${1:-0}" s="${2:-0}"
    awk -v b="$b" -v s="$s" 'BEGIN{ if(s<=0||b<0){print "-";exit}
      v=b/s; split("B/s KB/s MB/s GB/s",U," ");i=0;
      while(v>=1000 && i<3){v/=1000;i++}
      if(v<10) printf "%.1f %s",v,U[i+1]; else printf "%.0f %s",v,U[i+1]}'
  }
  dl_bar() {  # $1=percent -> 24-char bar
    local pct="${1:-0}" width=24 filled=0 i out=""
    [ "$pct" -gt 100 ] && pct=100
    [ "$pct" -lt 0 ] && pct=0
    filled=$(( pct * width / 100 ))
    for ((i=0;i<width;i++)); do
      if [ "$i" -lt "$filled" ]; then out="${out}#"; else out="${out}-"; fi
    done
    printf '%s' "$out"
  }

  # -- 5a. Start the model download (background; ~9.3 GB via git-lfs) ----------
  # MUST be `git lfs clone` (runs `git lfs install` + fetches LFS objects). A
  # plain `git clone` leaves ~130-byte pointer STUBS in place of the real *.bin
  # tensors, which would make the model "present" but unloadable at runtime.
  DL_XL_PID=""
  if [ -n "$SKIP_SDXL" ]; then
    echo "    SDXL-Turbo models: SKIPPED (--skip-sdxl)"
  elif [ -d "$MODEL_XL_DIR/sdxl_unet_anyshape_fp16" ] && \
       [ -n "$(find "$MODEL_XL_DIR/sdxl_unet_anyshape_fp16" -maxdepth 1 -name '*.bin' -size +10k -print -quit 2>/dev/null)" ]; then
    echo "    SDXL-Turbo models already present — skipping download."
  else
    rm -rf "$MODEL_XL_DIR" 2>/dev/null || true
    sudo -u "$USER_NAME" bash -lc \
      "git lfs install >/dev/null 2>&1; git lfs clone --depth=1 $MODEL_XL_REPO $MODEL_XL_DIR" \
      > "$SD_ROOT/model_download_xl.log" 2>&1 &
    DL_XL_PID=$!
  fi

  # -- 5b. Start the OnnxStream build (background; XNNPACK fetched by CMake) ----
  BUILD_PID=""
  if [ -x "$SD_BIN" ]; then
    echo "    OnnxStream 'sd' binary already present — skipping build."
  else
    rm -f "$SD_ROOT/build.done"
    if [ ! -d "$SD_SRC/.git" ]; then
      sudo -u "$USER_NAME" git clone --depth=1 "$ONNX_REPO" "$SD_SRC" \
        > "$SD_ROOT/build.log" 2>&1
    fi
    sudo -u "$USER_NAME" bash -lc \
      "cd $SD_SRC/src && mkdir -p build && cd build \
       && cmake -DCMAKE_BUILD_TYPE=Release .. \
       && cmake --build . --config Release -j \$(nproc); rc=\$?; touch $SD_ROOT/build.done; exit \$rc" \
      >> "$SD_ROOT/build.log" 2>&1 &
    BUILD_PID=$!
  fi

  # -- 5c. Live progress display: poll the build + download -------------------
  # Everything long (build ~minutes, download ~9.3 GB) runs in the background, so
  # we show a single live line that fills in as bytes hit the disk. In a terminal
  # it redraws in place; under CI/log it prints one line per poll.
  if [ -n "$BUILD_PID" ] || [ -n "$DL_XL_PID" ]; then
    DL_ELAPSED=0; DL_T0=$SECONDS
    XL_B=0; XL_BP=""
    while :; do
      sleep 1
      DL_ELAPSED=$(( SECONDS - DL_T0 ))
      XL_B=$(dl_bytes "$MODEL_XL_DIR")
      XL_PCT=$(( XL_B * 100 / SDXL_TOTAL )); [ "$XL_PCT" -gt 100 ] && XL_PCT=100
      if [ -n "$DL_XL_PID" ] && [ "$XL_B" -ge "${XL_BP:-0}" ] && [ "$XL_PCT" -lt 100 ]; then
        XL_SP=$(dl_rate $(( XL_B - ${XL_BP:-0} )) 1); XL_BP="$XL_B"
      else XL_SP="-"; fi
      if [ -n "$BUILD_PID" ] && kill -0 "$BUILD_PID" 2>/dev/null; then B_STAT="building OnnxStream …"; else B_STAT="build done"; fi
      line="    SDXL-Turbo  [$(dl_bar "$XL_PCT") ${XL_PCT}%] $(dl_human "$XL_B") / $(dl_human "$SDXL_TOTAL")  ${XL_SP}  ·  ${B_STAT}"
      if [ "$DL_IS_TTY" -eq 1 ]; then
        printf '\r\033[K%s' "$line"
      else
        echo "$line"
      fi
      b_done=1; [ -n "$BUILD_PID" ] && kill -0 "$BUILD_PID" 2>/dev/null && b_done=0
      d_done=1; [ -n "$DL_XL_PID" ] && kill -0 "$DL_XL_PID" 2>/dev/null && d_done=0
      [ "$b_done" -eq 1 ] && [ "$d_done" -eq 1 ] && break
    done
    [ "$DL_IS_TTY" -eq 1 ] && printf '\r\033[K'
    echo "    Done in ${DL_ELAPSED}s."
  fi

  # -- 5d. Wait for the background jobs and check their exit codes --------------
  if [ -n "$BUILD_PID" ]; then
    wait "$BUILD_PID"; BUILD_RC=$?
    if [ "$BUILD_RC" -ne 0 ]; then
      echo "    ERROR: OnnxStream build failed (exit $BUILD_RC). Last lines of build.log:"
      tail -n 30 "$SD_ROOT/build.log" 2>/dev/null || true
      exit 1
    fi
  fi
  if [ -n "$DL_XL_PID" ]; then
    wait "$DL_XL_PID"; DL_XL_RC=$?
    if [ "$DL_XL_RC" -ne 0 ]; then
      echo "    ERROR: SDXL-Turbo model download failed (exit $DL_XL_RC). Last lines:"
      tail -n 30 "$SD_ROOT/model_download_xl.log" 2>/dev/null || true
      exit 1
    fi
  fi

  # -- 5e. Verify the build + model tensors, then reclaim disk ------------------
  if [ ! -x "$SD_BIN" ]; then
    echo "    ERROR: 'sd' binary not found at $SD_BIN after build."
    tail -n 30 "$SD_ROOT/build.log" 2>/dev/null || true
    exit 1
  fi
  # Verify the model tensors are real (not ~130-byte LFS pointer stubs).
  # model.txt must be a real graph (KB-sized) and at least one large .bin must exist.
  if [ -z "$SKIP_SDXL" ] && [ -d "$MODEL_XL_DIR" ] && \
     { [ ! -s "$MODEL_XL_DIR/sdxl_unet_anyshape_fp16/model.txt" ] || \
       [ -z "$(find "$MODEL_XL_DIR/sdxl_unet_anyshape_fp16" -maxdepth 1 -name '*.bin' -size +100k -print -quit 2>/dev/null)" ]; }; then
    echo "    ERROR: SDXL-Turbo models look incomplete (LFS pointers, not real tensors)."
    tail -n 30 "$SD_ROOT/model_download_xl.log" 2>/dev/null || true
    exit 1
  fi
  # Reclaim disk: `git lfs clone` keeps a second copy of every blob under
  # <dir>/.git (a ~9 GB duplicate for SDXL-Turbo). Once the tensors are in the
  # working tree the model dir is read-only data — drop the .git so a fresh
  # flash doesn't pay twice for the same bytes.
  for MD in "$MODEL_XL_DIR"; do
    if [ -d "$MD/.git" ]; then
      echo "    Reclaiming .git store in $MD (keeps working tree only) ..."
      sudo -u "$USER_NAME" rm -rf "$MD/.git"
    fi
  done
  echo "    SD binary  : $SD_BIN"
  if [ -d "$MODEL_XL_DIR" ]; then
    echo "    SDXL models: $MODEL_XL_DIR ($(du -sh "$MODEL_XL_DIR" 2>/dev/null | cut -f1 || echo '?'))"
  fi
fi

# ── 6. systemd service ───────────────────────────────────────────────────────
echo "==> [6/7] Installing systemd unit oled-web.service ..."
cat > /etc/systemd/system/oled-web.service <<UNIT_EOF
[Unit]
Description=OLED Web Controller (Flask :5000)
After=network.target
Wants=network.target

[Service]
User=$USER_NAME
WorkingDirectory=$APP_DIR
ExecStart=$PYTHON_BIN $APP_DIR/app.py
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT_EOF

systemctl daemon-reload
systemctl enable oled-web

# ── 7. I2C sanity + start ────────────────────────────────────────────────────
echo "==> [7/7] I2C sanity check + starting service ..."
if [ -e "/dev/i2c-$BUS" ]; then
  echo "    OK: /dev/i2c-$BUS present. Devices on the bus:"
  /usr/sbin/i2cdetect -y "$BUS" 2>/dev/null | sed 's/^/      /' || true
  systemctl restart oled-web
  sleep 2
  if systemctl is-active oled-web >/dev/null; then
    echo "    oled-web is RUNNING"
  else
    echo "    oled-web did not start. Recent log:"
    journalctl -u oled-web -n 15 --no-pager || true
  fi
else
  echo "    /dev/i2c-$BUS is not present yet. On a Pi 5 / freshly flashed Pi the"
  echo "    firmware I2C controller (bus $BUS) is created at boot, so a reboot is"
  echo "    needed before the OLED can be opened."
  if [ -n "$REBOOT" ] || [ "$CONFIG_CHANGED" -eq 1 ]; then
    echo "    Rebooting now (config changed / --reboot). After boot the service"
    echo "    starts automatically on :5000."
    systemctl enable oled-web >/dev/null 2>&1
    reboot
    exit 0
  else
    echo "    Reboot when ready to bring the OLED up:"
    echo "        sudo reboot"
  fi
fi

# ── done ─────────────────────────────────────────────────────────────────────
cat <<DONE
══════════════════════════════════════════════════════════════════════
  Done. OLED-App$( [ -n "$SKIP_SD" ] || echo " + Stable Diffusion (SDXL-Turbo)" ) installed for user '$USER_NAME'.

    Web UI    : http://<pi-ip>:5000
    OLED      : SSD1306 128x64, I2C bus $BUS @ 0x3C
    Wallpaper : enabled (lightdm + labwc + pcmanfm-pi)
$( [ -n "$SKIP_SD" ] || printf '    SD        : OnnxStream `sd` + SDXL-Turbo models under %s/onnxstream/\n' "$USER_HOME" )
  The service is enabled and starts automatically at boot.
$( [ "$CONFIG_CHANGED" -eq 1 ] && echo "  NOTE: config.txt was changed, so a REBOOT is required" && echo "       before the OLED node (/dev/i2c-$BUS) exists and the app works." )
  Verify (after reboot, if it rebooted):
      systemctl status oled-web
      journalctl -u oled-web -n 20 --no-pager
      curl http://localhost:5000
$( [ -n "$SKIP_SD" ] || printf "      ls $USER_HOME/onnxstream/models-sdxl-turbo\n" )
══════════════════════════════════════════════════════════════════════
DONE
