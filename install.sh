#!/bin/sh
set -eu

prefix=${HOME:?HOME must be set}/.local
bin_dir=$prefix/bin

CDPATH='' cd "$(dirname "$0")"
zig build install-tome -Doptimize=ReleaseSafe --prefix "$prefix"

printf 'Installed %s\n' "$bin_dir/tome"
case ":${PATH-}:" in
    *":$bin_dir:"* | *":$bin_dir/:"*) ;;
    *)
        printf '%s\n' 'Add the following line to your shell startup file to run tome from any directory.'
        printf '%s\n' "export PATH=\"\$HOME/.local/bin:\$PATH\""
        ;;
esac
