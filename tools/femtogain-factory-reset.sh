#!/bin/bash
# femtogain-factory-reset.sh — restore the factory login password and network.
# Started only by femtogain-reset-button.py (reset jumper held RESET_HOLD_SEC).
# Not reachable from femtogainctl or the web UI.
#
# Indication: this unit has no controller-driven front LED, so the ODROID
# board's blue LED blinks 5 times (fast) before the settings change, and the
# event is written to /var/log/femtogain/reset.log.  The gain lines are not
# touched.
TOP=/usr/local/epics/iocs/femtogain
CONF=$TOP/iocBoot/iocfemtogain/ioc.conf
LOG=/var/log/femtogain/reset.log
LED=/sys/class/leds/blue
get() { local v; v=$(sed -n "s/^[[:space:]]*$1=\([^#]*\).*/\1/p" "$CONF" 2>/dev/null | tail -1 | tr -d '[:space:]'); echo "${v:-$2}"; }
mkdir -p "$(dirname "$LOG")"
log() { echo "$(date '+%F %T') $*" | tee -a "$LOG"; }

[ "$(id -u)" = 0 ] || { echo "must run as root" >&2; exit 1; }
USER_=$(get DEFAULT_USER root); PW=$(get DEFAULT_PASSWORD femto)
IP=$(get DEFAULT_IP 10.0.147.1); MASK=$(get DEFAULT_NETMASK 255.255.255.0)
GW=$(get DEFAULT_GATEWAY 10.0.147.99); DNS=$(get DEFAULT_DNS 8.8.8.8)

log "factory reset requested (reset jumper)"
if [ -w "$LED/trigger" ]; then
    old=$(sed -n 's/.*\[\(.*\)\].*/\1/p' "$LED/trigger")
    echo none > "$LED/trigger"
    for _ in 1 2 3 4 5; do echo 1 > "$LED/brightness"; sleep 0.25; echo 0 > "$LED/brightness"; sleep 0.25; done
    echo "${old:-heartbeat}" > "$LED/trigger"
fi

if printf '%s:%s\n' "$USER_" "$PW" | chpasswd; then log "password of $USER_ reset to the factory default"
else log "ERROR: could not reset the password of $USER_"; fi

if "$TOP/tools/femtogainctl" ip "$IP" "$GW" "$DNS" "$MASK" >>"$LOG" 2>&1; then log "network reset to $IP / $MASK gw $GW dns $DNS"
else log "ERROR: could not apply the factory network settings"; fi
log "factory reset done"
