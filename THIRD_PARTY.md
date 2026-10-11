# Third-Party Components

This project is built on the components below. Their code is **not**
vendored in this repository — the installer fetches them at install time
from the upstream locations. Each component's own license applies to that
component.

| Component | Used for | License | Upstream |
|---|---|---|---|
| [OnnxStream](https://github.com/vitoplantamura/OnnxStream) | CPU Stable Diffusion engine (ONNX Runtime, SDXL Turbo, `--xl --turbo --ram`) | MIT | <https://github.com/vitoplantamura/OnnxStream> |
| [SDXL Turbo ONNX weights](https://huggingface.co/vitoplantamura/stable-diffusion-xl-turbo-1.0-anyshape-onnxstream) | ~9.3 GB model set, downloaded via `git lfs clone` during install | Stability AI SDXL-Turbo license (see below) | <https://huggingface.co/vitoplantamura/stable-diffusion-xl-turbo-1.0-anyshape-onnxstream> |
| [Flask](https://flask.palletsprojects.com/) | Web server (`app.py`, pinned 3.1.3) | BSD-3 | <https://github.com/pallets/flask> |
| [Pillow](https://python-pillow.org/) | Image manipulation (`img2bmp`, resizing, JPEG/PNG output; pinned 10.4.0) | MIT-CMU / HPND | <https://github.com/python-pillow/Pillow> |
| [Luma.OLED / Luma.Core](https://luma-oled.readthedocs.io/) | SSD1306 OLED driver (pinned 3.15.0 / 2.5.3) | MIT | <https://github.com/timwolla/luma.oled>, <https://github.com/timwolla/luma.core> |
| [git-lfs](https://git-lfs.com/) | Model weight transfer during install | MIT | <https://github.com/git-lfs/git-lfs> |
| [Raspberry Pi OS (Debian 13 trixie)](https://www.raspberrypi.com/software/) | Target OS | Debian Free Software License (OS) / various | <https://www.raspberrypi.com/> |

## Model weights — Stability AI SDXL-Turbo license

The SDXL Turbo weights are **not** redistributed by this repository; the
installer clones them from the upstream Hugging Face repository at install
time. The weights are governed by Stability AI's license for SDXL Turbo
(derived from the Stability AI Model License 1.0 / OpenRAIL family):

- **Non-commercial / research use** is the primary permitted use.
- Stability AI's **Acceptable Use Policy** applies (prohibited uses, e.g.
  generating CSAM or non-consensual intimate imagery).
- The full license text is in the upstream weight repository
  (`LICENSE` file) and on Stability AI's site.

If you plan to use generated images commercially, review that license
before doing so. The *code* in this repository is MIT-licensed and
unrestricted; the restriction lives in the *weights*.
