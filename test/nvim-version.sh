#!/bin/sh
# Download a Neovim release once into .cache/nvim/<version>/ and print the
# path of its nvim binary, for running the suite against that version:
#   NVIM=$(test/nvim-version.sh v0.12.0) test/run.sh
# Usage: test/nvim-version.sh <version tag, e.g. v0.10.4>
# Linux x86_64 and arm64 only. CI's versions: .github/workflows/test.yml.
set -eu

version=${1:?usage: test/nvim-version.sh <version tag, e.g. v0.10.4>}
case $version in v*) ;; *) version=v$version ;; esac
root=$(cd "$(dirname "$0")/.." && pwd)
dir=$root/.cache/nvim/$version

case $(uname -m) in
  x86_64) arches='x86_64 64' ;;
  aarch64 | arm64) arches='arm64' ;;
  *) echo "nvim-version.sh: unsupported machine $(uname -m)" >&2; exit 2 ;;
esac

bin=$(find "$dir" -path '*/bin/nvim' -type f 2>/dev/null | head -n 1)
if [ -z "$bin" ]; then
  mkdir -p "$dir"
  # Asset names changed in v0.10.4: nvim-linux64 became nvim-linux-x86_64.
  for arch in $arches; do
    case $arch in 64) asset=nvim-linux64 ;; *) asset=nvim-linux-$arch ;; esac
    url=https://github.com/neovim/neovim/releases/download/$version/$asset.tar.gz
    if curl -sSfL -o "$dir/nvim.tar.gz" "$url" 2>/dev/null; then
      tar xzf "$dir/nvim.tar.gz" -C "$dir"
      rm -f "$dir/nvim.tar.gz"
      break
    fi
  done
  bin=$(find "$dir" -path '*/bin/nvim' -type f | head -n 1)
  [ -n "$bin" ] || { echo "nvim-version.sh: no Linux release asset for $version" >&2; rm -rf "$dir"; exit 1; }
fi
echo "$bin"
