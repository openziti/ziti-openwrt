#
# llhttp -- HTTP/1.1 parser from nodejs/llhttp.
# Runtime dep for ziti-edge-tunnel's embedded tlsuv. tlsuv links against
# the shared library (despite BUILD_SHARED_LIBS=OFF; llhttp's CMake
# config exports both shared and static targets and tlsuv picks shared).
# So we ship libllhttp.so on the device and declare it as a runtime
# DEPENDS in ziti-edge-tunnel.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=llhttp
PKG_VERSION:=9.4.1
PKG_RELEASE:=1

PKG_SOURCE:=$(PKG_NAME)-$(PKG_VERSION).tar.gz
PKG_SOURCE_URL:=https://codeload.github.com/nodejs/llhttp/tar.gz/refs/tags/release/v$(PKG_VERSION)?
PKG_SOURCE_SUBDIR:=$(PKG_NAME)-release-v$(PKG_VERSION)
PKG_HASH:=86a8c16759fdcc7aa2c9841fbe8ba2e77ea98be7d5d45615f2604776d0ff78c7

PKG_MAINTAINER:=openwrt-openziti contributors
PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE-MIT

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-release-v$(PKG_VERSION)
PKG_BUILD_PARALLEL:=1

CMAKE_INSTALL:=1

include $(INCLUDE_DIR)/package.mk
include $(INCLUDE_DIR)/cmake.mk

define Package/llhttp
  SECTION:=libs
  CATEGORY:=Libraries
  TITLE:=HTTP/1.1 parser (nodejs/llhttp)
  URL:=https://github.com/nodejs/llhttp
  ABI_VERSION:=9
endef

# Build both static (for completeness in staging) and shared (for the
# runtime install that ZET links against).
CMAKE_OPTIONS += \
	-DBUILD_SHARED_LIBS=ON \
	-DBUILD_STATIC_LIBS=ON

define Package/llhttp/install
	$(INSTALL_DIR) $(1)/usr/lib
	$(CP) $(PKG_INSTALL_DIR)/usr/lib/libllhttp.so* $(1)/usr/lib/
endef

$(eval $(call BuildPackage,llhttp))
