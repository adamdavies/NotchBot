#!/bin/sh
# Syntax-checks the generated OpenCode plugin with node.
#
# The plugin ships as a Swift template (Sources/NotchBotIntegrationCore/OpenCodePluginSource.swift)
# rather than a linted .js file, so this runs `node --check` over the generated output for both
# the plain and cost-tracking variants. The check also runs as part of `swift test`.
set -eu

if ! command -v node >/dev/null 2>&1; then
    echo "check-plugin-js: node not found on PATH; nothing checked" >&2
    exit 1
fi

cd "$(dirname "$0")/.."
exec swift test --filter generatedPluginIsSyntacticallyValidJavaScript
