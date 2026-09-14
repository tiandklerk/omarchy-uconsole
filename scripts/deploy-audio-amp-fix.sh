#!/bin/bash
# Deploys the fixed amp-gating script + unit from this checkout. Run as root.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
install -Dm755 overlay/usr/local/bin/uconsole-audio-amp /usr/local/bin/uconsole-audio-amp
install -Dm644 overlay/etc/systemd/system/uconsole-audio-amp.service /etc/systemd/system/uconsole-audio-amp.service
systemctl daemon-reload
systemctl restart uconsole-audio-amp
sleep 1
echo "--- status ---"
systemctl status uconsole-audio-amp --no-pager
echo "--- last 5 log lines ---"
journalctl -u uconsole-audio-amp --no-pager -n 5
