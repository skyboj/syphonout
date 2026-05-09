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

echo ""
echo "═══════════════════════════════════════════════"
echo "  All tests passed ✓"
echo "═══════════════════════════════════════════════"
