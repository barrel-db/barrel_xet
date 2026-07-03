#!/bin/sh
# Fetch the large XET reference files (too big to vendor in git) into
# test/fixtures/large/. Test groups that need them skip when absent.
# Source: https://huggingface.co/datasets/xet-team/xet-spec-reference-files
# (Apache-2.0)
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
dest="$root/test/fixtures/large"
base="https://huggingface.co/datasets/xet-team/xet-spec-reference-files/resolve/main"

mkdir -p "$dest"

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

fetch() {
    name=$1
    sum=$2
    path="$dest/$name"
    if [ -f "$path" ] && [ "$(sha256 "$path")" = "$sum" ]; then
        echo "ok: $name (cached)"
        return 0
    fi
    echo "fetching: $name"
    curl -fL --progress-bar -o "$path.tmp" "$base/$name"
    got=$(sha256 "$path.tmp")
    if [ "$got" != "$sum" ]; then
        echo "checksum mismatch for $name: got $got, want $sum" >&2
        rm -f "$path.tmp"
        exit 1
    fi
    mv "$path.tmp" "$path"
    echo "ok: $name"
}

fetch "Electric_Vehicle_Population_Data_20250917.csv" \
    "f41255b252f776125f2b657136654e4d4d5d2ccf8ef4db0ec186bd1981b69734"
fetch "eea25d6ee393ccae385820daed127b96ef0ea034dfb7cf6da3a950ce334b7632.xorb" \
    "e72f4e05b9c4b96f1c6b2213d93de00ab943585a2f7c049fd127ba72ec1ff413"
