#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-claude-session.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 6 -strict-concurrency=complete \
    NotchBuddy/Sources/CoucouKit/BotEngine.swift \
    NotchBuddy/Sources/CoucouKit/ColorHex.swift \
    NotchBuddy/Sources/CoucouKit/IslandScreenGeometry.swift \
    NotchBuddy/Sources/CoucouKit/IslandTypes.swift \
    NotchBuddy/Sources/CoucouKit/MochiOutfitDrawing.swift \
    NotchBuddy/Sources/CoucouKit/MochiWardrobe.swift \
    NotchBuddy/Sources/CoucouKit/MochiStill.swift \
    NotchBuddy/Sources/CoucouKit/MochiActivityState.swift \
    NotchBuddy/Sources/CoucouKit/DiffEngine.swift \
    NotchBuddy/Sources/CoucouKit/PillCatalog.swift \
    NotchBuddy/Sources/CoucouKit/PillColors.swift \
    NotchBuddy/Sources/CoucouKit/ServiceDetail.swift \
    NotchBuddy/Sources/CoucouKit/ServiceSnapshot.swift \
    NotchBuddy/Sources/CoucouKit/TurnSnapshot.swift \
    NotchBuddy/Sources/CoucouKit/QuestionPayload.swift \
    tests/_stubs.swift \
    tests/ClaudeSessionTests.swift -o "$TEST_DIR/claude-session-tests"
"$TEST_DIR/claude-session-tests"