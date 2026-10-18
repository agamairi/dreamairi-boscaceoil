#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

GODOT="${1:-}"
if [ -z "$GODOT" ]; then
    if [ -x "/Applications/Godot.app/Contents/MacOS/Godot" ]; then
        GODOT="/Applications/Godot.app/Contents/MacOS/Godot"
    elif command -v godot >/dev/null 2>&1; then
        GODOT="$(command -v godot)"
    elif command -v godot4 >/dev/null 2>&1; then
        GODOT="$(command -v godot4)"
    fi
fi

if [ -z "$GODOT" ] || [ ! -x "$GODOT" ]; then
    echo "FAIL: could not locate a Godot binary." >&2
    exit 1
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

cat > "$WORK_DIR/project.godot" <<'PROJECT_FILE'
config_version=5

[application]
config/name="remote-control-test"
config/features=PackedStringArray("4.4")

[debug]
gdscript/warnings/untyped_declaration=1
PROJECT_FILE

mkdir -p "$WORK_DIR/ai" "$WORK_DIR/test"
cp "$REPO_ROOT/ai/remote_control.gd" "$WORK_DIR/ai/remote_control.gd"
cp "$REPO_ROOT/test/remote_control_test.gd" "$WORK_DIR/test/remote_control_test.gd"

"$GODOT" --headless --path "$WORK_DIR" --script "test/remote_control_test.gd"
