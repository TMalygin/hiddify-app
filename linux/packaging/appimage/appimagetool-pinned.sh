#!/usr/bin/env bash
set -euo pipefail

# CI verifies both files before exposing this wrapper on PATH. Fastforge's
# initial package and our repackaging pass must use that same runtime.
tool_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
for argument in "$@"; do
    case "$argument" in
        --runtime-file|--runtime-file=*)
            printf 'The AppImage runtime is selected by the verified build toolchain.\n' >&2
            exit 2
            ;;
    esac
done
test -s "$tool_dir/runtime-x86_64"
exec "$tool_dir/appimagetool-bin" --runtime-file "$tool_dir/runtime-x86_64" "$@"
