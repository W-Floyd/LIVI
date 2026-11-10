#!/usr/bin/env bash
# Backport the Android logger (/dev/log/*) and alarm (/dev/alarm) drivers that
# 3.18 had and 4.4 dropped; Android 4.4 userland uses both.
# $1 = 3.18 tree (only drivers/staging/android extracted), $2 = 4.4 tree.
set -euo pipefail
OLD=$1/drivers/staging/android NEW=$2/drivers/staging/android
cp "$OLD"/logger.c "$OLD"/logger.h "$OLD"/alarm-dev.c "$OLD"/android_alarm.h "$NEW"/
cp "$OLD"/uapi/android_alarm.h "$NEW"/uapi/
python3 - "$NEW" <<'PY'
import sys
d = sys.argv[1]
l = open(d + "/logger.c").read()
l = l.replace("iocb->ki_nbytes", "iov_iter_count(from)")
l = l.replace("#include <linux/sched.h>", "#include <linux/sched.h>\n#include <linux/uio.h>", 1)
# The stock liblog also opens /dev/log/mobis and treats a missing node as a fatal init failure.
l = l.replace("\tret = create_log(LOGGER_LOG_SYSTEM, 256*1024);", "\tret = create_log(\"log_mobis\", 256*1024);\n\tif (unlikely(ret))\n\t\tgoto out;\n\n\tret = create_log(LOGGER_LOG_SYSTEM, 256*1024);", 1)
open(d + "/logger.c", "w").write(l)
k = open(d + "/Kconfig").read()
add = '''config ANDROID_LOGGER
	tristate "Android log driver"
	default n

config ANDROID_ALARM_DEV
	bool "Android alarm driver"
	depends on RTC_CLASS
	default n

'''
k = k.replace("config ANDROID_TIMED_OUTPUT", add + "config ANDROID_TIMED_OUTPUT", 1)
open(d + "/Kconfig", "w").write(k)
m = open(d + "/Makefile").read()
m += "obj-$(CONFIG_ANDROID_LOGGER)\t+= logger.o\nobj-$(CONFIG_ANDROID_ALARM_DEV)\t+= alarm-dev.o\n"
open(d + "/Makefile", "w").write(m)
PY
