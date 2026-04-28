#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
physical_build_root="$repo_root/.build"
freerdp_version="${FREERDP_VERSION:-3.25.0}"
deployment_target="${DEPLOYMENT_TARGET:-17.0}"
jobs="${JOBS:-$(sysctl -n hw.ncpu)}"
force=0
skip_openssl=0
freerdp_source=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)
            force=1
            shift
            ;;
        --skip-openssl)
            skip_openssl=1
            shift
            ;;
        --deployment-target)
            deployment_target="${2:-}"
            shift 2
            ;;
        --freerdp-version)
            freerdp_version="${2:-}"
            freerdp_source=""
            shift 2
            ;;
        --freerdp-source)
            freerdp_source="${2:-}"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

if [[ -z "$deployment_target" || -z "$freerdp_version" ]]; then
    echo "deployment target and FreeRDP version must be non-empty" >&2
    exit 2
fi

mkdir -p "$physical_build_root"
build_root="$physical_build_root"

if [[ "$physical_build_root" == *" "* ]]; then
    safe_build_root="${TMPDIR:-/tmp}/screenq-build-${USER:-$(id -u)}"
    if [[ -L "$safe_build_root" || ! -e "$safe_build_root" ]]; then
        rm -f "$safe_build_root"
        ln -s "$physical_build_root" "$safe_build_root"
    elif [[ "$(cd "$safe_build_root" && pwd -P)" != "$(cd "$physical_build_root" && pwd -P)" ]]; then
        echo "Cannot create no-space build path at $safe_build_root; path already exists and points elsewhere." >&2
        exit 1
    fi
    build_root="$safe_build_root"
fi

if [[ -z "$freerdp_source" ]]; then
    freerdp_source="$build_root/FreeRDP-$freerdp_version-src"
fi

if [[ -z "$freerdp_source" ]]; then
    echo "FreeRDP source path must be non-empty" >&2
    exit 2
fi

if [[ ! -d "$freerdp_source" ]]; then
    git clone --depth 1 --branch "$freerdp_version" https://github.com/FreeRDP/FreeRDP.git "$freerdp_source"
fi

toolchain="$freerdp_source/cmake/ios.toolchain.cmake"
if [[ ! -f "$toolchain" ]]; then
    echo "FreeRDP iOS toolchain was not found at $toolchain" >&2
    exit 1
fi

if [[ "$skip_openssl" -eq 0 ]]; then
    openssl_args=(--deployment-target "$deployment_target")
    if [[ "$force" -eq 1 ]]; then
        openssl_args+=(--force)
    fi
    "$repo_root/Scripts/build_ios_openssl.sh" "${openssl_args[@]}"
fi

build_freerdp_slice() {
    local slice="$1"
    local platform="$2"
    local arch="$3"
    local openssl_prefix="$build_root/ios-deps/openssl/$slice"
    local install_dir="$build_root/ios-deps/freerdp/$slice"
    local build_dir="$build_root/freerdp-ios/$slice"
    local stamp="$install_dir/.screenq-freerdp-ios-stamp"
    local expected_stamp="freerdp=$freerdp_version platform=$platform arch=$arch deployment=$deployment_target no-json no-uriparser"

    if [[ ! -f "$openssl_prefix/lib/libssl.a" || ! -f "$openssl_prefix/lib/libcrypto.a" ]]; then
        echo "OpenSSL static libraries are missing for $slice. Run Scripts/build_ios_openssl.sh first." >&2
        exit 1
    fi

    if [[ "$force" -eq 0 && -f "$install_dir/lib/libfreerdp3.a" && -f "$install_dir/lib/libfreerdp-client3.a" && -f "$install_dir/lib/libwinpr3.a" && -f "$stamp" ]] && grep -qx "$expected_stamp" "$stamp"; then
        echo "FreeRDP $slice already built at $install_dir"
        return
    fi

    rm -rf "$build_dir" "$install_dir"
    mkdir -p "$build_dir" "$install_dir"

    cmake -S "$freerdp_source" -B "$build_dir" \
        -DCMAKE_TOOLCHAIN_FILE="$toolchain" \
        -DPLATFORM="$platform" \
        -DARCHS="$arch" \
        -DDEPLOYMENT_TARGET="$deployment_target" \
        -DENABLE_BITCODE=OFF \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$install_dir" \
        -DFREERDP_IOS_EXTERNAL_SSL_PATH="$openssl_prefix" \
        -DFREERDP_UNIFIED_BUILD=ON \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_TESTING=OFF \
        -DBUILD_TESTING_INTERNAL=OFF \
        -DBUILD_BENCHMARK=OFF \
        -DWITH_SAMPLE=OFF \
        -DWITH_MANPAGES=OFF \
        -DWITH_CLIENT_COMMON=ON \
        -DWITH_CLIENT=OFF \
        -DWITH_CLIENT_SDL=OFF \
        -DWITH_CLIENT_IOS=OFF \
        -DWITH_SERVER=OFF \
        -DWITH_SERVER_INTERFACE=OFF \
        -DWITH_CHANNELS=OFF \
        -DWITH_CLIENT_CHANNELS=OFF \
        -DWITH_JSON_DISABLED=ON \
        -DWITH_URIPARSER=OFF \
        -DWITH_X11=OFF \
        -DWITH_WAYLAND=OFF \
        -DWITH_FFMPEG=OFF \
        -DWITH_DSP_FFMPEG=OFF \
        -DWITH_VIDEO_FFMPEG=OFF \
        -DWITH_SWSCALE=OFF \
        -DWITH_CAIRO=OFF \
        -DWITH_OPENH264=OFF \
        -DWITH_OPUS=OFF \
        -DWITH_AAD=OFF \
        -DWITH_KRB5=OFF \
        -DWITH_PCSC=OFF \
        -DWITH_PCSC_WINPR=OFF \
        -DWITH_SMARTCARD_EMULATE=OFF \
        -DWITH_CLANG_FORMAT=OFF \
        -DWITH_CCACHE=OFF

    cmake --build "$build_dir" --target install --parallel "$jobs"
    printf "%s\n" "$expected_stamp" > "$stamp"
    echo "Built FreeRDP $slice at $install_dir"
}

build_bridge_slice() {
    local slice="$1"
    local platform="$2"
    local arch="$3"
    local openssl_prefix="$build_root/ios-deps/openssl/$slice"
    local freerdp_prefix="$build_root/ios-deps/freerdp/$slice"
    local build_dir="$build_root/ScreenQFreeRDPBridge-iOS/$slice"
    local frameworks_dir="$build_root/ScreenQFreeRDPBridge-iOS/frameworks/$slice"
    local framework_output="$frameworks_dir/ScreenQFreeRDPBridge.framework"

    rm -rf "$build_dir" "$frameworks_dir"
    mkdir -p "$build_dir" "$frameworks_dir"

    cmake -S "$repo_root/Vendor/ScreenQFreeRDPBridge" -B "$build_dir" \
        -DCMAKE_TOOLCHAIN_FILE="$toolchain" \
        -DPLATFORM="$platform" \
        -DARCHS="$arch" \
        -DDEPLOYMENT_TARGET="$deployment_target" \
        -DENABLE_BITCODE=OFF \
        -DCMAKE_BUILD_TYPE=Release \
        -DSCREENQ_FREERDP_PREFIX="$freerdp_prefix" \
        -DSCREENQ_OPENSSL_PREFIX="$openssl_prefix"

    cmake --build "$build_dir" --config Release --parallel "$jobs"

    local built_framework="$build_dir/ScreenQFreeRDPBridge.framework"
    if [[ ! -d "$built_framework" ]]; then
        built_framework="$(find "$build_dir" -name ScreenQFreeRDPBridge.framework -type d -print -quit)"
    fi

    if [[ -z "$built_framework" || ! -d "$built_framework" ]]; then
        echo "ScreenQFreeRDPBridge.framework was not produced for $slice" >&2
        exit 1
    fi

    cp -R "$built_framework" "$framework_output"
    echo "Built bridge framework for $slice at $framework_output"
}

build_freerdp_slice "iphoneos-arm64" "OS64" "arm64"
build_freerdp_slice "iphonesimulator-arm64" "SIMULATORARM64" "arm64"

build_bridge_slice "iphoneos-arm64" "OS64" "arm64"
build_bridge_slice "iphonesimulator-arm64" "SIMULATORARM64" "arm64"

dist_dir="$build_root/ScreenQFreeRDPBridge-iOS/dist"
xcframework="$dist_dir/ScreenQFreeRDPBridge.xcframework"
rm -rf "$xcframework"
mkdir -p "$dist_dir"

xcodebuild -create-xcframework \
    -framework "$build_root/ScreenQFreeRDPBridge-iOS/frameworks/iphoneos-arm64/ScreenQFreeRDPBridge.framework" \
    -framework "$build_root/ScreenQFreeRDPBridge-iOS/frameworks/iphonesimulator-arm64/ScreenQFreeRDPBridge.framework" \
    -output "$xcframework"

echo "Built $xcframework"
