ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = IPADumper
IPADumper_FILES = Dumper.mm
IPADumper_CFLAGS = -fobjc-arc -Wno-everything
IPADumper_CCFLAGS = -std=c++17 -Wno-everything
IPADumper_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
