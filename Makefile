# Artlight - game streaming client for Sunshine and Apollo hosts (the GameStream protocol of Moonlight/Artemis) on
# jailbroken iOS. One source tree, two packages (Theos):
#   make package                               armv7 for iOS 6.x (the iOS 9.3 SDK, deployment target 6.0)
#   make package THEOS_PACKAGE_SCHEME=rootless arm64 for iOS 14-17 (the iOS 16.5 SDK, deployment target 14.0):
#                                              the .deb for rootless jailbreaks, the IPA for TrollStore
# (`make clean` between the two; CI builds both, see .github/workflows/build.yml)

ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
TARGET := iphone:clang:16.5:14.0
ARCHS := arm64
else
TARGET := iphone:clang:9.3:6.0
ARCHS := armv7
endif
DEBUG ?= 0

# Device used by `make install` (Theos) - overridden by tools/ipad.ps1 anyway
THEOS_DEVICE_IP ?= 192.168.1.176
THEOS_DEVICE_USER ?= root

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME := Artlight

# libopus (fixed point, plain C - no ARM assembly), fetched by CI into vendor/opus; the multistream decoder is in src/
OPUS_SRC := $(filter-out vendor/opus/src/opus_demo.c vendor/opus/src/repacketizer_demo.c vendor/opus/src/opus_compare.c vendor/opus/src/mlp_train.c, $(wildcard vendor/opus/src/*.c)) \
            $(filter-out vendor/opus/celt/opus_custom_demo.c, $(wildcard vendor/opus/celt/*.c)) \
            $(wildcard vendor/opus/silk/*.c) \
            $(wildcard vendor/opus/silk/fixed/*.c)

# moonlight-common-c (GPLv3, checked in with a few marked Artlight changes - see vendor/moonlight-common-c/ARTLIGHT.md),
# with its ENet and nanors (Reed-Solomon FEC) dependencies
MLC := vendor/moonlight-common-c
MLC_SRC := $(wildcard $(MLC)/src/*.c) \
           $(MLC)/enet/callbacks.c $(MLC)/enet/compress.c $(MLC)/enet/host.c $(MLC)/enet/list.c $(MLC)/enet/packet.c \
           $(MLC)/enet/peer.c $(MLC)/enet/protocol.c $(MLC)/enet/unix.c \
           $(MLC)/nanors/rs.c $(MLC)/nanors/deps/obl/oblas_common.c $(MLC)/nanors/deps/obl/oblas_lite.c

Artlight_FILES := $(wildcard src/*.m) $(wildcard src/*/*.m) $(wildcard src/*/*.c) \
                  vendor/mbedtls_glue.c \
                  $(wildcard vendor/mbedtls/library/*.c) \
                  $(OPUS_SRC) \
                  $(MLC_SRC)

Artlight_FRAMEWORKS := UIKit Foundation CoreGraphics QuartzCore CoreText Security ImageIO CoreMedia CoreVideo OpenGLES AudioToolbox AVFoundation

# Flags for every C-family file (also the vendored mbedTLS, opus and moonlight-common-c sources)
Artlight_CFLAGS := -Isrc -Isrc/GS -Isrc/Stream -Isrc/Media -Isrc/UI -Isrc/Util \
                   -Ivendor -Ivendor/mbedtls/include -Ivendor/mbedtls/library \
                   -Ivendor/opus/include -Ivendor/opus/celt -Ivendor/opus/silk -Ivendor/opus/silk/fixed -Ivendor/opus \
                   -I$(MLC)/src -I$(MLC)/enet/include -I$(MLC)/nanors -I$(MLC)/nanors/deps/obl \
                   -DOPUS_BUILD -DFIXED_POINT=1 -DDISABLE_FLOAT_API -DUSE_ALLOCA -DHAVE_LRINT -DHAVE_LRINTF \
                   -DUSE_MBEDTLS -DHAS_SOCKLEN_T -D__APPLE_USE_RFC_3542 \
                   -Os -fvisibility=hidden \
                   -Wall -Wno-unused-variable -Wno-unused-function -Wno-unused-but-set-variable \
                   -Wno-deprecated-declarations -Wno-unknown-warning-option -Wno-unused-parameter -Wno-sign-compare \
                   -Wno-nullability-completeness -Wno-nullability-completeness-on-arrays -Wno-error

# Objective-C only: ARC; APIs newer than the deployment target are warnings here and turned into errors for our
# own sources by the pragma in src/ALCommon.h (vendored code only warns). src/Util/ALModern.m bridges the newer
# iOS on its own terms and opts out.
Artlight_OBJCFLAGS := -fobjc-arc -Wunguarded-availability

Artlight_LDFLAGS := -lz

include $(THEOS)/makefiles/application.mk

Artlight_STAGED_APP := $(THEOS_STAGING_DIR)/Applications/Artlight.app
Artlight_STAGED_BIN := $(Artlight_STAGED_APP)/Artlight

ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
# The arm64 bundle: iOS 14.0+, arm64 required, a launch screen the system draws instead of the iOS 6 launch
# images (tools/modern_bundle.py), signed again with the entitlements afterwards.
after-stage::
	python3 "$(THEOS_PROJECT_DIR)/tools/modern_bundle.py" "$(Artlight_STAGED_APP)"
	ldid -S"$(THEOS_PROJECT_DIR)/entitlements-arm64.xml" "$(Artlight_STAGED_BIN)"
# The .deb is for rootless jailbreaks (iOS 15 and newer; Theos sets Architecture: iphoneos-arm64 and the /var/jb
# prefix itself) and tells the home screen about the app when installed or removed.
before-package::
	sed -i -e 's/^Depends: .*/Depends: firmware (>= 15.0)/' "$(THEOS_STAGING_DIR)/DEBIAN/control"
	printf '%s\n' '#!/bin/sh' '[ "$$1" = configure ] || exit 0' \
		'command -v uicache >/dev/null 2>&1 && { uicache -p /var/jb/Applications/Artlight.app >/dev/null 2>&1 || uicache -a >/dev/null 2>&1; }' \
		'exit 0' > "$(THEOS_STAGING_DIR)/DEBIAN/postinst"
	printf '%s\n' '#!/bin/sh' '[ "$$1" = remove ] || exit 0' \
		'command -v uicache >/dev/null 2>&1 && uicache -a >/dev/null 2>&1' \
		'exit 0' > "$(THEOS_STAGING_DIR)/DEBIAN/postrm"
	chmod 0755 "$(THEOS_STAGING_DIR)/DEBIAN/postinst" "$(THEOS_STAGING_DIR)/DEBIAN/postrm"
else
# The iOS 9.3 SDK places the NSURL* loading classes in CFNetwork; on iOS 6 they live in Foundation and dyld aborts at
# launch when the binary asks CFNetwork for them. The app avoids those classes, but should the linker still record
# CFNetwork, the load command is pointed at Foundation (harmless when there is none), then the binary is signed again.
after-stage::
	install_name_tool -change /System/Library/Frameworks/CFNetwork.framework/CFNetwork /System/Library/Frameworks/Foundation.framework/Foundation "$(Artlight_STAGED_BIN)" || true
	ldid -S"$(THEOS_PROJECT_DIR)/entitlements.xml" "$(Artlight_STAGED_BIN)"
endif
