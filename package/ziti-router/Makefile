# ziti-router -- ships a self-built static Linux binary of `ziti`.
#
# Why self-built rather than redistributing upstream's release tarball:
# upstream's released artifacts are built with CGO_ENABLED=1 and link
# glibc. OpenWRT is musl. We compile the same source ourselves with
# CGO_ENABLED=0 (ziti has no `import "C"` requirements) using a
# golang:1.26 docker image -- producing a fully static binary that runs
# unmodified on musl OpenWRT. tools/build-ziti-router.sh orchestrates
# this; it MUST be run before this package builds, and stages the
# binaries under files/binaries/ziti-{arm64,amd64}.
#
# Restricted to aarch64 and x86_64 (the arches we cross-compile).

include $(TOPDIR)/rules.mk

PKG_NAME:=ziti-router
PKG_VERSION:=1.6.15
PKG_RELEASE:=1

PKG_LICENSE:=Apache-2.0
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=openwrt-openziti contributors

ifeq ($(ARCH),aarch64)
  PKG_ZITI_ARCH:=arm64
endif
ifeq ($(ARCH),x86_64)
  PKG_ZITI_ARCH:=amd64
endif

# No PKG_SOURCE -- we use a binary checked into ./files/binaries/.

include $(INCLUDE_DIR)/package.mk

define Package/ziti-router
  SECTION:=net
  CATEGORY:=Network
  TITLE:=OpenZiti edge router (self-built static binary)
  URL:=https://openziti.io
  DEPENDS:=@(aarch64||x86_64) +ca-bundle
endef

define Package/ziti-router/description
  OpenZiti edge router (`ziti-router`). Statically-linked Go binary,
  built from openziti/ziti v$(PKG_VERSION) with CGO_ENABLED=0 so it
  runs unmodified on musl OpenWRT. The binary is multi-call -- both
  `/usr/bin/ziti` and `/usr/bin/ziti-router` (symlink) are installed.

  The router must be enrolled with `ziti-router enroll` against an
  OpenZiti controller before it will start successfully.

  Not available on mips/mipsel/armv7. Run tools/build-ziti-router.sh on
  the build host before building this package.
endef

define Package/ziti-router/conffiles
/etc/config/ziti-router
/etc/ziti/router/
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	cp ./files/binaries/ziti-$(PKG_ZITI_ARCH) $(PKG_BUILD_DIR)/ziti
	chmod 0755 $(PKG_BUILD_DIR)/ziti
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/ziti-router/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/ziti $(1)/usr/bin/ziti
	ln -sf ziti $(1)/usr/bin/ziti-router

	$(INSTALL_DIR) $(1)/etc/ziti/router
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/ziti-router $(1)/etc/init.d/ziti-router

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/ziti-router $(1)/etc/config/ziti-router
endef

$(eval $(call BuildPackage,ziti-router))
