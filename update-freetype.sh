#!/usr/bin/env bash
# Vendors the subset of FreeType that build.rs needs from upstream into freetype2/.
#
#   ./update-freetype.sh <version>          Replace freetype2/ with the subset of upstream tag
#                                          VER-<version-with-dashes> and stage it.
#   ./update-freetype.sh --check <version>  Compare the committed freetype2/ (HEAD) with the
#                                          subset of that upstream tag.
#
# The version is written with dots (for example, 2.14.3).  Keep SOURCE_MODULES in sync with
# the files build.rs compiles.  The script verifies that it covers every module enabled in
# modules.cfg; builds for all supported target families are still required after an update.
set -euo pipefail

UPSTREAM=https://gitlab.freedesktop.org/freetype/freetype.git

# Complete source directories are retained so that internal include dependencies do not need
# to be duplicated here.  modules.cfg documents the upstream module selection, and the license
# files cover FreeType's dual license and its separately licensed source components.
SOURCE_MODULES=(
    autofit
    base
    bdf
    bzip2
    cache
    cff
    cid
    gzip
    lzw
    pcf
    pfr
    psaux
    pshinter
    psnames
    raster
    sdf
    sfnt
    smooth
    svg
    truetype
    type1
    type42
    winfonts
)

VENDORED_FILES=(
    'modules.cfg'
    'LICENSE.TXT'
    'docs/FTL.TXT'
    'docs/GPLv2.TXT'
    'builds/unix/ftsystem.c'
    'builds/windows/ftsystem.c'
)

check=false
if [ "${1-}" = --check ]; then
    check=true
    shift
fi
if [ $# -ne 1 ]; then
    sed -n '2,11s/^# \{0,1\}//p' "$0" >&2
    exit 2
fi
version=$1
if [[ ! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "invalid FreeType version '$version'; expected a version like 2.14.3" >&2
    exit 2
fi
tag=VER-${version//./-}

module_is_vendored() {
    local configured=$1
    local vendored

    for vendored in "${SOURCE_MODULES[@]}"; do
        if [ "$configured" = "$vendored" ]; then
            return 0
        fi
    done
    return 1
}

# Fail explicitly when upstream enables a new module instead of silently producing a partial
# source tree.  Disabled modules and optional base extensions do not need their own directories.
verify_modules() {
    local modules_cfg=$1
    local configured

    while read -r configured; do
        if ! module_is_vendored "$configured"; then
            echo "modules.cfg enables '$configured', but SOURCE_MODULES does not vendor it" >&2
            exit 1
        fi
    done < <(sed -n 's/^[A-Z_]*_MODULES[[:space:]]*+=[[:space:]]*\([^[:space:]#]*\).*$/\1/p' "$modules_cfg")
}

# Copies the subset we need of directory $1 into the new directory $2.
filter() {
    local source=$1
    local destination=$2
    local file
    local module

    mkdir "$destination"
    cp -R "$source/include" "$destination/include"

    for file in "${VENDORED_FILES[@]}"; do
        mkdir -p "$destination/$(dirname "$file")"
        cp "$source/$file" "$destination/$file"
    done

    mkdir "$destination/src"
    for module in "${SOURCE_MODULES[@]}"; do
        cp -R "$source/src/$module" "$destination/src/$module"
    done
}

cd "$(dirname "$0")"
work=$(mktemp -d)
trap 'rm -rf "${work:?}"' EXIT

git -C "$work" init -q
git -C "$work" fetch -q --depth 1 "$UPSTREAM" "refs/tags/$tag"
commit=$(git -C "$work" rev-parse FETCH_HEAD^{commit})
mkdir "$work/full"
git -C "$work" archive FETCH_HEAD | tar -x -C "$work/full"

header="$work/full/include/freetype/freetype.h"
major=$(sed -n 's/^#define FREETYPE_MAJOR[[:space:]]*\([0-9][0-9]*\).*$/\1/p' "$header")
minor=$(sed -n 's/^#define FREETYPE_MINOR[[:space:]]*\([0-9][0-9]*\).*$/\1/p' "$header")
patch=$(sed -n 's/^#define FREETYPE_PATCH[[:space:]]*\([0-9][0-9]*\).*$/\1/p' "$header")
header_version=$major.$minor.$patch
if [ "$header_version" != "$version" ]; then
    echo "upstream tag $tag has FreeType version $header_version" >&2
    exit 1
fi

verify_modules "$work/full/modules.cfg"
filter "$work/full" "$work/upstream"

if $check; then
    object_type=$(git cat-file -t HEAD:freetype2 2>/dev/null || true)
    if [ "$object_type" != tree ]; then
        echo "freetype2/ at HEAD is not a vendored directory; run the updater and commit it first" >&2
        exit 1
    fi

    mkdir "$work/committed"
    git archive HEAD:freetype2 | tar -x -C "$work/committed"
    if git diff --no-index --no-renames --quiet "$work/committed" "$work/upstream"; then
        echo "freetype2/ at HEAD matches the vendored subset of FreeType $version (upstream commit $commit)"
        exit 0
    fi
    { git diff --no-index --no-renames --name-status "$work/committed" "$work/upstream" || true; } |
        sed "s#$work/committed/#freetype2/#; s#$work/upstream/#freetype2/#"
    echo "freetype2/ at HEAD differs from the vendored subset of FreeType $version (upstream commit $commit)."
    echo "D: only at HEAD, A: only upstream, M: content differs."
    exit 1
fi

rm -rf freetype2
mv "$work/upstream" freetype2

if git config -f .gitmodules --get-regexp '^submodule\.freetype2\.' >/dev/null 2>&1; then
    git config -f .gitmodules --remove-section submodule.freetype2
    git add .gitmodules
fi
if git ls-files --stage freetype2 | grep -q '^160000 '; then
    git rm --cached --quiet freetype2
fi
git add --all --force freetype2
echo "Vendored and staged FreeType $version (upstream commit $commit) in freetype2/."
