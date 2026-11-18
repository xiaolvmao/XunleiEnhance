TARGET := iphone:clang:16.5:14.0
ARCHS = arm64
INSTALL_TARGET_PROCESSES = TDMVideo

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = XunleiEnhance
XunleiEnhance_FILES = Tweak.xm
XunleiEnhance_CFLAGS = -fobjc-arc -Wno-unused-function
XunleiEnhance_FRAMEWORKS = Foundation UIKit

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += XunleiEnhancePrefs
include $(THEOS_MAKE_PATH)/aggregate.mk
