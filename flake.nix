# vim: tabstop=2 shiftwidth=2 expandtab autoindent colorcolumn=80
{
  description = "Ubuntu Noble arm64 sysroot builder";

  inputs = {
    nixpkgs.url = "https://channels.nixos.org/nixpkgs-unstable/nixexprs.tar.zst";
  };

  outputs = inputs: {
    packages.aarch64-linux = let
      pkgs = inputs.nixpkgs.legacyPackages.aarch64-linux;
      arm64Ubuntu = "http://ports.ubuntu.com/ubuntu-ports";

      ubuntuKeyring = pkgs.fetchurl {
        url = "${arm64Ubuntu}/project/ubuntu-archive-keyring.gpg";
        hash = "sha256-gKNrCm3i9p9J0t9170c8zeEh6eGQueoB0gpPY3eNXDE=";
      };

      nobleSource = pkgs.writeText "noble-arm64.sources" ''
        Types: deb deb-src
        URIs: ${arm64Ubuntu}
        Suites: noble noble-updates noble-backports noble-security
        Components: main restricted universe multiverse
        Signed-By: ${ubuntuKeyring}
      '';

      toolsPath = pkgs.lib.makeBinPath [
        pkgs.apt
        pkgs.coreutils
        pkgs.dpkg
        pkgs.gnupg
        pkgs.gzip
      ];

      mkRepo = pkgs.writeShellScriptBin "mk-repo" ''
        set -euo pipefail
        export PATH=${toolsPath}:$PATH

        if [ "$#" -lt 2 ]; then
          printf 'usage: %s REPOSITORY PACKAGE...\n' "$0" >&2
          exit 2
        fi

        repo=$1
        shift
        work="$repo.apt"
        ${pkgs.coreutils}/bin/mkdir -p "$repo" "$work/lists/partial" "$work/cache/archives/partial"
        ${pkgs.coreutils}/bin/touch "$work/status"

        apt_args=(
          -o APT::Architecture=arm64
          -o Dir::Bin::dpkg=${pkgs.dpkg}/bin/dpkg
          -o Dir::Bin::gpgv=${pkgs.gnupg}/bin/gpgv
          -o Dir::Etc::sourcelist=${nobleSource}
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

      mkRoot = name: pkgs.writeShellScriptBin name ''
        set -euo pipefail
        export PATH=${toolsPath}:$PATH

        if [ "$#" -lt 3 ]; then
          printf 'usage: %s ROOT REPOSITORY PACKAGE...\n' "$0" >&2
          exit 2
        fi

        root=$1
        repo=$2
        shift 2
        ${mkRepo}/bin/mk-repo "$repo" "$@"

        ${pkgs.coreutils}/bin/mkdir -p "$root"
        for deb in "$repo/"*.deb; do
          ${pkgs.dpkg}/bin/dpkg-deb --extract "$deb" "$root"
        done
      '';

      mkDevRoot = mkRoot "mk-devroot";
      mkRelRoot = mkRoot "mk-relroot";
    in {
      inherit mkDevRoot mkRelRoot mkRepo nobleSource ubuntuKeyring;
      default = mkDevRoot;
    };
  };
}
