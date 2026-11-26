#!/bin/bash
# femtogain-gpio-init.sh — put the header pins into their safe idle state.
#
# ODROID-C5 powers up with the SoC's internal pull-UP enabled on several of
# the gain lines (header pins 11 13 15 19 21 22 23 24).  That fights the
# 100k pull-downs on the controller board while nothing drives the lines.
# This script switches every gain line to input + internal pull-DOWN (gain
# code 000) and every overload line to input + internal pull-up (idle =
# Normal, same direction as the external 47k).  The bias stays in effect
# after the line is released and when the IOC later drives the line.
#
# Run early at boot by femtogain-gpio-init.service and again before each IOC
# start.  Lines that are busy (IOC already running) are left alone.
CONF=/usr/local/epics/iocs/femtogain/iocBoot/iocfemtogain/ioc.conf
get() { local v; v=$(sed -n "s/^[[:space:]]*$1=\([^#]*\).*/\1/p" "$CONF" 2>/dev/null | tail -1 | tr -d '[:space:]'); echo "${v:-$2}"; }
CHIP=$(get GPIOCHIP gpiochip0)
for _ in $(seq 50); do [ -e "/dev/$CHIP" ] && break; sleep 0.1; done

gain=( $(get CH1_G0_LINE 28) $(get CH1_G1_LINE 53) $(get CH1_G2_LINE 54)
       $(get CH2_G0_LINE 63) $(get CH2_G1_LINE 52) $(get CH2_G2_LINE 30)
       $(get CH3_G0_LINE 31) $(get CH3_G1_LINE 56) $(get CH3_G2_LINE 57)
       $(get CH4_G0_LINE 62) $(get CH4_G1_LINE 59) $(get CH4_G2_LINE 58) )
ovl=( $(get OVL1_LINE 55) $(get OVL2_LINE 40) $(get OVL3_LINE 41) $(get OVL4_LINE 50) )

rc=0
for l in "${gain[@]}"; do gpioget --bias=pull-down "$CHIP" "$l" >/dev/null 2>&1 || { echo "gain line $l: busy or unavailable"; rc=1; }; done
for l in "${ovl[@]}";  do gpioget --bias=pull-up   "$CHIP" "$l" >/dev/null 2>&1 || { echo "overload line $l: busy or unavailable"; rc=1; }; done
echo "femtogain-gpio-init: gain lines ${gain[*]} -> input/pull-down, overload lines ${ovl[*]} -> input/pull-up (rc=$rc)"
exit 0
