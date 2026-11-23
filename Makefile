TARGET = iphone:clang:latest:15.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = Aweme

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DYYYAlbum
DYYYAlbum_FILES = Tweak.m
DYYYAlbum_CFLAGS = -fobjc-arc
DYYYAlbum_FRAMEWORKS = UIKit Photos Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
