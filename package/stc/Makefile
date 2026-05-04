#
# stc -- Smart Template Containers (stclib/STC).
# Mixed header-only + small libstc.a static lib. Build-only dep for
# ziti-edge-tunnel's vendored ziti-sdk-c (pkg_check_modules(stc REQUIRED)).
#
# Upstream uses Meson but also ships a working GNU Makefile. We use the
# Makefile path because it's a single command and avoids pulling Meson
# into the OpenWRT build env. We also hand-author a stc.pc (upstream
# does not ship one) so pkg_check_modules can resolve it.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=stc
PKG_VERSION:=5.0
PKG_RELEASE:=1

PKG_SOURCE:=STC-$(PKG_VERSION).tar.gz
PKG_SOURCE_URL:=https://codeload.github.com/stclib/STC/tar.gz/refs/tags/v$(PKG_VERSION)?
PKG_SOURCE_SUBDIR:=STC-$(PKG_VERSION)
PKG_HASH:=d61353852b9d7ef69b56fa32edcbc7934f2153385f3778536234201ceebcc950

PKG_MAINTAINER:=openwrt-openziti contributors
PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE

PKG_BUILD_DIR:=$(BUILD_DIR)/STC-$(PKG_VERSION)
PKG_BUILD_PARALLEL:=1

include $(INCLUDE_DIR)/package.mk

define Package/stc
  SECTION:=libs
  CATEGORY:=Libraries
  TITLE:=Smart Template Containers (stclib/STC)
  URL:=https://github.com/stclib/STC
  BUILDONLY:=1
endef

# Bypass upstream's Werror -- some toolchains (musl + gcc 12) trip on
# warnings the upstream CI doesn't see.
define Build/Compile
	$(MAKE) -C $(PKG_BUILD_DIR) lib \
		CC="$(TARGET_CC)" \
		AR_RCS="$(TARGET_AR) rcs" \
		CFLAGS="$(TARGET_CFLAGS) -std=c11 -Iinclude -O3 -Wno-error" \
		LDFLAGS="$(TARGET_LDFLAGS)"
endef

define Build/InstallDev
	$(INSTALL_DIR) $(1)/usr/include
	cp -r $(PKG_BUILD_DIR)/include/* $(1)/usr/include/

	$(INSTALL_DIR) $(1)/usr/lib
	$(CP) $(PKG_BUILD_DIR)/bld_Linux/$(notdir $(TARGET_CC))/libstc.a $(1)/usr/lib/

	$(INSTALL_DIR) $(1)/usr/lib/pkgconfig
	$(CP) ./files/stc.pc.in $(1)/usr/lib/pkgconfig/stc.pc
	sed -i 's/@VERSION@/$(PKG_VERSION)/' $(1)/usr/lib/pkgconfig/stc.pc
endef

# Static-only -- no runtime install.
define Package/stc/install
endef

$(eval $(call BuildPackage,stc))
