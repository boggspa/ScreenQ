#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_dir="$repo_root/Vendor/ScreenQFreeRDPBridge"
physical_build_root="$repo_root/.build"
build_dir="$physical_build_root/ScreenQFreeRDPBridge"
dist_dir="$build_dir/dist"
install_app=""
freerdp_version="${FREERDP_VERSION:-3.25.0}"
deployment_target="${DEPLOYMENT_TARGET:-14.0}"
jobs="${JOBS:-$(sysctl -n hw.ncpu)}"
arch="${ARCH:-$(uname -m)}"
force=0
skip_openssl=0
dynamic_homebrew=0
freerdp_source=""
universal=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --install-to-app)
            install_app="${2:-}"
            shift 2
            ;;
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
        --arch)
            arch="${2:-}"
            shift 2
            ;;
        --dynamic-homebrew)
            dynamic_homebrew=1
            shift
            ;;
        --universal)
            universal=1
            shift
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

if [[ -z "$deployment_target" || -z "$freerdp_version" || -z "$arch" ]]; then
    echo "deployment target, FreeRDP version, and architecture must be non-empty" >&2
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

if [[ "$universal" -eq 1 ]]; then
    if [[ "$dynamic_homebrew" -eq 1 ]]; then
        echo "--universal is only supported for the self-contained static bridge, not --dynamic-homebrew." >&2
        exit 2
    fi

    universal_slice_dir="$physical_build_root/ScreenQFreeRDPBridge-universal-slices"
    mkdir -p "$dist_dir" "$universal_slice_dir"

    for slice_arch in arm64 x86_64; do
        slice_args=(
            --arch "$slice_arch"
            --deployment-target "$deployment_target"
            --freerdp-version "$freerdp_version"
        )
        if [[ "$force" -eq 1 ]]; then
            slice_args+=(--force)
        fi
        if [[ "$skip_openssl" -eq 1 ]]; then
            slice_args+=(--skip-openssl)
        fi
        if [[ -n "$freerdp_source" ]]; then
            slice_args+=(--freerdp-source "$freerdp_source")
        fi

        "$0" "${slice_args[@]}"
        cp "$dist_dir/libScreenQFreeRDPBridge.dylib" "$universal_slice_dir/libScreenQFreeRDPBridge-$slice_arch.dylib"
    done

    lipo -create \
        "$universal_slice_dir/libScreenQFreeRDPBridge-arm64.dylib" \
        "$universal_slice_dir/libScreenQFreeRDPBridge-x86_64.dylib" \
        -output "$dist_dir/libScreenQFreeRDPBridge.dylib"

    echo "Built universal $dist_dir/libScreenQFreeRDPBridge.dylib"

    if [[ -n "$install_app" ]]; then
        frameworks_dir="$install_app/Contents/Frameworks"
        if [[ ! -d "$install_app" ]]; then
            echo "App bundle not found: $install_app" >&2
            exit 1
        fi
        mkdir -p "$frameworks_dir"
        cp "$dist_dir/libScreenQFreeRDPBridge.dylib" "$frameworks_dir/libScreenQFreeRDPBridge.dylib"
        echo "Installed bridge into $frameworks_dir"
    fi

    exit 0
fi

if [[ "$dynamic_homebrew" -eq 1 ]]; then
    if ! command -v pkg-config >/dev/null 2>&1; then
        echo "pkg-config is required. Install FreeRDP with Homebrew first: brew install freerdp" >&2
        exit 1
    fi

    if ! pkg-config --exists freerdp3 winpr3 freerdp-client3; then
        echo "FreeRDP 3 pkg-config metadata was not found. Install it with: brew install freerdp" >&2
        exit 1
    fi

    rm -rf "$build_dir"
    cmake -S "$source_dir" -B "$build_dir" \
        -DCMAKE_BUILD_TYPE=RelWithDebInfo \
        -DCMAKE_OSX_ARCHITECTURES="$arch" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$deployment_target"
    cmake --build "$build_dir" --config RelWithDebInfo --parallel "$jobs"
else
    if [[ -z "$freerdp_source" ]]; then
        freerdp_source="$build_root/FreeRDP-$freerdp_version-src"
    fi

    if [[ ! -d "$freerdp_source" ]]; then
        git clone --depth 1 --branch "$freerdp_version" https://github.com/FreeRDP/FreeRDP.git "$freerdp_source"
    fi

    if [[ "$skip_openssl" -eq 0 ]]; then
        openssl_args=(--deployment-target "$deployment_target" --arch "$arch")
        if [[ "$force" -eq 1 ]]; then
            openssl_args+=(--force)
        fi
        "$repo_root/Scripts/build_macos_openssl.sh" "${openssl_args[@]}"
    fi

    openssl_prefix="$build_root/macos-deps/openssl/$arch"
    freerdp_prefix="$build_root/macos-deps/freerdp/$arch"
    freerdp_build_dir="$build_root/freerdp-macos/$arch"
    freerdp_stamp="$freerdp_prefix/.screenq-freerdp-macos-stamp"
    expected_freerdp_stamp="freerdp=$freerdp_version arch=$arch deployment=$deployment_target no-json no-uriparser"

    if [[ ! -f "$openssl_prefix/lib/libssl.a" || ! -f "$openssl_prefix/lib/libcrypto.a" ]]; then
        echo "OpenSSL static libraries are missing for macOS $arch. Run Scripts/build_macos_openssl.sh first." >&2
        exit 1
    fi

    if [[ "$force" -eq 1 || ! -f "$freerdp_prefix/lib/libfreerdp3.a" || ! -f "$freerdp_prefix/lib/libfreerdp-client3.a" || ! -f "$freerdp_prefix/lib/libwinpr3.a" || ! -f "$freerdp_stamp" ]] || ! grep -qx "$expected_freerdp_stamp" "$freerdp_stamp"; then
        rm -rf "$freerdp_build_dir" "$freerdp_prefix"
        mkdir -p "$freerdp_build_dir" "$freerdp_prefix"

        cmake -S "$freerdp_source" -B "$freerdp_build_dir" \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_INSTALL_PREFIX="$freerdp_prefix" \
            -DCMAKE_OSX_ARCHITECTURES="$arch" \
            -DCMAKE_OSX_DEPLOYMENT_TARGET="$deployment_target" \
            -DCMAKE_PREFIX_PATH="$openssl_prefix" \
            -DOPENSSL_ROOT_DIR="$openssl_prefix" \
            -DOPENSSL_USE_STATIC_LIBS=TRUE \
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

        cmake --build "$freerdp_build_dir" --target install --parallel "$jobs"
        printf "%s\n" "$expected_freerdp_stamp" > "$freerdp_stamp"
        echo "Built FreeRDP macOS $arch at $freerdp_prefix"
    else
        echo "FreeRDP macOS $arch already built at $freerdp_prefix"
    fi

    rm -rf "$build_dir"
    cmake -S "$source_dir" -B "$build_dir" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES="$arch" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$deployment_target" \
        -DSCREENQ_FREERDP_PREFIX="$freerdp_prefix" \
        -DSCREENQ_OPENSSL_PREFIX="$openssl_prefix"
    cmake --build "$build_dir" --config Release --parallel "$jobs"
fi

mkdir -p "$dist_dir"
cp "$build_dir/libScreenQFreeRDPBridge.dylib" "$dist_dir/libScreenQFreeRDPBridge.dylib"

echo "Built $dist_dir/libScreenQFreeRDPBridge.dylib"

if [[ -n "$install_app" ]]; then
    frameworks_dir="$install_app/Contents/Frameworks"
    if [[ ! -d "$install_app" ]]; then
        echo "App bundle not found: $install_app" >&2
        exit 1
    fi
    mkdir -p "$frameworks_dir"
    cp "$dist_dir/libScreenQFreeRDPBridge.dylib" "$frameworks_dir/libScreenQFreeRDPBridge.dylib"
    echo "Installed bridge into $frameworks_dir"
fi
