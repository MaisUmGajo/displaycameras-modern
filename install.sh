#!/bin/bash
# Installer for the modern displaycameras camera display on Raspberry Pi OS
# (Bookworm/Trixie). Detects the board and installs the matching backend:
#   full - X11 + openbox multi-tile grids (Pi 4/5; Pi 2/3 by default)
#   lite - single fullscreen camera via DRM, no X (Pi Zero / Zero W / Pi 1)
#
# Run as root:  sudo ./install.sh [--user <name>] [--backend auto|full|lite] [--upgrade]
#
#   --user <name>      Account the display runs as (default: invoking sudo user,
#                      else "pi"). Must be an existing login user.
#   --backend <b>      Force the backend. Default 'auto' picks from the board
#                      (lite on ARMv6 boards, full otherwise).
#   --upgrade          Replace scripts/service only; keep existing config.
set -euo pipefail

DIR="$(dirname "$(readlink -f "$0")")"
CONF_DIR="/etc/displaycameras"
BIN_DIR="/usr/local/bin"

# --- args ------------------------------------------------------------------
TARGET_USER=""
BACKEND="auto"
UPGRADE=false
while [ $# -gt 0 ]; do
	case "$1" in
		--user) TARGET_USER="$2"; shift 2 ;;
		--backend) BACKEND="$2"; shift 2 ;;
		--upgrade) UPGRADE=true; shift ;;
		*) echo "Unknown option: $1" >&2; exit 1 ;;
	esac
done

if [ "$(id -u)" -ne 0 ]; then
	echo "This installer must be run as root (use sudo)." >&2
	exit 1
fi

if [ -z "$TARGET_USER" ]; then
	TARGET_USER="${SUDO_USER:-pi}"
fi
if ! id "$TARGET_USER" >/dev/null 2>&1; then
	echo "User '$TARGET_USER' does not exist. Create it or pass --user <name>." >&2
	exit 1
fi

# --- backend detection -----------------------------------------------------
if [ "$BACKEND" = "auto" ]; then
	if [ "$(uname -m 2>/dev/null)" = "armv6l" ]; then BACKEND="lite"; else BACKEND="full"; fi
fi
if [ "$BACKEND" != "full" ] && [ "$BACKEND" != "lite" ]; then
	echo "Invalid --backend '$BACKEND' (use auto|full|lite)." >&2
	exit 1
fi
MODEL="$(cat /proc/device-tree/model 2>/dev/null | tr -d '\000' || true)"
echo "Board:   ${MODEL:-unknown} ($(uname -m))"
echo "Backend: $BACKEND"
echo "User:    $TARGET_USER"

# --- dependencies ----------------------------------------------------------
echo "Installing dependencies..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
DEPS="mpv python3"
if [ "$BACKEND" = "full" ]; then
	DEPS="$DEPS xserver-xorg xinit x11-xserver-utils openbox unclutter xdotool"
fi
# shellcheck disable=SC2086
apt-get install -y $DEPS

# Access to the GPU/DRM, input, and console.
for grp in video render input tty; do
	if getent group "$grp" >/dev/null 2>&1; then
		usermod -aG "$grp" "$TARGET_USER"
	fi
done

# --- scripts ---------------------------------------------------------------
echo "Installing scripts to $BIN_DIR..."
install -m 0755 "$DIR/bin/displaycameras"     "$BIN_DIR/displaycameras"
install -m 0755 "$DIR/bin/displaycameras-ipc" "$BIN_DIR/displaycameras-ipc"
if [ "$BACKEND" = "full" ]; then
	install -m 0755 "$DIR/bin/displaycameras-session" "$BIN_DIR/displaycameras-session"
else
	install -m 0755 "$DIR/bin/displaycameras-run-drm" "$BIN_DIR/displaycameras-run-drm"
fi

# --- config ----------------------------------------------------------------
mkdir -p "$CONF_DIR"
[ "$BACKEND" = "full" ] && install -m 0644 "$DIR/xorg/openbox-rc.xml" "$CONF_DIR/openbox-rc.xml"

if [ "$UPGRADE" = false ]; then
	# Back up any existing config before writing fresh examples.
	if [ -f "$CONF_DIR/displaycameras.conf" ] || [ -f "$CONF_DIR/layout.conf.default" ]; then
		mkdir -p "$CONF_DIR/bak"
		find "$CONF_DIR" -maxdepth 1 -type f -name '*.conf*' -exec mv -f {} "$CONF_DIR/bak/" \;
		echo "Existing config backed up to $CONF_DIR/bak"
	fi
	if [ "$BACKEND" = "lite" ]; then
		install -m 0644 "$DIR/config/displaycameras.conf.lite.example" "$CONF_DIR/displaycameras.conf"
		install -m 0644 "$DIR/config/layout.conf.single.example"       "$CONF_DIR/layout.conf.default"
	else
		install -m 0644 "$DIR/config/displaycameras.conf.example"      "$CONF_DIR/displaycameras.conf"
		install -m 0644 "$DIR/config/layout.conf.default.example"      "$CONF_DIR/layout.conf.default"
	fi
	echo "Wrote starter $CONF_DIR/displaycameras.conf and layout.conf.default (edit these!)."
else
	echo "Upgrade mode: existing config left untouched."
fi

# --- systemd service -------------------------------------------------------
echo "Installing systemd service..."
if [ "$BACKEND" = "full" ]; then
	UNIT="displaycameras.service"; OTHER_UNIT="displaycameras-drm.service"
	# Allow Xorg to start from the service (no logind graphical seat here).
	mkdir -p /etc/X11
	install -m 0644 "$DIR/xorg/Xwrapper.config" /etc/X11/Xwrapper.config
else
	UNIT="displaycameras-drm.service"; OTHER_UNIT="displaycameras.service"
fi
# Disable the other backend's unit if a previous install left it enabled.
systemctl disable "$OTHER_UNIT" 2>/dev/null || true
sed "s/^User=.*/User=$TARGET_USER/" "$DIR/systemd/$UNIT" >"/etc/systemd/system/$UNIT"
chmod 0644 "/etc/systemd/system/$UNIT"
systemctl daemon-reload
systemctl enable "$UNIT"

# --- boot config hint ------------------------------------------------------
BOOT_CFG=""
[ -f /boot/firmware/config.txt ] && BOOT_CFG=/boot/firmware/config.txt
[ -z "$BOOT_CFG" ] && [ -f /boot/config.txt ] && BOOT_CFG=/boot/config.txt
if [ "$BACKEND" = "lite" ]; then APPEND="$DIR/boot/config.txt.append.lite"; else APPEND="$DIR/boot/config.txt.append"; fi
if [ -n "$BOOT_CFG" ] && [ "$UPGRADE" = false ]; then
	echo
	echo "Recommended boot settings are in $APPEND"
	read -r -p "Append them to $BOOT_CFG now? [y/N] " reply
	if [ "$reply" = "y" ] || [ "$reply" = "Y" ]; then
		if ! grep -q 'displaycameras.*recommended settings' "$BOOT_CFG"; then
			printf '\n' >>"$BOOT_CFG"
			cat "$APPEND" >>"$BOOT_CFG"
			echo "Appended. A reboot is required for these to take effect."
		else
			echo "Boot settings already present; skipping."
		fi
	fi
fi

echo
echo "Installation complete ($BACKEND backend)."
echo "Next steps:"
echo "  1. Edit $CONF_DIR/layout.conf.default with your camera feeds."
echo "  2. (Optional) Edit $CONF_DIR/displaycameras.conf for global options."
echo "  3. Reboot, or: sudo systemctl start ${UNIT%.service}"
echo "  4. Check status:  displaycameras status   (run as $TARGET_USER)"
