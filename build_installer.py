#!/usr/bin/env python3
"""
Build a single self-contained installer (install_oled_app.sh) that reproduces
the piki OLED-App — including the Stable Diffusion backend — on a fresh
Raspberry Pi OS (Bookworm / Trixie).

Embeds byte-faithful copies of app.py and templates/index.html as quoted
heredocs, plus the OS-driver / I2C / pip / systemd logic, and adds a Stable
Diffusion step that:
    • installs the OnnxStream build toolchain (build-essential, git, cmake,
      git-lfs, curl, ca-certificates)
    • builds the `sd` example binary (XNNPACK auto-downloaded by CMake)
    • downloads the SDXL-Turbo 1.0 ONNX model set (HuggingFace LFS, ~9.3 GB)

The model download runs in the background while OnnxStream compiles, so the
two long steps overlap. Progress is rendered live from the bytes on disk.

Run:
    python build_installer.py [--user sysadmin] [--bus 1] [--out install_oled_app.sh]

Then copy install_oled_app.sh to the target Pi and:
    sudo bash install_oled_app.sh                 # full install incl. SDXL-Turbo
    sudo bash install_oled_app.sh --skip-sd       # OLED app only (no Stable Diffusion)
    sudo bash install_oled_app.sh --skip-sdxl     # build OnnxStream, skip the SDXL-Turbo model
    sudo bash install_oled_app.sh --user alice    # different user

Reference build: Raspberry Pi 5 (BCM2712, 8 GB), SSD1306 128x64 I2C bus 1 @ 0x3C,
Debian 13 (trixie). OnnxStream commit d60b6e1, SDXL-Turbo 1.0 ONNX repo
vitoplantamura/stable-diffusion-xl-turbo-1.0-anyshape-onnxstream.
"""
import argparse
from pathlib import Path

HERE = Path(__file__).resolve().parent

BANNER = (
    "# ─────────────────────────────────────────────────────────────────────────────\n"
    "#  OLED SSD1306 Web Controller + Stable Diffusion — one-shot installer\n"
    "#\n"
    "#  Reproducibly installs, on a fresh Raspberry Pi OS (Bookworm / Trixie):\n"
    "#    • OS drivers: I2C stack (i2c-tools, python3-smbus), PIL, desktop\n"
    "#    • I2C enabled in the firmware (correct dtparam for Pi 4 vs Pi 5)\n"
    "#    • Python deps (pinned): luma.oled 3.15.0, luma.core 2.5.3,\n"
    "#                            Flask 3.1.3, Pillow 10.4.0\n"
    "#    • the app:  <user-home>/oled-web/  (app.py + templates/index.html)\n"
    "#    • Stable Diffusion: OnnxStream `sd` binary + SDXL-Turbo 1.0 ONNX models\n"
    "#      (live model-download progress bar, bytes on disk, tty-aware)\n"
    "#      (<user-home>/onnxstream/, ~9.3 GB)\n"
    "#    • a systemd service (auto-start) on port 5000\n"
    "#\n"
    "#  Usage:\n"
    "#      sudo bash install_oled_app.sh [--user sysadmin] [--bus 1] [--reboot] [--skip-sd] [--skip-sdxl]\n"
    "#        --reboot    reboot at the end (recommended on a fresh flash so the\n"
    "#                    firmware I2C node exists when the service starts at boot)\n"
    "#        --skip-sd   skip the Stable Diffusion build + model download\n"
    "#        --skip-sdxl  skip the SDXL-Turbo model download\n"
    "#\n"
    "#  After install (or a reboot if I2C needed to come up): open http://<pi-ip>:5000\n"
    "#\n"
    "#  Reference hardware: Raspberry Pi 5 (BCM2712), SSD1306 128x64 I2C bus 1 @ 0x3C\n"
    "# ─────────────────────────────────────────────────────────────────────────────\n"
)

# Plain (not f-) string. Bash is full of literal { } $( ) — keep it a raw template
# and substitute a few @@TOKENS@@ at the end.
TEMPLATE = r"""
set -euo pipefail

# ── args ─────────────────────────────────────────────────────────────────────
USER_NAME="@@DEFAULT_USER@@"
BUS="@@DEFAULT_BUS@@"
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
@@APP_PY@@
APP_PY_EOF

cat > "$APP_DIR/templates/index.html" <<'INDEX_HTML_EOF'
@@INDEX_HTML@@
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
"""


def read(name: str) -> str:
    p = HERE / name
    if not p.exists():
        raise SystemExit(f"missing source file: {p}")
    data = p.read_text().rstrip("\n")
    if "APP_PY_EOF" in data or "INDEX_HTML_EOF" in data:
        raise SystemExit(f"{name} contains a heredoc delimiter — cannot embed safely")
    return data


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    ap.add_argument("--user", default="sysadmin", help="Pi user that runs the app (default sysadmin)")
    ap.add_argument("--bus", type=int, default=1, help="I2C bus number the app uses (default 1)")
    ap.add_argument("--out", default=str(HERE / "install_oled_app.sh"), help="output installer path")
    a = ap.parse_args()

    app_py = read("app.py")
    index_html = read("index.html")

    # The shipped app.py hardcodes I2C_BUS = 1. If a different bus is requested,
    # rewrite only that line so the rest of the code stays byte-identical.
    if a.bus != 1:
        app_py = app_py.replace("I2C_BUS = 1", f"I2C_BUS = {a.bus}", 1)
        if f"I2C_BUS = {a.bus}" not in app_py:
            raise SystemExit("failed to patch I2C_BUS in app.py")

    script = BANNER + TEMPLATE
    script = script.replace("@@DEFAULT_USER@@", a.user)
    script = script.replace("@@DEFAULT_BUS@@", str(a.bus))
    script = script.replace("@@APP_PY@@", app_py)
    script = script.replace("@@INDEX_HTML@@", index_html)

    out = Path(a.out)
    # Force LF line endings — CRLF breaks the bash heredocs / set -o pipefail.
    out.write_bytes(script.replace("\r\n", "\n").replace("\r", "\n").encode("utf-8"))
    out.chmod(0o755)
    print(f"Wrote {out}  ({out.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
