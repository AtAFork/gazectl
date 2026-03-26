#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

VERSION="$1"
if [ -z "$VERSION" ]; then
  echo "usage: ./scripts/release.sh <version>"
  echo "example: ./scripts/release.sh 0.2.0"
  exit 1
fi

cd "$ROOT_DIR"

# Ensure clean working tree
if [ -n "$(git status --porcelain)" ]; then
  echo "error: working tree is not clean"
  git status --short
  exit 1
fi

# Ensure gh CLI is available
if ! command -v gh &>/dev/null; then
  echo "error: gh CLI is required (brew install gh)"
  exit 1
fi

echo "==> Updating version to $VERSION..."
npm version "$VERSION" --no-git-tag-version
./scripts/sync-version.sh

echo "==> Building universal binary..."
cleanup() {
  rm -f "$ROOT_DIR/bin/gazectl-bin"
}
trap cleanup EXIT

./scripts/build-npm-binary.sh

SIZE=$(ls -lh bin/gazectl-bin | awk '{print $5}')
echo "    binary: bin/gazectl-bin ($SIZE)"

echo "==> Committing and tagging..."
git add package.json Sources/BuildInfo.swift scripts/build-npm-binary.sh scripts/release.sh
git commit -m "v$VERSION"
git tag "v$VERSION"

echo "==> Pushing to GitHub..."
git push origin main --tags

echo "==> Creating GitHub release..."
gh release create "v$VERSION" bin/gazectl-bin \
  --title "v$VERSION" \
  --generate-notes

echo "==> Publishing to npm..."
npm publish

echo ""
echo "Released v$VERSION"
echo "  npm: https://www.npmjs.com/package/gazectl"
echo "  github: https://github.com/jnsahaj/gazectl/releases/tag/v$VERSION"
