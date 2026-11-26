#!/bin/bash
# install.sh — register the built femtogain IOC with the system (run as root).
# Also removes the spi0 overlay from /boot/config.ini (reboot needed).
# Prerequisites: EPICS Base in /usr/local/epics/base, autosave in
# /usr/local/epics/support/autosave (linked, not used), `make -C /usr/local/epics/iocs/femtogain` done,
# packages: build-essential libreadline-dev libgpiod-dev gpiod procserv telnet python3-yaml
set -e
TOP=/usr/local/epics/iocs/femtogain
BOOT=$TOP/iocBoot/iocfemtogain
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }

# IOC runs as user epics (group gpio: /dev/gpiochip0 is root:gpio 660)
id epics >/dev/null 2>&1 || useradd --system --home-dir /usr/local/epics --no-create-home --shell /usr/sbin/nologin --groups gpio epics
mkdir -p "$BOOT/autosave" /var/log/femtogain
chown epics:epics "$BOOT" "$BOOT/autosave" /var/log/femtogain
chown root:root "$BOOT/ioc.conf" "$BOOT/web.conf"; chmod 644 "$BOOT/ioc.conf"; chmod 600 "$BOOT/web.conf"

# CLI, login environment, login banner
ln -sfn "$TOP/tools/femtogainctl" /usr/local/bin/femtogainctl
ln -sfn "$TOP" /root/femtogain
cat > /etc/profile.d/epics.sh <<'EOP'
# EPICS environment (installed by femtogain setup)
export EPICS_BASE=/usr/local/epics/base
export EPICS_HOST_ARCH=linux-aarch64
export EPICS_CA_AUTO_ADDR_LIST=YES
case ":$PATH:" in
  *":$EPICS_BASE/bin/$EPICS_HOST_ARCH:"*) ;;
  *) export PATH="$EPICS_BASE/bin/$EPICS_HOST_ARCH:/usr/local/epics/iocs/femtogain/tools:$PATH" ;;
esac
EOP
ln -sfn "$TOP/tools/femtogain-motd.sh" /etc/profile.d/femtogain-motd.sh

# Boot config: the stock spi0 overlay claims header pins 19/21/23/24
# (C3_G1, C3_G2, C4_G1, C4_G2).  Remove it; takes effect after a reboot.
overlay_rc=0; "$TOP/tools/femtogain-boot-overlay.sh" || overlay_rc=$?
[ $overlay_rc = 0 ] || echo "WARNING: boot overlay not fixed (rc=$overlay_rc) — CH3/CH4 G1,G2 will not work until it is" >&2

# systemd units
for u in gpio-init ioc web reset firstboot; do cp "$BOOT/femtogain-$u.service" /etc/systemd/system/; done
systemctl daemon-reload
systemctl enable femtogain-gpio-init femtogain-ioc femtogain-web femtogain-reset femtogain-firstboot
systemctl start femtogain-gpio-init femtogain-ioc femtogain-web femtogain-reset
if ls /sys/bus/platform/drivers/meson-spicc*/*.spi >/dev/null 2>&1; then
    echo "installed, but the SPI driver still holds pins 19/21/23/24 in this boot:"
    echo "  REBOOT, then check:  femtogainctl status   (no 'pins differ' on CH3/CH4)"
else
    echo "installed.  Try: femtogainctl status"
fi
