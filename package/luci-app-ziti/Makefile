# SPDX-License-Identifier: Apache-2.0
#
# luci-app-ziti -- LuCI frontend for managing OpenZiti on OpenWRT.
#
# This Makefile follows the LuCI 23.05 JS-view convention. When built inside
# the OpenWRT LuCI feed, prefer "include ../../luci.mk" (which auto-discovers
# htdocs/, root/, po/ and sets standard LUCI_* variables). When built as a
# standalone out-of-tree package (this repo), we replicate the minimum
# behavior of luci.mk by hand.

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-ziti
PKG_VERSION:=0.1.0
PKG_RELEASE:=2

PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=openwrt-openziti contributors

LUCI_TITLE:=LuCI support for OpenZiti (ziti-edge-tunnel)
LUCI_DEPENDS:=+luci-base +ziti-edge-tunnel
LUCI_PKGARCH:=all

# If running inside the official LuCI feed, ../../luci.mk exists and does the
# right thing. Otherwise fall back to the standard package.mk pattern.
LUCI_MK:=$(wildcard ../../luci.mk)

ifneq ($(LUCI_MK),)
include $(LUCI_MK)
else

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)

include $(INCLUDE_DIR)/package.mk

define Package/$(PKG_NAME)
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=$(LUCI_TITLE)
  DEPENDS:=$(LUCI_DEPENDS)
  PKGARCH:=$(LUCI_PKGARCH)
  URL:=https://openziti.io
endef

define Package/$(PKG_NAME)/description
  LuCI web UI for managing OpenZiti identities, enrollment via JWT, and the
  ziti-edge-tunnel service on OpenWRT.
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)
	$(CP) ./htdocs $(1)/www/luci-static/.. 2>/dev/null || true
	# htdocs/ -> /www/
	if [ -d ./htdocs ]; then \
		$(INSTALL_DIR) $(1)/www ; \
		$(CP) -r ./htdocs/* $(1)/www/ ; \
	fi
	# root/ -> /
	if [ -d ./root ]; then \
		$(CP) -r ./root/. $(1)/ ; \
	fi
endef

define Package/$(PKG_NAME)/conffiles
/etc/config/ziti
endef

$(eval $(call BuildPackage,$(PKG_NAME)))

endif
