# OLED Pixel-Paint + Stable Diffusion on Raspberry Pi

A web app for Raspberry Pi that drives an **SSD1306 128×64 I2C OLED** and
generates images with **Stable Diffusion (SDXL-Turbo)** running entirely on
the Pi's CPU via [OnnxStream](https://github.com/vitoplantamura/OnnxStream).

One script installs everything on a fresh Raspberry Pi OS flash: OS packages,
pinned Python deps, the app, the compiled OnnxStream `sd` binary, the ~9.3 GB
SDXL-Turbo ONNX model set (with a live download progress bar), and a systemd
service.

UI is fully English. Tabs: **Pixel Paint · Upload Image · Stable Diffusion**.

## Highlights

- **Single model** — SDXL-Turbo 1.0
  (`--xl --turbo --ram`); 4 steps by default.
- **Any aspect ratio** — square, 4:3, 16:9, 3:2, 21:9 (`--res WxH`,
  multiples of 8).
- **One-file UI** — the entire web front end is a single `index.html`.
- **Idempotent installer** — re-runnable; completed parts are skipped.
- **No vendor lock-in** — plain Flask + luma.oled, MIT-licensed code.

## Built on / model weights

| Component | Role | License |
|---|---|---|
| [OnnxStream](https://github.com/vitoplantamura/OnnxStream) | CPU SD engine | MIT |
| [SDXL-Turbo ONNX weights](https://huggingface.co/vitoplantamura/stable-diffusion-xl-turbo-1.0-anyshape-onnxstream) | Model (downloaded at install, not bundled) | Stability AI SDXL-Turbo license (non-commercial/research; see [THIRD_PARTY.md](THIRD_PARTY.md)) |
| [Flask](https://flask.palletsprojects.com/) / [Pillow](https://python-pillow.org/) / [luma.oled](https://luma-oled.readthedocs.io/) | App runtime | BSD-3 / MIT / MIT |

Full third-party rights and links: **[THIRD_PARTY.md](THIRD_PARTY.md)**.

## License

Code in this repository: **MIT** — see [LICENSE](LICENSE).
The SDXL-Turbo *model weights* are governed by Stability AI's license
(non-commercial/research use) and are fetched from the upstream Hugging Face
repo at install time; this repository does not redistribute them.

---

## What the installer does

| Step | Action |
|------|--------|
| 1 | Installs OS packages: `i2c-tools`, `python3-smbus`, `python3-pil`, `python3-pip`, `lightdm`, `labwc`, `pcmanfm-pi` |
| 2 | Enables the firmware I2C mux in `config.txt` (correct dtparam for Pi 4 vs Pi 5), adds the app user to the `i2c` group, ensures `i2c_dev` kernel module loads at boot |
| 3 | Installs pinned Python deps into the target user's site: `luma.oled==3.15.0`, `luma.core==2.5.3`, `Flask==3.1.3`, `Pillow==10.4.0` |
| 4 | Writes the app to `<home>/oled-web/` (`app.py` + `templates/index.html`) |
| 5 | Compiles **OnnxStream** and downloads the **SDXL-Turbo** models (~9.3 GB) in parallel, with a **live download progress bar** |
| 6 | Writes and enables `oled-web.service` (systemd, port 5000, auto-starts at boot) |
| 7 | Sanity-checks I2C, starts the service, reboots if the firmware config changed |

> The download progress bar measures the bytes actually written to the model
> directory's LFS cache, so it is correct regardless of `git-lfs` version and
> works both in an interactive terminal (in-place line) and in logged output
> (one line per second).

---

## Requirements

- **Raspberry Pi OS** (Bookworm or Trixie), any Pi with I2C (Pi 4 or Pi 5)
- **A target user account that already exists** (default: `sysadmin`) — see below
- **SSD1306 128×64 I2C OLED** wired to the Pi's I2C header:
  - SDA → pin 3, SCL → pin 5, VCC → pin 1 (3.3 V), GND → pin 6
  - I2C address `0x3C`, bus `1` (default; see `--bus` below)
- **Internet** during install (apt + pip + the model download)
- **Disk space** — see below

### Disk space

The model download peaks at roughly **2× the model size** while in flight
(LFS cache + working-tree copies) and then drops to the final size after the
`.git` cleanup:

| What | Size |
|------|------|
| SDXL-Turbo model (final) | ~9.3 GB |
| Peak during download | ~18 GB |
| OnnxStream source + build | ~1–2 GB |
| OS + Python deps | ~2 GB |

A **32 GB** microSD card is the minimum; 64 GB or larger is comfortable.

---

## Installation

### 1. Prepare the target user (fresh flash)

The installer expects the target user to **already exist** (it writes the app
to that user's home and runs the service as them). On a fresh Raspberry Pi OS
flash only the default user (`pi`, or whatever you named it) exists, so you
must create the user first.

To match the default (and this README's examples), create `sysadmin`:

```bash
adduser sysadmin
sudo usermod -aG sudo sysadmin     # so it can sudo later
```

(Or skip this and pass `--user pi` / `--user <your-user>` at install time —
the app just lives under that user's home instead.)

### 2. Run the installer

```bash
# Copy install_oled_app.sh to the Pi, then:
sudo bash install_oled_app.sh
```

This uses the default user `sysadmin`. Recommended on a fresh flash so the
I2C config change takes effect at the first boot.

### Flags

| Flag | Default | Effect |
|------|---------|--------|
| `--user <name>` | `sysadmin` | Target user (must already exist) |
| `--bus <n>` | `1` | I2C bus number |
| `--reboot` | off | Force a reboot at the end even if config did not change |
| `--skip-sd` | off | Skip the whole Stable Diffusion build + download |
| `--skip-sdxl` | off | Skip just the SDXL-Turbo model download |

### After install

1. If the script reboots, wait for the Pi to come back (~30 s).
2. Open the web UI: **`http://<pi-ip>:5000`**
3. The OLED should display the startup (blank) frame.

---

## What the app does

- **Pixel Paint** — a 128×64 pixel canvas you draw on; push to the OLED with
  *Send to Display*.
- **Upload Image** — upload an image, set a brightness threshold, send it to
  the OLED.
- **Stable Diffusion** — text-to-image via OnnxStream (`sd`). Single live
  model, **SDXL-Turbo 1.0** in Fast mode (`--xl --turbo --ram`). Non-square
  resolutions work (`--res WxH`, multiples of 8); default **896×512**, 4 steps.
  Generated images appear in the in-page gallery.

---

## Files created

| Path | Purpose |
|------|---------|
| `<home>/oled-web/app.py` | Flask application (pixel canvas, I2C OLED driver, SD worker) |
| `<home>/oled-web/templates/index.html` | Browser UI — single file (HTML + CSS + JS) |
| `<home>/oled-web/sd-output/` | Generated SD images |
| `<home>/onnxstream/OnnxStream/` | Cloned + built OnnxStream (the `sd` binary lives in `src/build/`) |
| `<home>/onnxstream/models-sdxl-turbo/` | SDXL-Turbo 1.0 ONNX models (~9.3 GB) |
| `/etc/systemd/system/oled-web.service` | systemd unit — runs the app at boot, port 5000 |
| `/boot/firmware/config.txt.bak-oled` | Backup of `config.txt` before the dtparam was added |

---

## Systemd service

```ini
[Unit]
Description=OLED Web Controller (Flask :5000)
After=network.target
Wants=network.target

[Service]
User=sysadmin
WorkingDirectory=/home/sysadmin/oled-web
ExecStart=/usr/bin/python3 /home/sysadmin/oled-web/app.py
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
```

Common management:

```bash
sudo systemctl status  oled-web
sudo systemctl restart oled-web
sudo systemctl stop    oled-web
sudo journalctl -u oled-web -f    # live log
```

---
Tested on a Raspberry Pi 5 (8 GB) in a Pironman5 case (with OLED) on Raspberry Pi OS (Trixie).

