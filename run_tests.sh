#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "═══════════════════════════════════════════════"
echo "  SyphonOut Test Suite"
echo "═══════════════════════════════════════════════"

# ─── Rust Core ──────────────────────────────────────────────────────────────
echo ""
echo "▶ Rust Core (cargo test)"
cd core
cargo test --quiet
cd ..

# ─── C Protocol Tests ───────────────────────────────────────────────────────
echo ""
echo "▶ C Protocol Layout Tests"
clang -std=c11 -Wall -Wextra \
    obs-solink/tests/test_protocol.c \
    -o /tmp/solink_test_protocol \
    && /tmp/solink_test_protocol

# ─── C SHM Tests ────────────────────────────────────────────────────────────
echo ""
echo "▶ C Shared Memory Tests"
clang -std=c11 -Wall -Wextra \
    obs-solink/tests/test_shm.c \
    -o /tmp/solink_test_shm \
    && /tmp/solink_test_shm

echo ""
echo "═══════════════════════════════════════════════"
echo "  All tests passed ✓"
echo "═══════════════════════════════════════════════"
