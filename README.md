# displaycameras (modern) — RTSP camera video wall for Raspberry Pi 4

A faithful, modernized rewrite of
[Anonymousdog/displaycameras](https://github.com/Anonymousdog/displaycameras)
that runs on a **Raspberry Pi 4** with the **latest Raspberry Pi OS (Bookworm)**.

It displays a grid of RTSP/IP-camera feeds full-screen on an attached display,
keeps them alive, and can rotate through more cameras than there are tiles.

---

## Why a rewrite?

The original project is excellent but built on a stack that **no longer exists**
on the Pi 4 / Bookworm:

- **`omxplayer`** was removed after Buster. It drew each camera as an
  independent hardware **dispmanx** overlay with no display server needed.
  Dispmanx is gone on the Pi 4's KMS/DRM graphics pipeline.
- Screen blanking used the **framebuffer** viewer `fbi`; control and monitoring
  used **`omxplayer`'s D-Bus** interface.
- Setup tuned the legacy **`gpu_mem`** split and **overscan** via `raspi-config`.

This port keeps the same command-line verbs and config file format, but swaps
the engine for tools that are current on Bookworm:

| Original | This port |
| --- | --- |
| one `omxplayer` per camera on dispmanx | one **`mpv`** per tile, composited by a minimal **X11 + Openbox** kiosk session |
| hardware decode via MMAL | hardware decode via **V4L2 M2M** (`--hwdec`) on the Pi 4 VideoCore |
| D-Bus control (`omxplayer_dbuscontrol`) | **mpv JSON IPC** socket (`displaycameras-ipc`) |
| `fbi` + `black.png` blanking | black X root window |
| `cron` repair + `rotatedisplays` loop | one in-session **`supervise`** loop |
| `gpu_mem` split + overscan tweaks | **CMA** pool sizing in `config.txt` |
| rotation moves windows across off-screen tiles | rotation **reloads feeds into fixed tiles** (no off-screen windows needed) |

---

## Requirements

- Raspberry Pi 4 (or 400/CM4).
- Raspberry Pi OS **Bookworm**, 64-bit recommended. The **Lite** image is ideal
  (this project brings its own minimal X session); the Desktop image also works.
- One or more RTSP-capable cameras/NVR. Prefer each camera's **low-resolution
  substream** — the Pi 4 has a single shared hardware video decoder, so lower
  resolutions let you show more feeds at once.

Dependencies installed automatically by `install.sh`: `mpv`, `xserver-xorg`,
`xinit`, `x11-xserver-utils`, `openbox`, `unclutter`, `python3`.

---

## Install

```bash
git clone <this-repo>
cd displaycameras-modern
sudo ./install.sh            # or: sudo ./install.sh --user myuser
```

The installer:

1. installs dependencies and adds the kiosk user to the `video`, `render`,
   `input`, and `tty` groups;
2. copies `displaycameras`, `displaycameras-ipc`, `displaycameras-session` to
   `/usr/local/bin`;
3. writes starter config to `/etc/displaycameras/` (backing up anything there);
4. allows Xorg to start from the service (`/etc/X11/Xwrapper.config`);
5. installs and enables the `displaycameras` systemd service;
6. optionally appends recommended CMA/KMS lines to your `config.txt`.

Then edit your feeds and (re)start:

```bash
sudo nano /etc/displaycameras/layout.conf.default
sudo systemctl restart displaycameras
```

To upgrade the code later without touching your config:
`sudo ./install.sh --upgrade`. To remove it: `sudo ./uninstall.sh [--purge]`.

---

## Configuration

Two files in `/etc/displaycameras/`, matching the original layout:

### `displaycameras.conf` — global options

Screen blanking, network timeout, hardware-decode mode, how feeds fill each
tile (`letterbox`/`stretch`/`crop`), repair interval, rotation dwell time, and
optional resolution autodetection. Every option is documented inline in the
file (see [`config/displaycameras.conf.example`](config/displaycameras.conf.example)).

### `layout.conf.default` — tiles and feeds

Four bash arrays, **compatible with the original format**:

```bash
windows=(upper_left upper_right lower_left lower_right)

# "X1 Y1 X2 Y2" pixel rectangles (top-left .. bottom-right)
window_positions=(
	"0 0 959 539"        \
	"960 0 1919 539"     \
	"0 540 959 1079"     \
	"960 540 1919 1079"  \
)

camera_names=(Front Back Drive Yard)

camera_feeds=(
	"rtsp://user:pass@192.168.1.11:554/stream2"  \
	"rtsp://user:pass@192.168.1.12:554/stream2"  \
	"rtsp://user:pass@192.168.1.13:554/stream2"  \
	"rtsp://user:pass@192.168.1.14:554/stream2"  \
)

rotate="true"   # optional: cycle feeds through the tiles
```

More ready-made layouts are in [`config/layouts/`](config/layouts) (3x3 and 1x1
on 1080p, 2x2 on 720p). Copy one to `/etc/displaycameras/layout.conf.default`,
or, with `displaydetect=true`, name it `layout.conf.<WxH>` (e.g.
`layout.conf.1920x1080`) and it is auto-selected by screen resolution.

**Rotation:** unlike the original you do **not** create off-screen windows.
List only the tiles you can see; if you define more cameras than tiles and set
`rotate="true"`, the camera list cycles through the fixed tiles every
`rotatedelay` seconds.

---

## Usage

The systemd service runs the wall at boot. For manual control, run as the
kiosk user (the mpv IPC sockets live in `/run/displaycameras`):

```bash
displaycameras status       # per-tile playing / not playing
displaycameras positions    # per-tile playback time
displaycameras rotate       # advance the rotation one step
displaycameras repair       # reconnect any stalled/dead tile
sudo systemctl restart displaycameras
```

Verbs: `start | stop | restart | repair | status | positions | rotate |
rotaterev | supervise`. (`supervise` is the foreground loop the session runs;
you normally don't call it directly.)

---

## How it fits together

```
systemd (displaycameras.service)
  └─ xinit … displaycameras-session   (a bare X server on tty1/:0)
        ├─ xset/xsetroot/unclutter    (no blanking, black bg, no cursor)
        ├─ openbox                    (decorationless WM so --geometry sticks)
        └─ displaycameras start       (spawns one mpv per tile)
             └─ displaycameras supervise   (repairs + rotates on an interval)

control/monitoring: displaycameras  ──JSON IPC──▶  each mpv tile socket
                                    (displaycameras-ipc)
```

---

## Tuning & troubleshooting

- **Only a few feeds decode / high CPU.** The Pi 4 has one hardware H.264
  decoder shared across all tiles. Use low-res substreams, raise the CMA pool
  (`dtoverlay=vc4-kms-v3d,cma-256` in `config.txt`), and keep `hwdec=auto-safe`.
  For many small tiles, `hwdec=drm-prime` can lower CPU further.
- **Tiles aren't positioned exactly.** Openbox must be running (it is, in the
  session) so mpv `--geometry` is honored. Check `journalctl -u displaycameras`.
- **A feed won't connect.** Test it directly on the Pi:
  `mpv --rtsp-transport=tcp "rtsp://…"`. Confirm the URL, credentials, and that
  TCP transport is used (many cameras drop UDP over Wi-Fi).
- **Black screen at boot.** Ensure `dtoverlay=vc4-kms-v3d` is in `config.txt`
  and the kiosk user is in the `video`/`render` groups (the installer does
  this — re-login or reboot after first install).
- **Service logs:** `journalctl -u displaycameras -b`.

### Dual-HDMI walls (Pi 4)

The Pi 4 has two HDMI outputs. Arrange them into one X screen with `xrandr`
(e.g. place `HDMI-2` to the right of `HDMI-1`), then give tiles coordinates in
that combined space (the second display starts at `X = width_of_first`). A
per-output `xrandr` layout step can be added to `displaycameras-session`.

---

## Credit & license

Original concept and configuration design:
[Anonymousdog/displaycameras](https://github.com/Anonymousdog/displaycameras).
This modernized port preserves that project's CLI and config conventions.
