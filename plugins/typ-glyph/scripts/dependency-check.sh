#!/usr/bin/env bash
# Resolve a Python interpreter with the requested packages importable.
#
# Usage: dependency-check.sh <plugin-name> "<import-expr>" <pkg> [<pkg>...]
#
# On success: prints "PLUGIN_PY=<path>" as its last stdout line and exits 0.
# On failure: prints a diagnostic to stderr and exits non-zero.
#
# Cascade: (1) system interpreter already satisfies deps?
#          (2) install via `uv pip install --system` (retry with --break-system-packages)
#          (3) create a user-local venv under $TMPDIR
#          (4) verify — a post-install import failure usually means a native system
#              library is missing (e.g., libcairo for cairosvg).
#
# See team standards, "Python Plugin Dependencies", for rationale.

if [ "$#" -lt 3 ]; then
    echo "usage: $0 <plugin-name> '<import-expr>' <package> [<package>...]" >&2
    exit 2
fi

PLUGIN_NAME="$1"
IMPORT_EXPR="$2"
shift 2

PY="$(command -v python3 || command -v python)"
if [ -z "$PY" ]; then
    echo "No python3/python on PATH" >&2
    exit 1
fi

if "$PY" -c "import $IMPORT_EXPR" 2>/dev/null; then
    PLUGIN_PY="$PY"

elif command -v uv >/dev/null 2>&1 \
     && { uv pip install --python "$PY" --system "$@" \
          || uv pip install --python "$PY" --system --break-system-packages "$@"; }; then
    PLUGIN_PY="$PY"

else
    VENV_DIR="${TMPDIR:-/tmp}/${PLUGIN_NAME}-venv-$(id -u 2>/dev/null || echo default)"
    if ! [ -x "$VENV_DIR/bin/python" ] \
       && ! [ -x "$VENV_DIR/bin/python3" ] \
       && ! [ -x "$VENV_DIR/Scripts/python.exe" ]; then
        rm -rf "$VENV_DIR"
        "$PY" -m venv "$VENV_DIR" || {
            echo "venv creation failed — install the Python venv module (e.g., 'apt install python3-venv' on Debian/Ubuntu)" >&2
            exit 1
        }
    fi
    if   [ -x "$VENV_DIR/bin/python" ];         then PLUGIN_PY="$VENV_DIR/bin/python"
    elif [ -x "$VENV_DIR/bin/python3" ];        then PLUGIN_PY="$VENV_DIR/bin/python3"
    elif [ -x "$VENV_DIR/Scripts/python.exe" ]; then PLUGIN_PY="$VENV_DIR/Scripts/python.exe"
    else
        echo "venv interpreter not found under $VENV_DIR (expected bin/python, bin/python3, or Scripts/python.exe)" >&2
        exit 1
    fi
    "$PLUGIN_PY" -m pip install "$@" || {
        echo "pip install failed in venv $VENV_DIR" >&2
        exit 1
    }
fi

"$PLUGIN_PY" -c "import $IMPORT_EXPR" || {
    echo "verify failed: if the error mentions a missing native library (e.g., libcairo), install it via the OS package manager (macOS: 'brew install cairo pango'; Debian/Ubuntu: 'apt install libcairo2-dev'; Windows: install a GTK runtime)" >&2
    exit 1
}

echo "PLUGIN_PY=$PLUGIN_PY"
