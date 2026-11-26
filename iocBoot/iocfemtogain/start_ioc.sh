#!/bin/bash
# start_ioc.sh — launch the Femto Gain Controller IOC with settings from ioc.conf
#
#   ./start_ioc.sh                 use ./ioc.conf
#   FEMTOGAIN_CONF=/path/x.conf ./start_ioc.sh
#   PREFIX=TEST: ./start_ioc.sh    environment overrides the file
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${FEMTOGAIN_CONF:-$HERE/ioc.conf}"

# Load KEY=VALUE from conf, but let already-exported env vars win.
if [ -r "$CONF" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"              # strip comments
        line="${line//[[:space:]]/}"    # strip whitespace
        [ -z "$line" ] && continue
        key="${line%%=*}"; val="${line#*=}"
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        if [ -z "${!key+x}" ]; then export "$key=$val"; fi
    done < "$CONF"
fi

# Gain code 7 is undefined on the DLPCA-200: never boot into it.
if [ -n "${DEFAULT_GAIN+x}" ] && ! [[ "$DEFAULT_GAIN" =~ ^[0-6]$ ]]; then
    echo "[start_ioc] DEFAULT_GAIN='$DEFAULT_GAIN' is not 0-6, using 0" >&2
    export DEFAULT_GAIN=0
fi

cd "$HERE"
BIN="$HERE/../../bin/linux-aarch64/femtogain"
[ -x "$BIN" ] || { echo "IOC binary not built: $BIN  (run: make -C $HERE/../..)" >&2; exit 1; }
echo "[start_ioc] PREFIX=${PREFIX:-GC01:(default)}  conf=$CONF"
exec "$BIN" st.cmd
