#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-claude-host.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
# ClaudeHost.label(for:) takes a ClaudeSession, so IslandTypes has to be on the
# command line too — and IslandTypes pulls the engine and the pill catalog in.
swiftc -swift-version 6 -strict-concurrency=complete \
    NotchBuddy/Sources/CoucouKit/BotEngine.swift \
    NotchBuddy/Sources/CoucouKit/ColorHex.swift \
    NotchBuddy/Sources/CoucouKit/IslandScreenGeometry.swift \
    NotchBuddy/Sources/CoucouKit/IslandTypes.swift \
    NotchBuddy/Sources/CoucouKit/MochiOutfitDrawing.swift \
    NotchBuddy/Sources/CoucouKit/MochiWardrobe.swift \
    NotchBuddy/Sources/CoucouKit/DiffEngine.swift \
    NotchBuddy/Sources/CoucouKit/PillCatalog.swift \
    NotchBuddy/Sources/CoucouKit/PillColors.swift \
    NotchBuddy/Sources/App/ClaudeHost.swift \
    tests/_stubs.swift \
    tests/ClaudeHostTests.swift -o "$TEST_DIR/claude-host-tests"
"$TEST_DIR/claude-host-tests"
