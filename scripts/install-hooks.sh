#!/bin/sh
# Installs git hooks for this repository.
# Run once after cloning: bash scripts/install-hooks.sh

set -e

HOOKS_DIR=".git/hooks"

if [ ! -d "$HOOKS_DIR" ]; then
  echo "Error: $HOOKS_DIR not found. Run this from the repo root."
  exit 1
fi

cat > "$HOOKS_DIR/pre-commit" << 'EOF'
#!/bin/sh
# Regenerate skills-data.ts when any file the bundler reads is staged.
#
# bundle-skills.ts reads each skill's SKILL.md AND every file in its
# references/ directory, plus PERFORMANCE_TUNING_GUIDE.md and
# skills/VERSION_COMPATIBILITY.md. Matching only SKILL.md left the bundle stale
# on a references-only commit, so the MCP server served outdated content with
# nothing to flag it.
if git diff --cached --name-only | grep -qE "^skills/.*/SKILL\.md$|^skills/.*/references/.*|^PERFORMANCE_TUNING_GUIDE\.md$|^skills/VERSION_COMPATIBILITY\.md$"; then
  echo "[pre-commit] bundled source changed — regenerating skills-data.ts..."
  cd mcp-server && npm run bundle && cd ..
  git add mcp-server/src/skills-data.ts
  echo "[pre-commit] skills-data.ts updated and staged."
fi
EOF

chmod +x "$HOOKS_DIR/pre-commit"
echo "Installed: $HOOKS_DIR/pre-commit"
