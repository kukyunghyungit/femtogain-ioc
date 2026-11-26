#!../../bin/linux-aarch64/femtogain

#- Femto Gain Controller Rev.2 IOC startup
#- Site settings come from environment variables (loaded from ioc.conf by
#- start_ioc.sh / systemd).  Every $(NAME=default) below falls back to the
#- default when the variable is not set, so `./st.cmd` also works standalone.

< envPaths

cd "${TOP}"

## ---- Site configuration -------------------------------------------
epicsEnvSet("PREFIX",       "$(PREFIX=GC01:)")
epicsEnvSet("GPIOCHIP",     "$(GPIOCHIP=gpiochip0)")
epicsEnvSet("DEFAULT_GAIN", "$(DEFAULT_GAIN=0)")
epicsEnvSet("OVL_BLANK",    "$(OVL_BLANK=0.5)")
#- channel signal names (PV = <PREFIX><NAME>Gain; Rev.1 was <NAME>GainValue)
epicsEnvSet("CH1_NAME",     "$(CH1_NAME=Io)")
epicsEnvSet("CH2_NAME",     "$(CH2_NAME=It)")
epicsEnvSet("CH3_NAME",     "$(CH3_NAME=If)")
epicsEnvSet("CH4_NAME",     "$(CH4_NAME=Ir)")
#- gpiochip0 line offsets for the ODROID-C5 40-pin header
epicsEnvSet("CH1_G0_LINE",  "$(CH1_G0_LINE=28)")   #- pin 7
epicsEnvSet("CH1_G1_LINE",  "$(CH1_G1_LINE=53)")   #- pin 11
epicsEnvSet("CH1_G2_LINE",  "$(CH1_G2_LINE=54)")   #- pin 12
epicsEnvSet("CH2_G0_LINE",  "$(CH2_G0_LINE=63)")   #- pin 13
epicsEnvSet("CH2_G1_LINE",  "$(CH2_G1_LINE=52)")   #- pin 15
epicsEnvSet("CH2_G2_LINE",  "$(CH2_G2_LINE=30)")   #- pin 16
epicsEnvSet("CH3_G0_LINE",  "$(CH3_G0_LINE=31)")   #- pin 18
epicsEnvSet("CH3_G1_LINE",  "$(CH3_G1_LINE=56)")   #- pin 19
epicsEnvSet("CH3_G2_LINE",  "$(CH3_G2_LINE=57)")   #- pin 21
epicsEnvSet("CH4_G0_LINE",  "$(CH4_G0_LINE=62)")   #- pin 22
epicsEnvSet("CH4_G1_LINE",  "$(CH4_G1_LINE=59)")   #- pin 23
epicsEnvSet("CH4_G2_LINE",  "$(CH4_G2_LINE=58)")   #- pin 24
epicsEnvSet("OVL1_LINE",    "$(OVL1_LINE=55)")     #- pin 26
epicsEnvSet("OVL2_LINE",    "$(OVL2_LINE=40)")     #- pin 29
epicsEnvSet("OVL3_LINE",    "$(OVL3_LINE=41)")     #- pin 31
epicsEnvSet("OVL4_LINE",    "$(OVL4_LINE=50)")     #- pin 32

## Register all support components
dbLoadDatabase "dbd/femtogain.dbd"
femtogain_registerRecordDeviceDriver pdbbase

## Load record instances (one template, four channels)
dbLoadRecords("db/femtogain.db", "P=$(PREFIX),CHIP=$(GPIOCHIP),S1=$(CH1_NAME),S2=$(CH2_NAME),S3=$(CH3_NAME),S4=$(CH4_NAME)")
dbLoadRecords("db/femtogainCh.template", "P=$(PREFIX),S=$(CH1_NAME),CH=1,CHIP=$(GPIOCHIP),GAIN=$(DEFAULT_GAIN),BLANK=$(OVL_BLANK),G0=$(CH1_G0_LINE),G1=$(CH1_G1_LINE),G2=$(CH1_G2_LINE),OVL=$(OVL1_LINE)")
dbLoadRecords("db/femtogainCh.template", "P=$(PREFIX),S=$(CH2_NAME),CH=2,CHIP=$(GPIOCHIP),GAIN=$(DEFAULT_GAIN),BLANK=$(OVL_BLANK),G0=$(CH2_G0_LINE),G1=$(CH2_G1_LINE),G2=$(CH2_G2_LINE),OVL=$(OVL2_LINE)")
dbLoadRecords("db/femtogainCh.template", "P=$(PREFIX),S=$(CH3_NAME),CH=3,CHIP=$(GPIOCHIP),GAIN=$(DEFAULT_GAIN),BLANK=$(OVL_BLANK),G0=$(CH3_G0_LINE),G1=$(CH3_G1_LINE),G2=$(CH3_G2_LINE),OVL=$(OVL3_LINE)")
dbLoadRecords("db/femtogainCh.template", "P=$(PREFIX),S=$(CH4_NAME),CH=4,CHIP=$(GPIOCHIP),GAIN=$(DEFAULT_GAIN),BLANK=$(OVL_BLANK),G0=$(CH4_G0_LINE),G1=$(CH4_G1_LINE),G2=$(CH4_G2_LINE),OVL=$(OVL4_LINE)")

## ---- No autosave (removed 2026-11-26) ------------------------------
#- Gains are NOT saved or restored.  Every IOC start (power-up, reboot,
#- service restart, procServ respawn) begins with all four channels at
#- DEFAULT_GAIN from ioc.conf (0 = E3, the lowest gain).  devGpio requests
#- every gain line as an output at LOW (code 0); PINI=YES then processes
#- each mbbo, which drives G0..G2 to DEFAULT_GAIN.

cd "${TOP}/iocBoot/${IOC}"
iocInit

## Post-init
epicsEnvShow("PREFIX")
gpioReport
dbl > "pvlist.txt"
