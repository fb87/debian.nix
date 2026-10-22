# Debian.nix

Nix-based Ubuntu Noble sysroot and cross-toolchain builder. The generated
toolchains target `aarch64-linux` or `x86_64-linux` and use persistent local
APT repositories.

## Requirements

- Nix with flakes enabled
- A Linux host running `aarch64-linux` or `x86_64-linux`
- Network access to the Ubuntu repositories on the first run

## Build A Toolchain

`mkCrossToolchain` is the main public command:

```sh
nix run .#mkCrossToolchain -- TOOLCHAIN_DIR TARGET_SYSTEM SUITE PACKAGE...
```

For example, create an AArch64 development toolchain from Ubuntu Noble:

```sh
nix run .#mkCrossToolchain -- ./toolchain aarch64-linux noble \
  build-essential cmake zlib1g-dev
```

The command creates:

- `environment`: compiler and sysroot environment variables
- `<target-triplet>.cmake`: CMake toolchain file
- `<target>-root`: target sysroot
- `<target>-repo`: persistent target package repository
- `host-root`: host compiler and binutils environment

Use the generated environment for application builds:

```sh
. ./toolchain/environment
cmake -S . -B build -DCMAKE_TOOLCHAIN_FILE=./toolchain/aarch64-linux-gnu.cmake
cmake --build build
```

Package archives and APT metadata remain in the repository directories, so
subsequent invocations reuse already downloaded packages.

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
