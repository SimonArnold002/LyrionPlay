#!/bin/sh
# Removes LyrionPlay: stops the player, then deletes the app, its launch agent, its settings and
# its logs.
#
#   sh uninstall.sh                       keeps your "LyrionPlay Signing" certificate, for a reinstall
#   sh uninstall.sh --remove-certificate  deletes the certificate too
set -eu

NAME=LyrionPlay
BUNDLE_ID=com.crystalgipsy.lyrionplay
LABEL=$BUNDLE_ID.agent
CERT="${LYRIONPLAY_CERT:-LyrionPlay Signing}"
KEYCHAIN="${LYRIONPLAY_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
SUPPORT="$HOME/Library/Application Support/$NAME"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

if launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null; then
	echo "stopped the player"
fi
# the menu app is whoever holds its lock file; SIGKILL, because its Quit would only stop the player
for pid in $(lsof -t "$SUPPORT/menu.lock" 2>/dev/null); do
	case "$(ps -p "$pid" -o comm= 2>/dev/null)" in
		*/Contents/MacOS/$NAME) kill -KILL "$pid" 2>/dev/null && echo "closed the menu app" ;;
	esac
done
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"

for app in "/Applications/$NAME.app" "$HOME/Applications/$NAME.app"; do
	if [ -d "$app" ]; then
		"$LSREGISTER" -u "$app" 2>/dev/null || true
		rm -rf "$app"
		echo "removed $app"
	fi
done

defaults delete "$BUNDLE_ID" 2>/dev/null || true
for path in "$SUPPORT" "$HOME/Library/Logs/$NAME" "$HOME/Library/Caches/$BUNDLE_ID" \
	"$HOME/Library/HTTPStorages/$BUNDLE_ID" "$HOME/Library/Preferences/$BUNDLE_ID.plist" \
	"$HOME/Library/Saved Application State/$BUNDLE_ID.savedState"; do
	if [ -e "$path" ]; then
		rm -rf "$path"
		echo "removed $path"
	fi
done

if [ "${1:-}" = "--remove-certificate" ]; then
	n=0
	while security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "\"$CERT\""; do
		security delete-identity -c "$CERT" "$KEYCHAIN" >/dev/null
		n=$((n + 1))
		[ $n -lt 10 ] || break
	done
	echo "deleted the certificate \"$CERT\""
fi

cat <<EOF

LyrionPlay is uninstalled. Two things macOS and LMS keep, which you can tidy by hand:
  - LMS still lists the player until it forgets it.
  - System Settings > Privacy & Security > Local Network may still list lyrionplay-agent and
    squeezelite; the entries do nothing once the app is gone.
EOF
