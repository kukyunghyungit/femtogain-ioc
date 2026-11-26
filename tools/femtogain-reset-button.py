#!/usr/bin/env python3
"""femtogain-reset-button — factory-reset switch watcher (GPIO).

Wiring: jumper or push button between header pin 36 (gpiochip0 line 51, internal
pull-up) and GND (pin 34).  Pressed = line reads 0.

Keep the pins connected for RESET_HOLD_SEC seconds (default 5): the ODROID
board's blue LED blinks five times and femtogain-factory-reset.sh restores the
default login password and IP address.  Shorter presses are ignored.

Config keys in ioc.conf: GPIOCHIP, RESET_LINE, RESET_HOLD_SEC.
Uses the libgpiod v1 CLI tools (gpiomon / gpioget); no Python extras needed.
Set FEMTOGAIN_RESET_SIM=<file> to read the line level from a file (testing).
"""
import os
import subprocess
import sys
import time

CONF = "/usr/local/epics/iocs/femtogain/iocBoot/iocfemtogain/ioc.conf"
RESET_SCRIPT = os.environ.get("FEMTOGAIN_RESET_SCRIPT", "/usr/local/epics/iocs/femtogain/tools/femtogain-factory-reset.sh")
SIM = os.environ.get("FEMTOGAIN_RESET_SIM")


def conf():
    d = {}
    try:
        with open(CONF) as f:
            for line in f:
                line = line.split("#", 1)[0].strip()
                if "=" in line:
                    k, v = line.split("=", 1)
                    d[k.strip()] = v.strip()
    except FileNotFoundError:
        pass
    return d


def log(msg):
    print(time.strftime("%F %T"), msg, flush=True)


def read_level(chip, line):
    if SIM:
        try:
            with open(SIM) as f:
                return int(f.read().strip() or "1")
        except Exception:  # noqa
            return 1
    p = subprocess.run(["gpioget", "--bias=pull-up", chip, str(line)], capture_output=True, text=True, timeout=5)
    return int(p.stdout.strip() or "1")


def wait_press(chip, line):
    """Block until the line goes low (button pressed)."""
    if SIM:
        while read_level(chip, line) != 0:
            time.sleep(0.2)
        return
    # gpiomon exits after the first falling edge; it holds the line meanwhile.
    subprocess.run(["gpiomon", "--bias=pull-up", "--falling-edge", "--num-events=1", "--silent", chip, str(line)],
                   timeout=None)


def main():
    c = conf()
    chip = c.get("GPIOCHIP", "gpiochip0")
    line = int(c.get("RESET_LINE", "51"))
    hold = float(c.get("RESET_HOLD_SEC", "5"))
    log(f"watching {chip} line {line} (hold {hold:g} s to factory-reset)")
    while True:
        try:
            wait_press(chip, line)
            t0 = time.monotonic()
            # measure how long it stays pressed
            while read_level(chip, line) == 0:
                if time.monotonic() - t0 >= hold:
                    log(f"button held {hold:g} s -> running factory reset")
                    subprocess.run([RESET_SCRIPT], timeout=120)
                    # wait for release so one long press triggers once
                    while read_level(chip, line) == 0:
                        time.sleep(0.2)
                    break
                time.sleep(0.1)
            else:
                log(f"short press ({time.monotonic() - t0:.1f} s) ignored")
            time.sleep(0.5)
        except KeyboardInterrupt:
            return 0
        except Exception as e:  # noqa
            log(f"error: {e}; retrying in 2 s")
            time.sleep(2)


if __name__ == "__main__":
    sys.exit(main())
