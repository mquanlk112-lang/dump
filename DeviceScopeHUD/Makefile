THEOS_PACKAGE_SCHEME = rootless
ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DeviceScopeHUD
DeviceScopeHUD_FILES = Tweak.xm
DeviceScopeHUD_FRAMEWORKS = UIKit Foundation
DeviceScopeHUD_CFLAGS = -fobjc-arc -Wno-deprecated-declarations

include $(THEOS_MAKE_PATH)/tweak.mk
