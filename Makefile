TARGET := iphone:clang:latest:14.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = Aweme

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DYGlassDock

DYGlassDock_FILES = Tweak.x
DYGlassDock_CFLAGS = -fobjc-arc -Wno-unused-function -Wno-deprecated-declarations
DYGlassDock_FRAMEWORKS = UIKit Foundation AVFoundation Photos AudioToolbox
DYGlassDock_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 Aweme || true"
