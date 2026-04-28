#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
physical_build_root="$repo_root/.build"
openssl_version="${OPENSSL_VERSION:-3.6.2}"
deployment_target="${DEPLOYMENT_TARGET:-14.0}"
jobs="${JOBS:-$(sysctl -n hw.ncpu)}"
force=0
arch="${ARCH:-$(uname -m)}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)
            force=1
            shift
            ;;
        --deployment-target)
            deployment_target="${2:-}"
            shift 2
            ;;
        --openssl-version)
            openssl_version="${2:-}"
            shift 2
            ;;
        --arch)
            arch="${2:-}"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

if [[ -z "$deployment_target" || -z "$openssl_version" || -z "$arch" ]]; then
    echo "deployment target, OpenSSL version, and architecture must be non-empty" >&2
    exit 2
fi

case "$arch" in
    arm64)
        configure_target="darwin64-arm64-cc"
        ;;
    x86_64)
        configure_target="darwin64-x86_64-cc"
        ;;
    *)
        echo "Unsupported macOS architecture for OpenSSL: $arch" >&2
        exit 2
        ;;
esac

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

archive="$build_root/openssl-$openssl_version.tar.gz"
source_dir="$build_root/openssl-$openssl_version"

if [[ ! -d "$source_dir" ]]; then
    if [[ ! -f "$archive" ]]; then
        curl -L "https://www.openssl.org/source/openssl-$openssl_version.tar.gz" -o "$archive"
    fi
    tar -xzf "$archive" -C "$build_root"
fi

build_dir="$build_root/openssl-macos/$arch"
install_dir="$build_root/macos-deps/openssl/$arch"
stamp="$install_dir/.screenq-openssl-macos-stamp"
min_version_flag="-mmacosx-version-min=$deployment_target"
expected_stamp="openssl=$openssl_version target=$configure_target arch=$arch deployment=$deployment_target no-quic $min_version_flag"

if [[ "$force" -eq 0 && -f "$install_dir/lib/libssl.a" && -f "$install_dir/lib/libcrypto.a" && -f "$stamp" ]] && grep -qx "$expected_stamp" "$stamp"; then
    echo "OpenSSL macOS $arch already built at $install_dir"
    exit 0
fi

rm -rf "$build_dir" "$install_dir"
mkdir -p "$build_dir" "$install_dir"

pushd "$build_dir" >/dev/null
CFLAGS="$min_version_flag -arch $arch" \
    LDFLAGS="$min_version_flag -arch $arch" \
    "$source_dir/Configure" "$configure_target" \
    no-shared no-tests no-async no-ui-console no-module no-dso no-apps no-quic \
    --prefix="$install_dir" \
    --openssldir="$install_dir/ssl"
make -s -j"$jobs"
make -s install_sw
popd >/dev/null

printf "%s\n" "$expected_stamp" > "$stamp"
echo "Built OpenSSL macOS $arch at $install_dir"
