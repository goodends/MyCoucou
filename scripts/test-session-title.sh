#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-session-title.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
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
    NotchBuddy/Sources/App/SessionHistoryLoader.swift \
    NotchBuddy/Sources/App/SessionTitleWriter.swift \
    tests/_stubs.swift \
    tests/SessionTitleTests.swift -o "$TEST_DIR/session-title-tests"
"$TEST_DIR/session-title-tests"
