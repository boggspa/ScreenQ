cmake_minimum_required(VERSION 3.20)
project(ScreenQFreeRDPBridge LANGUAGES C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

set(SCREENQ_FREERDP_PREFIX "" CACHE PATH "FreeRDP install prefix for static/non-pkg-config builds")
set(SCREENQ_OPENSSL_PREFIX "" CACHE PATH "OpenSSL install prefix for static/non-pkg-config builds")
set(SCREENQ_FREERDP_BRIDGE_BUNDLE_ID "com.example.ScreenQFreeRDPBridge" CACHE STRING "iOS framework bundle identifier")

add_library(ScreenQFreeRDPBridge SHARED
    src/ScreenQFreeRDPBridge.c
)

target_include_directories(ScreenQFreeRDPBridge
    PUBLIC
        ${CMAKE_CURRENT_SOURCE_DIR}/include
)

target_compile_options(ScreenQFreeRDPBridge PRIVATE
    -Wall
    -Wextra
    -Wpedantic
)

if(SCREENQ_FREERDP_PREFIX)
    if(NOT SCREENQ_OPENSSL_PREFIX)
        message(FATAL_ERROR "SCREENQ_OPENSSL_PREFIX is required when SCREENQ_FREERDP_PREFIX is set")
    endif()

    set(_screenq_freerdp_client "${SCREENQ_FREERDP_PREFIX}/lib/libfreerdp-client3.a")
    set(_screenq_freerdp_core "${SCREENQ_FREERDP_PREFIX}/lib/libfreerdp3.a")
    set(_screenq_winpr "${SCREENQ_FREERDP_PREFIX}/lib/libwinpr3.a")
    set(_screenq_ssl "${SCREENQ_OPENSSL_PREFIX}/lib/libssl.a")
    set(_screenq_crypto "${SCREENQ_OPENSSL_PREFIX}/lib/libcrypto.a")

    foreach(_screenq_required_file IN ITEMS
        "${_screenq_freerdp_client}"
        "${_screenq_freerdp_core}"
        "${_screenq_winpr}"
        "${_screenq_ssl}"
        "${_screenq_crypto}"
    )
        if(NOT EXISTS "${_screenq_required_file}")
            message(FATAL_ERROR "Required static dependency is missing: ${_screenq_required_file}")
        endif()
    endforeach()

    target_include_directories(ScreenQFreeRDPBridge
        PRIVATE
            "${SCREENQ_FREERDP_PREFIX}/include/freerdp3"
            "${SCREENQ_FREERDP_PREFIX}/include/winpr3"
            "${SCREENQ_OPENSSL_PREFIX}/include"
    )

    target_link_libraries(ScreenQFreeRDPBridge
        PRIVATE
            "${_screenq_freerdp_client}"
            "${_screenq_freerdp_core}"
            "${_screenq_winpr}"
            "${_screenq_ssl}"
            "${_screenq_crypto}"
            m
    )

    if(APPLE)
        find_library(SECURITY_FRAMEWORK Security)
        find_library(COREFOUNDATION_FRAMEWORK CoreFoundation)
        find_library(FOUNDATION_FRAMEWORK Foundation)
        target_link_libraries(ScreenQFreeRDPBridge
            PRIVATE
                ${SECURITY_FRAMEWORK}
                ${COREFOUNDATION_FRAMEWORK}
                ${FOUNDATION_FRAMEWORK}
        )
    endif()
else()
    find_package(PkgConfig REQUIRED)
    pkg_check_modules(FREERDP REQUIRED freerdp3 freerdp-client3 winpr3)

    target_include_directories(ScreenQFreeRDPBridge
        PRIVATE
            ${FREERDP_INCLUDE_DIRS}
    )

    target_compile_options(ScreenQFreeRDPBridge PRIVATE
        ${FREERDP_CFLAGS_OTHER}
    )

    target_link_directories(ScreenQFreeRDPBridge PRIVATE ${FREERDP_LIBRARY_DIRS})
    target_link_libraries(ScreenQFreeRDPBridge PRIVATE ${FREERDP_LIBRARIES})
endif()

set_target_properties(ScreenQFreeRDPBridge PROPERTIES
    OUTPUT_NAME "ScreenQFreeRDPBridge"
    PUBLIC_HEADER "${CMAKE_CURRENT_SOURCE_DIR}/include/ScreenQFreeRDPBridgeABI.h"
)

if(APPLE AND (IOS OR CMAKE_SYSTEM_NAME STREQUAL "iOS"))
    set_target_properties(ScreenQFreeRDPBridge PROPERTIES
        FRAMEWORK TRUE
        FRAMEWORK_VERSION A
        MACOSX_FRAMEWORK_IDENTIFIER "${SCREENQ_FREERDP_BRIDGE_BUNDLE_ID}"
        MACOSX_FRAMEWORK_BUNDLE_VERSION "1"
        MACOSX_FRAMEWORK_SHORT_VERSION_STRING "1.0"
        XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED "NO"
    )
endif()
