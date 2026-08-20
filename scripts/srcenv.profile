# the development environment of xmake-harness
#
# it makes `xmake ai` work directly from this source tree, no installation is needed,
# so we can debug the harness source code immediately:
#
#   $ cd /path/to/xmake-harness
#   $ source scripts/srcenv.profile
#   $ xmake ai
#
# it only creates the symbolic links in the xmake global directory, run
# `source scripts/srcenv.profile --unlink` to remove them again.
#
harness_rootdir=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)
harness_globaldir="${XMAKE_GLOBALDIR:-$HOME/.xmake}"

harness_link() {
    local src="$1"
    local dst="$2"
    if [ -L "$dst" ] || [ -e "$dst" ]; then
        rm -rf "$dst"
    fi
    mkdir -p "$(dirname "$dst")"
    ln -s "$src" "$dst"
    echo "link: $dst -> $src"
}

if [ "$1" = "--unlink" ]; then
    rm -rf "$harness_globaldir/plugins/ai" "$harness_globaldir/modules/harness"
    echo "the xmake-harness development links are removed."
else
    harness_link "$harness_rootdir/src/plugins/ai"      "$harness_globaldir/plugins/ai"
    harness_link "$harness_rootdir/src/modules/harness" "$harness_globaldir/modules/harness"
    export XMAKE_HARNESS_DEV="$harness_rootdir"
    echo "xmake-harness: the development environment is ready, try \`xmake ai\`."
fi

unset harness_rootdir harness_globaldir
unset -f harness_link
