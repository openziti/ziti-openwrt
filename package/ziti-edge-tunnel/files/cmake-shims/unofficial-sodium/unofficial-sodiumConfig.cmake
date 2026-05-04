# Shim for vcpkg's "unofficial-sodium" CMake port name.
# OpenZiti's ziti-sdk-c calls find_package(unofficial-sodium CONFIG REQUIRED)
# which is a vcpkg convention; OpenWRT ships plain "libsodium" via pkg-config,
# so we route the vcpkg-style target onto the system libsodium.

if(TARGET unofficial-sodium::sodium)
    return()
endif()

find_package(PkgConfig REQUIRED)
pkg_check_modules(_OPKG_SODIUM REQUIRED IMPORTED_TARGET libsodium)

add_library(unofficial-sodium::sodium INTERFACE IMPORTED)
target_link_libraries(unofficial-sodium::sodium INTERFACE PkgConfig::_OPKG_SODIUM)

set(unofficial-sodium_FOUND TRUE)
