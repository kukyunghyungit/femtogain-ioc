#!/bin/bash
# femtogain-boot-overlay.sh [--check] — keep the SPI overlay out of the boot config.
#
# ODROID-C5 ships with overlays="spi0 i2c0 i2c1" in the [generic] section of
# /boot/config.ini.  spi0 claims header pins 19/21/23/24, which this board
# uses as C3_G1, C3_G2, C4_G1, C4_G2; with it loaded the IOC cannot drive
# those four gain lines.  This script removes spi0 from that line (other
# overlays are kept).  A reboot is needed for the change to take effect.
#
# /boot must be the mounted boot partition: an edit made while it is not
# mounted lands in the root filesystem and is silently ignored at boot
# (this happened on the first unit).
#
#   (no option)  fix the file if needed       exit 0 = ok / fixed
#   --check      report only, change nothing  exit 0 = ok, 1 = spi0 still set
#   exit 2 = cannot tell (not mounted, file missing)
CFG=${FEMTOGAIN_BOOT_CFG:-/boot/config.ini}
BOOTDIR=$(dirname "$CFG")
check=0; [ "${1:-}" = "--check" ] && check=1

if [ -z "${FEMTOGAIN_BOOT_CFG:-}" ] && ! mountpoint -q "$BOOTDIR"; then
    echo "boot-overlay: $BOOTDIR is not a mounted partition — mount the boot partition first (mount $BOOTDIR)" >&2; exit 2
fi
[ -f "$CFG" ] || { echo "boot-overlay: $CFG not found" >&2; exit 2; }

# overlays= line of the [generic] section only
cur=$(sed -n '/^\[generic\]/,/^\[/{/^\[generic\]/b;/^\[/b;/^overlays=/p}' "$CFG" | head -1)
live=no; ls /sys/bus/platform/drivers/meson-spicc*/*.spi >/dev/null 2>&1 && live=yes

if ! printf '%s\n' "$cur" | grep -qw spi0; then
    echo "boot-overlay: ok, spi0 is not in $CFG (${cur:-no overlays line})"
    [ $live = yes ] && echo "boot-overlay: the SPI driver is still loaded in this boot — reboot to free pins 19/21/23/24"
    exit 0
fi
if [ $check = 1 ]; then
    echo "boot-overlay: spi0 is still enabled in $CFG ($cur) — CH3/CH4 G1,G2 will not work"; exit 1
fi
[ -e "$CFG.pre-femtogain" ] || cp -a "$CFG" "$CFG.pre-femtogain"
sed -i '/^\[generic\]/,/^\[/{/^overlays=/{s/\bspi0\b//;s/  */ /g;s/=" /="/;s/ "$/"/}}' "$CFG"
sync
new=$(sed -n '/^\[generic\]/,/^\[/{/^overlays=/p}' "$CFG" | head -1)
echo "boot-overlay: removed spi0 from $CFG: $cur -> $new (backup $CFG.pre-femtogain)"
echo "boot-overlay: REBOOT REQUIRED before CH3/CH4 G1,G2 can be driven"
exit 0
