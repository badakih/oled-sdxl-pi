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
