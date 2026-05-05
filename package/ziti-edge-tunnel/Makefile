#
# Copyright (C) 2026 OpenZiti contributors
#
# This is free software, licensed under the Apache License, Version 2.0.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=ziti-edge-tunnel
PKG_VERSION:=1.15.1
PKG_RELEASE:=2

PKG_SOURCE:=$(PKG_NAME)-$(PKG_VERSION).tar.gz
PKG_SOURCE_URL:=https://codeload.github.com/openziti/ziti-tunnel-sdk-c/tar.gz/refs/tags/v$(PKG_VERSION)?
PKG_SOURCE_SUBDIR:=ziti-tunnel-sdk-c-$(PKG_VERSION)
# sha256 of the codeload source tarball at refs/tags/v$(PKG_VERSION).
PKG_HASH:=12f01f561a3d70db796ed73691edac5498e931284171571e2280102140f37fd0

PKG_MAINTAINER:=OpenZiti contributors <developers@openziti.org>
PKG_LICENSE:=Apache-2.0
PKG_LICENSE_FILES:=LICENSE

PKG_BUILD_DIR:=$(BUILD_DIR)/ziti-tunnel-sdk-c-$(PKG_VERSION)
PKG_BUILD_PARALLEL:=1
PKG_USE_MIPS16:=0

# Build-only dep: tlsuv (vendored inside ZET) calls find_package(llhttp).
# llhttp lives as a sibling package in this feed; this declaration causes
# the SDK to build+stage it before our cmake configure runs.
PKG_BUILD_DEPENDS:=llhttp stc

CMAKE_INSTALL:=1

include $(INCLUDE_DIR)/package.mk
include $(INCLUDE_DIR)/cmake.mk

define Package/ziti-edge-tunnel
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=VPN
  TITLE:=OpenZiti edge tunneler (ZET)
  URL:=https://openziti.io/
  DEPENDS:=+libuv +libopenssl +zlib +libjson-c +libsodium +libprotobuf-c +libpcap +llhttp +libatomic +kmod-tun +ip-full +ca-bundle
endef

define Package/ziti-edge-tunnel/description
  ziti-edge-tunnel is the C tunneler from openziti/ziti-tunnel-sdk-c.
  It hosts and dials OpenZiti services and exposes them locally via a tun
  device, providing transparent zero-trust connectivity. State and enrolled
  identities live under /etc/ziti/ on overlay so they survive reboots.
endef

define Package/ziti-edge-tunnel/conffiles
/etc/config/ziti
/etc/ziti/identities/
endef

# Favor system libs over the upstream's vendored copies. Build only the
# tunneler binary, not tests/samples. TLSUV_TLSLIB selects the TLS backend;
# we pick openssl because OpenWRT's mbedtls is built without debug
# symbols (e.g. mbedtls_debug_set_threshold) that tlsuv's mbedtls engine
# references unconditionally -- causing link errors. Community NetFoundry
# scripts also use openssl for the same reason. Footprint hit is
# acceptable on aarch64/x86_64 targets we support.
CMAKE_OPTIONS += \
	-DCMAKE_BUILD_TYPE=Release \
	-DTLSUV_TLSLIB=openssl \
	-DUSE_OPENSSL=ON \
	-DUSE_MBEDTLS=OFF \
	-DBUILD_DIST_PACKAGES=OFF \
	-DBUILD_TESTS=OFF \
	-DEXCLUDE_PROGRAMS=OFF \
	-DHAVE_LIBUV=ON \
	-DHAVE_LIBSODIUM=ON \
	-DZITI_TUNNEL_BUILD_TESTS=OFF \
	-DDISABLE_SEMVER_VERIFICATION=ON \
	-DGIT_VERSION=v$(PKG_VERSION) \
	-DPROJECT_SEMVER=$(PKG_VERSION) \
	-Dunofficial-sodium_DIR=$(PKG_BUILD_DIR)/.cmake-shims/unofficial-sodium \
	-DDISABLE_LIBSYSTEMD_FEATURE=ON

# Drop the vcpkg-name shim into the source tree before cmake configure
# runs. It re-exports OpenWRT's libsodium under the "unofficial-sodium"
# CMake target name that ziti-sdk-c expects.
define Build/Configure
	mkdir -p $(PKG_BUILD_DIR)/.cmake-shims/unofficial-sodium
	$(CP) ./files/cmake-shims/unofficial-sodium/unofficial-sodiumConfig.cmake \
		$(PKG_BUILD_DIR)/.cmake-shims/unofficial-sodium/
	$(call Build/Configure/Default)
endef

# The upstream tree installs the binary as ziti-edge-tunnel under bin/.
define Package/ziti-edge-tunnel/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/usr/bin/ziti-edge-tunnel $(1)/usr/bin/ziti-edge-tunnel

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/ziti-edge-tunnel $(1)/etc/init.d/ziti-edge-tunnel

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/ziti $(1)/etc/config/ziti

	$(INSTALL_DIR) $(1)/etc/ziti
	$(INSTALL_DIR) $(1)/etc/ziti/identities
endef

define Package/ziti-edge-tunnel/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
chmod 0700 /etc/ziti/identities 2>/dev/null

# Create the 'ziti' system group if missing. ZET expects it to exist
# for its IPC socket server (`tunnel_status` etc); without it the
# server is disabled and the LuCI Status tab cannot query live state.
# BusyBox lacks groupadd, so append to /etc/group directly using a
# free system-range gid.
if ! grep -q '^ziti:' /etc/group; then
	gid=900
	while grep -q ":$${gid}:" /etc/group; do
		gid=$$((gid + 1))
		[ $${gid} -ge 1000 ] && break
	done
	echo "ziti:x:$${gid}:" >> /etc/group
fi

exit 0
endef

$(eval $(call BuildPackage,ziti-edge-tunnel))
