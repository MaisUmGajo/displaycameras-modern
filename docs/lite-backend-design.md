# Design for review — legacy-board (`lite`) backend

Status: **implemented, pending hardware validation.** Code is in the repo
(`backend` in `bin/displaycameras`, `bin/displaycameras-run-drm`,
`systemd/displaycameras-drm.service`, lite config templates, install branching).
The `hwdec`/`--vo`/tty-handoff choices in §3 are still to be confirmed on a
real board via `docs/hardware-test-plan.md`.

Add support for low-power Raspberry Pi boards (Zero / Zero W / Pi 1) on a
**current** Raspberry Pi OS, by introducing a second render backend. The
existing Pi 4 behaviour is untouched.

---

## 1. Two backends, one config logic

A new global option `backend` in `displaycameras.conf`:

```
backend=auto      # auto | full | lite   (default: auto)
```

| | `full` (existing) | `lite` (new) |
|---|---|---|
| Display path | X11 + openbox + mpv tiles, xdotool reposition | **single mpv → KMS via `--vo=drm`**, no X, no WM |
| Layout | multi-tile grids, optional dual-HDMI | **one fullscreen camera** |
| Uses from config | windows, window_positions, window_outputs, dual_hdmi, all camera_* | **camera_names, camera_feeds, rotate, rotatedelay only** |
| Ignores | — | windows/window_positions/window_outputs/dual_hdmi/reposition/arrange-displays |
| Extra deps | xserver-xorg, xinit, openbox, xdotool, unclutter, x11-xserver-utils | none beyond mpv + python3 |
| systemd | `xinit` → `displaycameras-session` | runs directly on tty1 (no X) |

**Shared, identical across both:** the config file format, the IPC helper
(`displaycameras-ipc`), and the `start` / `stop` / `repair` / `rotate` /
`rotaterev` / `status` / `positions` / `supervise` verbs and their logic. The
lite backend is modelled as "exactly one fullscreen tile", so the existing
rotation logic (cycle the camera list through the tiles) works unchanged — it
just has one tile.

## 2. Auto-detection

At install time, and at runtime when `backend=auto`, decide from the board:

- Read `/proc/device-tree/model` (e.g. `Raspberry Pi Zero W`, `Raspberry Pi
  Model B Rev 2`, `Raspberry Pi 4 Model B`) and CPU arch (`uname -m` /
  `/proc/cpuinfo`).
- **Rules (v1):**
  - ARMv6 (`armv6l`) or model matches *Zero* / original Pi 1 (`Model A`/`Model
    B` without a 2/3/4/5) → **`lite`**.
  - Everything else → **`full`**.
- **Pi 2 / Pi 3:** default **`full`** for now — *marked tentative, to be
  confirmed on real hardware during the test session* (they are quad-core but
  still VideoCore IV, so a small grid may or may not be comfortable).
- Always overridable: an explicit `backend=full|lite` in the config wins, and
  `install.sh --backend <x>` forces it.

A `displaycameras --detect` helper will print the model, arch, and the backend
it would choose (used by test plan §1).

## 3. Lite runtime behaviour

- **`start`:** launch **one** mpv, fullscreen on KMS, showing the current
  camera (respecting the rotation offset). Sketch:
  ```
  mpv --no-config --input-ipc-server=/run/displaycameras/win-0.sock \
      --vo=drm --hwdec=<board default> --rtsp-transport=tcp --no-audio \
      --profile=low-latency --cache=no --network-timeout=$net_timeout \
      --idle=yes --keep-open=no --really-quiet -- "$url" &
  ```
  No geometry, no `--x11-name`, no window placement.
- **`rotate` / `rotaterev`:** `loadfile` the next camera into that one socket
  (same code path as full, just one tile).
- **`repair`:** relaunch if the mpv died, `loadfile` if idle/stalled.
- **`status` / `positions`:** as today, over IPC, one tile.
- **`supervise`:** unchanged loop (repair + optional rotate). `reposition` and
  `arrange-displays` become no-ops under `lite`.
- No openbox / unclutter / X. Console blanking is disabled by the runner.

Exact `hwdec` and `--vo` choice (e.g. `v4l2m2m-copy` vs `drm-prime`,
`--vo=drm` vs `--vo=gpu --gpu-context=drm`) are **decided from the §3/§4
hardware measurements** and then baked in as the lite defaults.

## 4. systemd (lite)

New unit `displaycameras-drm.service` — like the current one but no X:

```
[Service]
Type=simple
User=<kiosk user>
TTYPath=/dev/tty1
StandardInput=tty
ExecStart=/usr/local/bin/displaycameras-run-drm   # disables console blank, then: start; exec supervise
Restart=always
Conflicts=getty@tty1.service
```

`displaycameras-run-drm` sets `setterm`/console blanking off and hands off to
`displaycameras start` + `displaycameras supervise`. mpv `--vo=drm` becomes the
DRM master on tty1. Kiosk user must be in `video`/`render`/`tty`.

## 5. install.sh changes

1. Detect model → choose backend (or honour `--backend`).
2. Install **only** the needed packages:
   - lite → `mpv python3` (+ `libdrm2`, usually already present)
   - full → today's list (unchanged)
3. Install the matching unit (`displaycameras.service` vs
   `displaycameras-drm.service`) and enable it.
4. Write the matching config template:
   - lite → `displaycameras.conf` with `backend=lite`, and a single-camera
     `layout.conf.default` (just `camera_names`/`camera_feeds`, `rotate="true"`).
   - full → today's templates (unchanged).
5. `config.txt` recommendations sized to the board:
   - lite / ≤512 MB RAM → `gpu_mem=128`, **no** big CMA override (the Pi 4's
     `cma-512` is removed from the lite path). Keep `dtoverlay=vc4-kms-v3d`.

## 6. Backwards compatibility

- Your Pi 4 install and its config are unaffected (`backend=auto` resolves to
  `full` there; existing configs have no `backend` line and default to full).
- Existing full-backend configs keep working with no edits.

## 7. Open questions / to confirm on hardware

- Does `--vo=drm` on VideoCore IV need a specific `--drm-connector`, or is auto
  fine? (Test §3.)
- Best `hwdec` on bcm2835-codec for these boards; does `auto-safe` pick it?
- Console/tty handoff: any flicker or leftover console text behind mpv; is
  `Conflicts=getty@tty1` + blanking-off enough?
- Real ceiling resolution per board → sets the "use a substream" guidance.
- Whether Pi 2/3 should be `full` or `lite` by default (revisit with a board).

## 8. Not in scope (for this change)

- Multi-tile grids or dual-HDMI on lite boards (explicitly excluded).
- Compositing multiple cameras into one view on a Zero.
