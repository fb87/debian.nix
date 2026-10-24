# Debian.nix

Nix-based Ubuntu Noble sysroot and cross-toolchain builder. The generated
toolchains target `aarch64-linux` or `x86_64-linux` and use persistent local
APT repositories.

## Requirements

- Nix with flakes enabled
- A Linux host running `aarch64-linux` or `x86_64-linux`
- Network access to the Ubuntu repositories on the first run

## Build A Toolchain

`mk-sdk` is the main public command:

```sh
nix run .#mk-sdk -- TOOLCHAIN_DIR TARGET_SYSTEM SUITE \
  [--packages FILE] PACKAGE...
```

Create an AArch64 SDK from Ubuntu Noble:

```sh
nix run .#mk-sdk -- ./sdk aarch64-linux noble \
  --packages sdk-packages.txt
```

The package file is optional. Packages can be supplied directly when a
separate file is unnecessary:

```sh
nix run .#mk-sdk -- ./sdk aarch64-linux noble zlib1g zlib1g-dev
```

Unprefixed command-line packages are included in both the sysroot and the
runtime rootfs. Runtime and development categories can also be explicit:

```sh
nix run .#mk-sdk -- ./sdk aarch64-linux noble \
  runtime:zlib1g development:zlib1g-dev
```

The package file uses one package per line and separates deployment packages
from development packages:

```text
# Packages included in rootfs.tar.gz and sysroot/
runtime: zlib1g
runtime: libusb-1.0-0

# Packages included only in sysroot/
development: build-essential
development: cmake
development: zlib1g-dev
development: libusb-1.0-0-dev
```

Blank lines and lines beginning with `#` are ignored.

The command creates:

- `environment`: compiler and sysroot environment variables
- `<target-triplet>.cmake`: CMake toolchain file
- `sysroot/`: target development sysroot
- `rootfs.tar.gz`: runtime-only root filesystem ready for deployment
- `host-root`: host compiler and binutils environment

The bundle is written next to the SDK directory. For example, building
`./sdk` produces `./sdk.tar.gz`. Share that archive with another compatible
Linux machine and extract it to reuse the SDK without Nix or package
resolution:

```sh
tar -xzf sdk.tar.gz
cd sdk
. ./environment
```

Use the generated environment for application builds:

```sh
. ./sdk/environment
cmake -S . -B build -DCMAKE_TOOLCHAIN_FILE=./sdk/aarch64-linux-gnu.cmake
cmake --build build
```

Package archives and APT metadata are stored in a shared cache. Set
`DEBIAN_NIX_CACHE` to choose its location; otherwise
`$XDG_CACHE_HOME/debian.nix` or `$HOME/.cache/debian.nix` is used. This cache
is shared across SDKs and prevents package downloads from being repeated.

Deploy the runtime filesystem with:

```sh
mkdir deploy-root
tar -xzf ./sdk/rootfs.tar.gz -C deploy-root
```

## Self-Test

The self-test builds a toolchain, cross-compiles a hello program, and verifies
its ELF architecture:

```sh
nix run .#selfTest -- ./toolchain aarch64-linux noble
nix run .#selfTest -- ./toolchain-x86_64 x86_64-linux noble
```

Supported target systems are `aarch64-linux` and `x86_64-linux`.

## License

MIT. See [LICENSE](LICENSE).
