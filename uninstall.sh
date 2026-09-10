#!/bin/bash
# Uninstaller for the modern displaycameras video wall. Run as root.
#   sudo ./uninstall.sh [--purge]
#     --purge   also remove /etc/displaycameras (config), not just the software
set -euo pipefail

PURGE=false
[ "${1:-}" = "--purge" ] && PURGE=true

if [ "$(id -u)" -ne 0 ]; then
	echo "This uninstaller must be run as root (use sudo)." >&2
	exit 1
fi

echo "Stopping and disabling the service (both backends)..."
for unit in displaycameras.service displaycameras-drm.service; do
	systemctl stop "$unit" 2>/dev/null || true
	systemctl disable "$unit" 2>/dev/null || true
	rm -f "/etc/systemd/system/$unit"
done
systemctl daemon-reload

echo "Removing scripts..."
rm -f /usr/local/bin/displaycameras \
      /usr/local/bin/displaycameras-ipc \
      /usr/local/bin/displaycameras-session \
      /usr/local/bin/displaycameras-run-drm

# Leave /etc/X11/Xwrapper.config in place; other tools may rely on it.

if [ "$PURGE" = true ]; then
	echo "Purging configuration in /etc/displaycameras..."
	rm -rf /etc/displaycameras
else
	echo "Configuration in /etc/displaycameras left in place (use --purge to remove)."
fi

rm -rf /run/displaycameras
echo "Uninstall complete."
