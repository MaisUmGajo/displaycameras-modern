#!/bin/bash
# Installer for the modern displaycameras video wall on Raspberry Pi OS
# Bookworm (Pi 4). Run as root:  sudo ./install.sh [--user <name>] [--upgrade]
#
#   --user <name>   Account the kiosk X session runs as (default: the invoking
#                   sudo user, else "pi"). Must be an existing login user.
#   --upgrade       Replace the scripts/service only; keep existing config.
set -euo pipefail

DIR="$(dirname "$(readlink -f "$0")")"
CONF_DIR="/etc/displaycameras"
BIN_DIR="/usr/local/bin"

# --- args ------------------------------------------------------------------
TARGET_USER=""
UPGRADE=false
while [ $# -gt 0 ]; do
	case "$1" in
		--user) TARGET_USER="$2"; shift 2 ;;
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
echo "Kiosk session will run as user: $TARGET_USER"

# --- dependencies ----------------------------------------------------------
echo "Installing dependencies..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
	mpv \
	xserver-xorg xinit x11-xserver-utils \
	openbox unclutter xdotool \
	python3

# Give the kiosk user access to the GPU, DRM, and input devices.
for grp in video render input tty; do
	if getent group "$grp" >/dev/null 2>&1; then
		usermod -aG "$grp" "$TARGET_USER"
	fi
done

# --- scripts ---------------------------------------------------------------
echo "Installing scripts to $BIN_DIR..."
install -m 0755 "$DIR/bin/displaycameras"         "$BIN_DIR/displaycameras"
install -m 0755 "$DIR/bin/displaycameras-ipc"     "$BIN_DIR/displaycameras-ipc"
install -m 0755 "$DIR/bin/displaycameras-session" "$BIN_DIR/displaycameras-session"

# --- config ----------------------------------------------------------------
mkdir -p "$CONF_DIR"
install -m 0644 "$DIR/xorg/openbox-rc.xml" "$CONF_DIR/openbox-rc.xml"

if [ "$UPGRADE" = false ]; then
	# Back up any existing config before writing fresh examples.
	if [ -f "$CONF_DIR/displaycameras.conf" ] || [ -f "$CONF_DIR/layout.conf.default" ]; then
		mkdir -p "$CONF_DIR/bak"
		find "$CONF_DIR" -maxdepth 1 -type f -name '*.conf*' -exec mv -f {} "$CONF_DIR/bak/" \;
		echo "Existing config backed up to $CONF_DIR/bak"
	fi
	install -m 0644 "$DIR/config/displaycameras.conf.example"   "$CONF_DIR/displaycameras.conf"
	install -m 0644 "$DIR/config/layout.conf.default.example"   "$CONF_DIR/layout.conf.default"
	echo "Wrote starter $CONF_DIR/displaycameras.conf and layout.conf.default (edit these!)."
else
	echo "Upgrade mode: existing config left untouched."
fi

# --- Xorg wrapper (allow X from the systemd service) -----------------------
mkdir -p /etc/X11
install -m 0644 "$DIR/xorg/Xwrapper.config" /etc/X11/Xwrapper.config

# --- systemd service --------------------------------------------------------
echo "Installing systemd service..."
sed "s/^User=.*/User=$TARGET_USER/" "$DIR/systemd/displaycameras.service" \
	>/etc/systemd/system/displaycameras.service
chmod 0644 /etc/systemd/system/displaycameras.service
systemctl daemon-reload
systemctl enable displaycameras.service

# --- boot config hint -------------------------------------------------------
BOOT_CFG=""
[ -f /boot/firmware/config.txt ] && BOOT_CFG=/boot/firmware/config.txt
[ -z "$BOOT_CFG" ] && [ -f /boot/config.txt ] && BOOT_CFG=/boot/config.txt
if [ -n "$BOOT_CFG" ]; then
	echo
	echo "Recommended boot settings are in $DIR/boot/config.txt.append"
	if [ "$UPGRADE" = false ]; then
		read -r -p "Append the recommended CMA/KMS settings to $BOOT_CFG now? [y/N] " reply
		if [ "$reply" = "y" ] || [ "$reply" = "Y" ]; then
			if ! grep -q 'displaycameras recommended settings' "$BOOT_CFG"; then
				printf '\n' >>"$BOOT_CFG"
				cat "$DIR/boot/config.txt.append" >>"$BOOT_CFG"
				echo "Appended. A reboot is required for CMA changes to take effect."
			else
				echo "Boot settings already present; skipping."
			fi
		fi
	fi
fi

echo
echo "Installation complete."
echo "Next steps:"
echo "  1. Edit $CONF_DIR/layout.conf.default with your camera feeds."
echo "  2. (Optional) Edit $CONF_DIR/displaycameras.conf for global options."
echo "  3. Reboot, or: sudo systemctl start displaycameras"
echo "  4. Check status:  displaycameras status   (run as $TARGET_USER)"
