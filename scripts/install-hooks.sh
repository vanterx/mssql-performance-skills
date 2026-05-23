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
# If any skills/*/SKILL.md is staged, regenerate skills-data.ts and re-stage it
if git diff --cached --name-only | grep -q "^skills/.*/SKILL\.md$"; then
  echo "[pre-commit] SKILL.md changed — regenerating skills-data.ts..."
  cd mcp-server && npm run bundle && cd ..
  git add mcp-server/src/skills-data.ts
  echo "[pre-commit] skills-data.ts updated and staged."
fi
EOF

chmod +x "$HOOKS_DIR/pre-commit"
echo "Installed: $HOOKS_DIR/pre-commit"
