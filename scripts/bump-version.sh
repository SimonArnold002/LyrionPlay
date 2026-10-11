#!/bin/sh
# Raises the version in VERSION, the one place it is set, then regenerates the pages so their
# version badge matches. build.sh puts it in the app (CFBundleShortVersionString) and the release
# zip's name; CFBundleVersion is the build's timestamp.
#   scripts/bump-version.sh           0.1.0 -> 0.1.1   (a fix or small change)
#   scripts/bump-version.sh minor     0.1.1 -> 0.2.0   (a new feature)
#   scripts/bump-version.sh major     0.2.0 -> 1.0.0
# The fleet's rule applies: every build handed over gets a new number, after a yes/no.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OLD=$(cat "$ROOT/VERSION")
case "$OLD" in
	*[!0-9.]* | *..* | .* | *.) echo "VERSION is not x.y.z: $OLD" >&2; exit 1 ;;
esac
MAJOR=$(echo "$OLD" | cut -d. -f1)
MINOR=$(echo "$OLD" | cut -d. -f2)
PATCH=$(echo "$OLD" | cut -d. -f3)
[ -n "$MAJOR" ] && [ -n "$MINOR" ] && [ -n "$PATCH" ] || { echo "VERSION is not x.y.z: $OLD" >&2; exit 1; }

case "${1:-patch}" in
	patch) PATCH=$((PATCH + 1)) ;;
	minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
	major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
	*) echo "usage: $0 [patch | minor | major]" >&2; exit 2 ;;
esac
NEW="$MAJOR.$MINOR.$PATCH"
printf '%s\n' "$NEW" > "$ROOT/VERSION"
python3 "$ROOT/tools/make_readme_html.py" >/dev/null
echo "LyrionPlay $OLD -> $NEW"
