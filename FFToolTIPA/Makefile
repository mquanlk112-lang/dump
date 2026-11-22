ARCHS := arm64 arm64e
TARGET := iphone:clang:latest:15.0
APPLICATION_NAME := FFTool
FFTool_INSTALL_PATH := /Applications
FFTool_FILES := main.mm FFToolAPI.mm
FFTool_CFLAGS += -fobjc-arc -Wno-deprecated-declarations
FFTool_FRAMEWORKS += Foundation UIKit QuartzCore CoreFoundation
FFTool_PRIVATE_FRAMEWORKS += BackBoardServices GraphicsServices SpringBoardServices
FFTool_LDFLAGS += -F$(CURDIR)/libraries
FFTool_CODESIGN_FLAGS += -SEntitlements.plist

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/application.mk

after-package::
	@mkdir -p packages $(THEOS_STAGING_DIR)/Payload
	@rm -rf $(THEOS_STAGING_DIR)/Payload/FFTool.app
	@cp -rp $(THEOS_STAGING_DIR)$(THEOS_PACKAGE_INSTALL_PREFIX)/Applications/FFTool.app $(THEOS_STAGING_DIR)/Payload/
	@cd $(THEOS_STAGING_DIR) && zip -qry $(CURDIR)/packages/FFTool.tipa Payload
	@rm -f $(CURDIR)/packages/*.deb
