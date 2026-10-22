# vim: tabstop=2 shiftwidth=2 expandtab autoindent colorcolumn=80
{
  description = "Ubuntu Noble sysroot and cross-toolchain builder";

  inputs = {
    flake-utils.url = "github:numtide/flake-utils";
    nixpkgs.url = "https://channels.nixos.org/nixpkgs-unstable/nixexprs.tar.zst";
  };

  outputs = inputs:
    inputs.flake-utils.lib.eachSystem [ "aarch64-linux" "x86_64-linux" ] (system: {
      packages = let
        pkgs = inputs.nixpkgs.legacyPackages.${system};
        architectures = {
          "aarch64-linux" = {
            debian = "arm64";
            ubuntu = "http://ports.ubuntu.com/ubuntu-ports";
            triple = "aarch64-linux-gnu";
            processor = "aarch64";
            loader = "ld-linux-aarch64.so.1";
          };
          "x86_64-linux" = {
            debian = "amd64";
            ubuntu = "http://archive.ubuntu.com/ubuntu";
            triple = "x86_64-linux-gnu";
            processor = "x86_64";
            loader = "ld-linux-x86-64.so.2";
          };
        };
        native = architectures.${system};

        fetchUbuntuKeyring = ubuntu: pkgs.fetchurl {
          url = "${ubuntu}/project/ubuntu-archive-keyring.gpg";
          hash = "sha256-gKNrCm3i9p9J0t9170c8zeEh6eGQueoB0gpPY3eNXDE=";
        };

        arm64Keyring = fetchUbuntuKeyring architectures.aarch64-linux.ubuntu;
        amd64Keyring = fetchUbuntuKeyring architectures.x86_64-linux.ubuntu;

        toolsPath = pkgs.lib.makeBinPath [
          pkgs.apt
          pkgs.coreutils
          pkgs.dpkg
          pkgs.gnupg
          pkgs.gnugrep
          pkgs.gnused
          pkgs.gzip
        ];

        mkRepo = name: architecture: ubuntu: keyring: pkgs.writeShellScriptBin name ''
        set -euo pipefail
        export PATH=${toolsPath}:$PATH

        if [ "$#" -lt 3 ]; then
          printf 'usage: %s REPOSITORY SUITE PACKAGE...\n' "$0" >&2
          exit 2
        fi

        repo=$1
        suite=$2
        shift 2
        work="$repo.apt"
        ${pkgs.coreutils}/bin/mkdir -p "$repo" "$work/lists/partial" "$work/cache/archives/partial"
        ${pkgs.coreutils}/bin/touch "$work/status"
        source="$work/$suite.sources"
        ${pkgs.coreutils}/bin/cat > "$source" <<EOF
        Types: deb deb-src
        URIs: ${ubuntu}
        Suites: ''${suite} ''${suite}-updates ''${suite}-backports ''${suite}-security
        Components: main restricted universe multiverse
        Signed-By: ${keyring}
        EOF

        apt_args=(
          -o APT::Architecture=${architecture}
          -o Dir::Bin::dpkg=${pkgs.dpkg}/bin/dpkg
          -o Dir::Bin::gpgv=${pkgs.gnupg}/bin/gpgv
          -o Dir::Etc::sourcelist="$source"
          -o Dir::Etc::sourceparts=-
          -o Dir::State::status="$work/status"
          -o Dir::State::lists="$work/lists"
          -o Dir::Cache::archives="$work/cache/archives"
          -o Dir::Cache::srcpkgcache="$work/srcpkgcache"
          -o Dir::Cache::pkgcache="$work/pkgcache"
        )

        ${pkgs.apt}/bin/apt-get "''${apt_args[@]}" update
        ${pkgs.apt}/bin/apt-get "''${apt_args[@]}" --yes --download-only install "$@"

        debs=("$work/cache/archives/"*.deb)
        if [ "''${#debs[@]}" -eq 0 ]; then
          printf 'apt-get did not download any packages\n' >&2
          exit 1
        fi
        ${pkgs.coreutils}/bin/cp -f "''${debs[@]}" "$repo/"
        (
          cd "$repo"
          ${pkgs.dpkg}/bin/dpkg-scanpackages . /dev/null |
            ${pkgs.gzip}/bin/gzip -9 > Packages.gz
        )
        '';

        mkRoot = name: repo: repoName: pkgs.writeShellScriptBin name ''
        set -euo pipefail
        export PATH=${toolsPath}:$PATH

        if [ "$#" -lt 4 ]; then
          printf 'usage: %s ROOT REPOSITORY SUITE PACKAGE...\n' "$0" >&2
          exit 2
        fi

        root=$1
        repo=$2
        suite=$3
        shift 3
        ${repo}/bin/${repoName} "$repo" "$suite" "$@"

        ${pkgs.coreutils}/bin/mkdir -p "$root"
        for deb in "$repo/"*.deb; do
          ${pkgs.dpkg}/bin/dpkg-deb --extract "$deb" "$root"
        done
        '';

        nativeRepo = if native.debian == "arm64" then
          mkRepo "mk-repo" native.debian native.ubuntu arm64Keyring
        else
          mkRepo "mk-repo" native.debian native.ubuntu amd64Keyring;
        arm64Repo = mkRepo "mk-arm64-repo" "arm64"
          architectures.aarch64-linux.ubuntu arm64Keyring;
        amd64Repo = mkRepo "mk-amd64-repo" "amd64"
          architectures.x86_64-linux.ubuntu amd64Keyring;
        mkDevRoot = mkRoot "mk-devroot" nativeRepo "mk-repo";
        mkArm64DevRoot = mkRoot "mk-arm64-devroot" arm64Repo "mk-arm64-repo";
        mkAmd64DevRoot = mkRoot "mk-amd64-devroot" amd64Repo "mk-amd64-repo";
        mkCrossToolchain = pkgs.writeShellScriptBin "mk-cross-toolchain" ''
          set -euo pipefail

           if [ "$#" -lt 4 ]; then
             printf 'usage: %s TOOLCHAIN_DIR TARGET_SYSTEM SUITE PACKAGE...\n' "$0" >&2
            exit 2
          fi

          toolchain_dir=$1
          if [ ! -d "$toolchain_dir" ]; then
            ${pkgs.coreutils}/bin/mkdir -p "$toolchain_dir"
          fi
          toolchain_dir=$(${pkgs.coreutils}/bin/realpath "$toolchain_dir")
           shift
           target_system=$1
           shift
           suite=$1
           shift

          host_repo="$toolchain_dir/host-repo"
          host_root="$toolchain_dir/host-root"

          system=${system}
          case "$system" in
            x86_64-linux)
              host_triple=x86_64-linux-gnu
              host_loader=ld-linux-x86-64.so.2
              ;;
            aarch64-linux)
              host_triple=aarch64-linux-gnu
              host_loader=ld-linux-aarch64.so.1
              ;;
            *)
              printf 'unsupported host system: %s\n' "$system" >&2
              exit 1
              ;;
          esac

          case "$target_system" in
            aarch64-linux)
              target_debian=arm64
              target_triple=aarch64-linux-gnu
              target_processor=aarch64
              target_loader=ld-linux-aarch64.so.1
              target_repo="$toolchain_dir/arm64-repo"
              target_root="$toolchain_dir/arm64-root"
              target_builder=${mkArm64DevRoot}/bin/mk-arm64-devroot
              ;;
            x86_64-linux)
              target_debian=amd64
              target_triple=x86_64-linux-gnu
              target_processor=x86_64
              target_loader=ld-linux-x86-64.so.2
              target_repo="$toolchain_dir/amd64-repo"
              target_root="$toolchain_dir/amd64-root"
              target_builder=${mkAmd64DevRoot}/bin/mk-amd64-devroot
              ;;
            *)
             printf 'unsupported target system: %s\n' "$target_system" >&2
               exit 1
               ;;
           esac

           toolchain_file="$toolchain_dir/$target_triple.cmake"
          wrapper_dir="$toolchain_dir/bin"

          if [ "$system" = "$target_system" ]; then
            host_packages=(build-essential)
            compiler_name=gcc
            cxx_compiler_name=g++
            host_tool_prefix=
            cross_compile_prefix=
          else
            host_packages=(crossbuild-essential-"$target_debian")
            compiler_name="$target_triple-gcc"
            cxx_compiler_name="$target_triple-g++"
            host_tool_prefix="$target_triple-"
            cross_compile_prefix="$wrapper_dir/$target_triple-"
          fi

            ${mkDevRoot}/bin/mk-devroot "$host_root" "$host_repo" \
              "$suite" \
              "''${host_packages[@]}"

           for linker_script in "$host_root/usr/$target_triple/lib/"*.so; do
             if [ -f "$linker_script" ] &&
                ${pkgs.gnugrep}/bin/grep -q '^GROUP (' "$linker_script"; then
               ${pkgs.gnused}/bin/sed -i \
                 -e "s# /usr/$target_triple/# $host_root/usr/$target_triple/#g" \
                 -e "s# /lib64/# $host_root/lib64/#g" \
                 "$linker_script"
             fi
           done

           ${pkgs.coreutils}/bin/mkdir -p "$wrapper_dir"
           host_loader_path="$host_root/usr/lib/$host_triple/$host_loader"
           host_library_path="$host_root/usr/lib/$host_triple:$host_root/usr/lib"
           ${pkgs.coreutils}/bin/mkdir -p "$host_root/lib"
           if [ ! -e "$host_root/lib/$host_triple" ] &&
              [ ! -L "$host_root/lib/$host_triple" ]; then
             ${pkgs.coreutils}/bin/ln -s ../usr/lib/$host_triple \
               "$host_root/lib/$host_triple"
           fi
           if [ ! -e "$host_root/lib/$host_loader" ] &&
              [ ! -L "$host_root/lib/$host_loader" ]; then
             ${pkgs.coreutils}/bin/ln -s \
               ../usr/lib/$host_triple/$host_loader \
               "$host_root/lib/$host_loader"
           fi
           if [ "$host_triple" = x86_64-linux-gnu ]; then
             ${pkgs.coreutils}/bin/mkdir -p "$host_root/lib64"
             if [ ! -e "$host_root/lib64/$host_loader" ] &&
                [ ! -L "$host_root/lib64/$host_loader" ]; then
               ${pkgs.coreutils}/bin/ln -s \
                 ../usr/lib/$host_triple/$host_loader \
                 "$host_root/lib64/$host_loader"
             fi
           fi

           for linker_script in \
             "$host_root/usr/lib/$host_triple/"*.so \
             "$host_root/usr/$host_triple/lib/"*.so; do
             if [ -f "$linker_script" ] &&
                ${pkgs.gnugrep}/bin/grep -q '^GROUP (' "$linker_script"; then
               ${pkgs.gnused}/bin/sed -i \
                 -e "s# /lib/# $host_root/lib/#g" \
                 -e "s# /usr/lib/# $host_root/usr/lib/#g" \
                 -e "s# /usr/$host_triple/# $host_root/usr/$host_triple/#g" \
                 -e "s# /lib64/# $host_root/lib64/#g" \
                 "$linker_script"
             fi
           done

           ${pkgs.coreutils}/bin/cat > "$wrapper_dir/tool-wrapper" <<EOF
          #!/bin/sh
          set -eu
          case "\$1" in
            "$wrapper_dir/"*)
              exec "\$@"
              ;;
          esac
           exec "$host_loader_path" --library-path "$host_library_path" "\$@"
          EOF

          ${pkgs.coreutils}/bin/cat > "$wrapper_dir/gcc" <<EOF
          #!/bin/sh
          set -eu
          exec "$host_loader_path" --library-path "$host_library_path" \\
            "$host_root/usr/bin/$compiler_name" \\
            -wrapper "$wrapper_dir/tool-wrapper" "\$@"
          EOF

          ${pkgs.coreutils}/bin/cat > "$wrapper_dir/g++" <<EOF
          #!/bin/sh
          set -eu
          exec "$host_loader_path" --library-path "$host_library_path" \\
            "$host_root/usr/bin/$cxx_compiler_name" \\
            -wrapper "$wrapper_dir/tool-wrapper" "\$@"
          EOF

          ${pkgs.coreutils}/bin/cat > "$wrapper_dir/binutils-wrapper" <<EOF
          #!/bin/sh
          set -eu
          name=\$(basename "\$0")
          case "\$name" in
            "$target_triple-as") name=as ;;
            "$target_triple-ld") name=ld ;;
            "$target_triple-ar") name=ar ;;
            "$target_triple-ranlib") name=ranlib ;;
            "$target_triple-strip") name=strip ;;
            "$target_triple-objcopy") name=objcopy ;;
            "$target_triple-nm") name=nm ;;
            "$target_triple-objdump") name=objdump ;;
            "$target_triple-readelf") name=readelf ;;
          esac
          [ "\$name" = ld ] && name=ld.bfd
          exec "$host_loader_path" --library-path "$host_library_path" \\
            "$host_root/usr/bin/$host_tool_prefix\$name" "\$@"
          EOF

          for tool in as ld ar ranlib strip objcopy nm objdump readelf; do
            ${pkgs.coreutils}/bin/ln -sf binutils-wrapper "$wrapper_dir/$tool"
            ${pkgs.coreutils}/bin/ln -sf binutils-wrapper \
              "$wrapper_dir/$target_triple-$tool"
          done

          ${pkgs.coreutils}/bin/chmod 755 \
            "$wrapper_dir/gcc" "$wrapper_dir/g++" \
            "$wrapper_dir/tool-wrapper" "$wrapper_dir/binutils-wrapper"
           c_compiler="$wrapper_dir/gcc"
           cxx_compiler="$wrapper_dir/g++"
           "$target_builder" "$target_root" "$target_repo" "$suite" "$@"

           target_arch=x86
           [ "$target_debian" = arm64 ] && target_arch=arm64
           ${pkgs.coreutils}/bin/mkdir -p "$target_root/lib"
           if [ ! -e "$target_root/lib/$target_triple" ] &&
              [ ! -L "$target_root/lib/$target_triple" ]; then
             ${pkgs.coreutils}/bin/ln -s ../usr/lib/$target_triple \
               "$target_root/lib/$target_triple"
           fi
           if [ ! -e "$target_root/lib/$target_loader" ] &&
              [ ! -L "$target_root/lib/$target_loader" ]; then
             ${pkgs.coreutils}/bin/ln -s \
               ../usr/lib/$target_triple/$target_loader \
               "$target_root/lib/$target_loader"
           fi
           if [ "$target_debian" = amd64 ]; then
             ${pkgs.coreutils}/bin/mkdir -p "$target_root/lib64"
             if [ ! -e "$target_root/lib64/$target_loader" ] &&
                [ ! -L "$target_root/lib64/$target_loader" ]; then
               ${pkgs.coreutils}/bin/ln -s \
                 ../usr/lib/$target_triple/$target_loader \
                 "$target_root/lib64/$target_loader"
             fi
           fi
           ${pkgs.coreutils}/bin/cat > "$toolchain_dir/environment" <<EOF
          export TOOLCHAIN_ROOT="$toolchain_dir"
          export SYSROOT="$target_root"
          export ARCH="$target_arch"
          export CROSS_COMPILE="$cross_compile_prefix"
          export CC="$c_compiler"
          export CXX="$cxx_compiler"
          export CPP="$c_compiler -E"
          export AR="$wrapper_dir/ar"
          export AS="$wrapper_dir/as"
          export LD="$wrapper_dir/ld"
          export NM="$wrapper_dir/nm"
          export OBJCOPY="$wrapper_dir/objcopy"
          export OBJDUMP="$wrapper_dir/objdump"
          export RANLIB="$wrapper_dir/ranlib"
          export READELF="$wrapper_dir/readelf"
          export STRIP="$wrapper_dir/strip"
          export PKG_CONFIG_SYSROOT_DIR="$target_root"
          export PKG_CONFIG_LIBDIR="$target_root/usr/lib/$target_triple/pkgconfig:$target_root/usr/share/pkgconfig"
          export PKG_CONFIG_PATH=
          export PATH="$wrapper_dir:\$PATH"
           export CFLAGS="-B$wrapper_dir --sysroot=$target_root"
           export CXXFLAGS="-B$wrapper_dir --sysroot=$target_root"
          export LDFLAGS="-B$wrapper_dir -L$target_root/usr/$target_triple/lib -L$target_root/usr/lib/$target_triple -Wl,-rpath-link,$target_root/usr/lib/$target_triple"
          EOF

          ${pkgs.coreutils}/bin/mkdir -p \
            "$target_root/lib" "$target_root/usr/$target_triple"
          if [ ! -e "$target_root/lib/$target_triple" ] &&
             [ ! -L "$target_root/lib/$target_triple" ]; then
            ${pkgs.coreutils}/bin/ln -s ../usr/lib/$target_triple \
              "$target_root/lib/$target_triple"
          fi
          if [ ! -e "$target_root/usr/$target_triple/lib" ] &&
             [ ! -L "$target_root/usr/$target_triple/lib" ]; then
            ${pkgs.coreutils}/bin/ln -s ../../lib/$target_triple \
              "$target_root/usr/$target_triple/lib"
          fi
          if [ ! -e "$target_root/lib/$target_loader" ] &&
             [ ! -L "$target_root/lib/$target_loader" ]; then
            ${pkgs.coreutils}/bin/ln -s \
              ../usr/lib/$target_triple/$target_loader \
              "$target_root/lib/$target_loader"
          fi
          if [ "$target_debian" = amd64 ]; then
            ${pkgs.coreutils}/bin/mkdir -p "$target_root/lib64"
            if [ ! -e "$target_root/lib64/$target_loader" ] &&
               [ ! -L "$target_root/lib64/$target_loader" ]; then
              ${pkgs.coreutils}/bin/ln -s \
                ../usr/lib/$target_triple/$target_loader \
                "$target_root/lib64/$target_loader"
            fi
          fi

          ${pkgs.coreutils}/bin/cat > "$toolchain_file" <<EOF
          set(CMAKE_SYSTEM_NAME Linux)
          set(CMAKE_SYSTEM_PROCESSOR $target_processor)
          set(CMAKE_LIBRARY_ARCHITECTURE $target_triple)

           set(CMAKE_C_COMPILER "$c_compiler")
           set(CMAKE_CXX_COMPILER "$cxx_compiler")
           set(CMAKE_C_FLAGS_INIT
               "-B$wrapper_dir --sysroot=$target_root -L$target_root/usr/$target_triple/lib -L$target_root/usr/lib/$target_triple -Wl,-rpath-link,$target_root/usr/lib/$target_triple")
           set(CMAKE_CXX_FLAGS_INIT
               "-B$wrapper_dir --sysroot=$target_root -L$target_root/usr/$target_triple/lib -L$target_root/usr/lib/$target_triple -Wl,-rpath-link,$target_root/usr/lib/$target_triple")
           set(CMAKE_EXE_LINKER_FLAGS_INIT
               "-B$wrapper_dir --sysroot=$target_root -L$target_root/usr/$target_triple/lib -L$target_root/usr/lib/$target_triple -Wl,-rpath-link,$target_root/usr/lib/$target_triple")
           set(CMAKE_FIND_ROOT_PATH "$target_root")
          set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
          set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
          set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
          set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

          set(ENV{PKG_CONFIG_SYSROOT_DIR} "$target_root")
          set(ENV{PKG_CONFIG_LIBDIR}
              "$target_root/usr/lib/$target_triple/pkgconfig:$target_root/usr/share/pkgconfig")
           set(ENV{PKG_CONFIG_PATH} "")
          EOF
         '';

         selfTest = pkgs.writeShellScriptBin "self-test" ''
           set -euo pipefail

           if [ "$#" -lt 3 ]; then
             printf 'usage: %s TOOLCHAIN_DIR TARGET_SYSTEM SUITE\n' "$0" >&2
             exit 2
           fi

           toolchain_dir=$1
           target_system=$2
           suite=$3
           work=$(${pkgs.coreutils}/bin/mktemp -d)
           trap '${pkgs.coreutils}/bin/rm -rf "$work"' EXIT

           ${mkCrossToolchain}/bin/mk-cross-toolchain \
             "$toolchain_dir" "$target_system" "$suite" zlib1g-dev

           # Compile a target binary through the generated environment.
           . "$toolchain_dir/environment"
           ${pkgs.coreutils}/bin/printf '%s\n' \
             'int main(void) { return 0; }' > "$work/hello.c"
           "$CC" $CFLAGS "$work/hello.c" -o "$work/hello"

           machine=$(${pkgs.binutils}/bin/readelf -h "$work/hello" |
             ${pkgs.gnugrep}/bin/grep '^  Machine:' |
             ${pkgs.coreutils}/bin/cut -d: -f2- |
             ${pkgs.coreutils}/bin/tr -d '[:space:]')
           case "$target_system:$machine" in
             aarch64-linux:AArch64|x86_64-linux:AdvancedMicroDevicesX86-64)
               printf 'self-test passed: %s (%s)\n' "$target_system" "$machine"
               ;;
             *)
               printf 'unexpected target machine: %s (%s)\n' "$target_system" "$machine" >&2
               exit 1
               ;;
           esac
         '';
      in {
        inherit mkCrossToolchain selfTest;
      };
    });
}
