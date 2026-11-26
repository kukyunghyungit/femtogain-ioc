TOP=../..

include $(TOP)/configure/CONFIG
#----------------------------------------
#  ADD MACRO DEFINITIONS AFTER THIS LINE
#=============================

#=============================
# Build the IOC application

PROD_IOC = femtogain
# femtogain.dbd will be created and installed
DBD += femtogain.dbd

# femtogain.dbd will be made up from these files:
femtogain_DBD += base.dbd
femtogain_DBD += devGpio.dbd

# autosave (save/restore of the gain selections across restarts)
femtogain_DBD += asSupport.dbd
femtogain_LIBS += autosave

# Device support: GPIO via libgpiod
femtogain_SRCS += devGpio.c
femtogain_SYS_LIBS += gpiod

# femtogain_registerRecordDeviceDriver.cpp derives from femtogain.dbd
femtogain_SRCS += femtogain_registerRecordDeviceDriver.cpp

# Build the main IOC entry point on workstation OSs.
femtogain_SRCS_DEFAULT += femtogainMain.cpp
femtogain_SRCS_vxWorks += -nil-

# Finally link to the EPICS Base libraries
femtogain_LIBS += $(EPICS_BASE_IOC_LIBS)

#===========================

include $(TOP)/configure/RULES
#----------------------------------------
#  ADD RULES AFTER THIS LINE
