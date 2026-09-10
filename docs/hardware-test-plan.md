# Hardware test plan — legacy-board (lite) support

Goal: validate and tune the new **`lite` (DRM, no-X, single-camera-rotation)**
backend on real ARMv6 boards (Raspberry Pi Zero / Zero W / Pi 1), on a current
Raspberry Pi OS (Bookworm/Trixie) — **not** an old OS.

We run this interactively over SSH so we can measure, adjust a knob, and
re-measure on the physical board.

---

## 0. Prerequisites (before the session)

- Board flashed with the latest Raspberry Pi OS **Lite** (32-bit / armhf; the
  ARMv6 build for Zero/Pi 1). Headless SSH enabled.
- Board on the network; note its IP. Add our SSH key to
  `~/.ssh/authorized_keys` (same as the Pi 4).
- A display connected via (mini-)HDMI.
- At least one camera **low-resolution substream** RTSP URL reachable from the
  board (e.g. 640x360 or D1). Ideally a few, to test rotation.
- `sudo` available (note whether it needs a password).

Capture a baseline first:
```
cat /proc/device-tree/model; echo
nproc; grep -m1 'model name\|Model' /proc/cpuinfo; grep Hardware /proc/cpuinfo
free -m
vcgencmd measure_temp; vcgencmd get_throttled; vcgencmd version
```

---

## 1. Hardware detection

Confirm the detector picks the **lite** backend on this board.

- Run the detection helper (`displaycameras --detect` or the install probe).
- **Pass:** reports the correct model and selects `backend=lite`.
- Record the exact `/proc/device-tree/model` string so the matcher covers it.

## 2. Install

- Run `sudo ./install.sh` (or `--backend lite` to force).
- **Pass:** installs only the minimal deps (mpv, python3 — no X packages);
  drops the DRM systemd unit; writes a lite `displaycameras.conf`
  (`backend=lite`), a single-camera `layout.conf.default`, and a board-sized
  `config.txt` (`gpu_mem=128`, small/no CMA).
- Record install time and disk footprint.

## 3. Decode capability probe (manual, before the service)

Find the resolution ceiling and the best decoder **before** wiring the wall.
For each resolution's substream, run mpv directly on the console:

```
mpv --vo=drm --hwdec=auto-safe --rtsp-transport=tcp --no-audio \
    --profile=low-latency --msg-level=vd=v,vo=v --untimed=no \
    "rtsp://<low-res-substream>"
```

Measure while it runs (from an SSH shell):
```
top -b -n1 | head -12          # mpv CPU%
vcgencmd measure_temp; vcgencmd get_throttled
```
And from mpv: `--msg-level=vd=v` shows whether a HW decoder engaged; the OSD
(`i` / `--osd-level=3`) or `--dump-stats` shows fps / dropped / decoded.

Record per resolution (**640x360, 704x576/D1, 1280x720, 1920x1080**):

| Res | hwdec active? | mpv CPU% | source fps vs shown | dropped | temp | verdict |
|-----|---------------|----------|---------------------|---------|------|---------|

## 4. Decoder (hwdec) matrix

For the **highest resolution that looked viable** in §3, compare decoders:

| hwdec | plays? | CPU% | dropped | notes |
|-------|--------|------|---------|-------|
| `auto-safe` | | | | |
| `v4l2m2m` (or `v4l2m2m-copy`) | | | | bcm2835-codec HW path |
| `drm-prime` | | | | zero-copy |
| `no` (software) | | | | expect fail >SD on ARMv6 |

Also compare video output: `--vo=drm` vs `--vo=gpu --gpu-context=drm`.

**Outcome:** choose the default `hwdec` + `vo` + max resolution for the lite
config, and bake them in.

## 5. Service integration

- `sudo systemctl enable --now displaycameras` (or reboot).
- **Pass:** single camera shows fullscreen on HDMI after boot; `displaycameras
  status` reports it playing; no X server running (`pgrep Xorg` empty).
- Record boot-to-picture time.

## 6. Rotation

- Set `rotate="true"`, `rotatedelay=8`, list several cameras.
- Measure: switch latency (time from `rotate` to new picture), any black gap or
  glitch, and **memory over many cycles** (leak check):
```
for i in $(seq 1 40); do displaycameras rotate; sleep 3; \
  echo "$(date +%T) $(grep MemAvailable /proc/meminfo) $(vcgencmd measure_temp)"; done
```
- **Pass:** switches within a couple of seconds, no crash, MemAvailable stable.

## 7. Resilience / repair

- Kill mpv (`pkill mpv`) → **supervise must relaunch** it within
  `repair_interval`.
- Break the stream (block the camera IP / unplug its network) for ~30 s, then
  restore → tile must reconnect on its own.
- Start the service with the camera **unreachable** → must keep retrying and
  come up when the camera returns (no crash loop).

## 8. Soak + thermal (30–60 min)

Leave it running and sample every 30 s:
```
while true; do echo "$(date +%T) $(vcgencmd measure_temp) \
  throttled=$(vcgencmd get_throttled) $(grep MemAvailable /proc/meminfo)"; sleep 30; done
```
- **Pass:** no crash, no memory growth, temp/throttle acceptable for the board.

## 9. Board-specific edges

- **Zero W:** 2.4 GHz Wi-Fi latency/jitter vs Ethernet — does the stream hold?
- **Pi 1:** networking path (Model B Ethernet; no built-in Wi-Fi).
- Boot time cold; behaviour if HDMI negotiated a different mode.

---

## Tuning knobs we can change live

- `hwdec`: `auto-safe` / `v4l2m2m` / `v4l2m2m-copy` / `drm-prime` / `no`
- Video out: `--vo=drm` vs `--vo=gpu --gpu-context=drm`
- Source **substream resolution** (biggest lever on ARMv6)
- Cache/latency: `--profile=low-latency` vs a small cache;
  `--vd-lavc-threads`, `--network-timeout`
- `--force-window` / initial connector selection (`--drm-connector`)
- `config.txt`: `gpu_mem`, CMA size, HDMI mode force
- `rotatedelay`, `repair_interval`

## Pass/fail summary (fill in on the day)

| Board | Max res HW-decoded | Best hwdec | Rotation OK | 60-min soak | Verdict |
|-------|--------------------|-----------|-------------|-------------|---------|
| Zero W | | | | | |
| Pi 1   | | | | | |

Target bar: one low-res (≈640x360) stream, hardware-decoded at source fps,
mpv CPU comfortably under one core, rotation switch < ~2 s, stable over a
60-minute soak with no leak and no runaway throttling.
