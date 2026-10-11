#!/bin/sh
# Installs LyrionPlay, signed with YOUR OWN code-signing certificate (INSTALL.md explains why).
#
#   sh install.sh                    installs the LyrionPlay.app that sits next to this script
#   sh install.sh <LyrionPlay.app>   installs that copy (scripts/build.sh --install does this)
#
# In order:
#   1. checks this Mac: Apple Silicon, macOS 14 or later
#   2. the first time only: creates your certificate "LyrionPlay Signing" in your login keychain
#   3. copies the app next to the installed one, in /Applications (or ~/Applications if you
#      cannot write to /Applications)
#   4. removes the download quarantine from the copy
#   5. signs the copy with your certificate
#   6. swaps it in, restarting the player only if the player itself changed
#   7. opens LyrionPlay
#
# For testing: LYRIONPLAY_CERT (certificate name), LYRIONPLAY_KEYCHAIN, LYRIONPLAY_DEST (folder
# to install into) and LYRIONPLAY_NO_START=1 (stop, start and open nothing).
set -eu

NAME=LyrionPlay
BUNDLE_ID=com.crystalgipsy.lyrionplay
LABEL=$BUNDLE_ID.agent
DOMAIN="gui/$(id -u)"
CERT="${LYRIONPLAY_CERT:-LyrionPlay Signing}"
KEYCHAIN="${LYRIONPLAY_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
NO_START="${LYRIONPLAY_NO_START:-0}"
SRC="${1:-$(cd "$(dirname "$0")" && pwd)/$NAME.app}"
LOCK="$HOME/Library/Application Support/$NAME/menu.lock"
SESSION_ENDING="$HOME/Library/Application Support/$NAME/menu-session-ending"

step() { printf '\n%s\n' "$*"; }
fail() { printf '\nLyrionPlay was not installed: %s\n' "$*" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

version_of() { /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist" 2>/dev/null || true; }

step "1. Checking this Mac"
[ "$(uname -m)" = arm64 ] || fail "LyrionPlay needs an Apple Silicon Mac; this one is $(uname -m)."
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 14 ] || fail "LyrionPlay needs macOS 14 or later; this Mac has $(sw_vers -productVersion)."
[ -x "$SRC/Contents/MacOS/$NAME" ] || fail "cannot find the app at $SRC"
echo "   Apple Silicon, macOS $(sw_vers -productVersion)"
echo "   installing LyrionPlay $(version_of "$SRC")"

# A self-signed certificate is "not trusted" (nothing vouches for it but you), so it is looked up
# among all code-signing identities, not only the trusted ones.
identity() {
	security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null |
		awk -v name="\"$CERT\"" 'index($0, name) { print $2; exit }'
}

step "2. Your code-signing certificate \"$CERT\""
ID=$(identity)
if [ -n "$ID" ]; then
	echo "   already in your keychain: using it"
else
	echo "   creating it in your login keychain (only this Mac has its private key)"
	cat > "$tmp/cert.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = $CERT
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF
	/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 -config "$tmp/cert.cnf" \
		-keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null || fail "openssl could not create the certificate"
	pass=$(/usr/bin/openssl rand -hex 16)
	/usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$CERT" \
		-out "$tmp/cert.p12" -passout "pass:$pass" || fail "openssl could not package the certificate"
	# -T: codesign may use the key without asking each time
	security import "$tmp/cert.p12" -k "$KEYCHAIN" -P "$pass" -T /usr/bin/codesign >/dev/null ||
		fail "the keychain refused the certificate (is it unlocked?)"
	ID=$(identity)
	[ -n "$ID" ] || fail "the certificate was imported but the keychain does not list it for code signing"
	echo "   created; valid for 10 years"
fi

DEST_DIR="${LYRIONPLAY_DEST:-/Applications}"
if [ ! -w "$DEST_DIR" ]; then
	DEST_DIR="$HOME/Applications"
	mkdir -p "$DEST_DIR"
fi
DEST="$DEST_DIR/$NAME.app"
STAGE="$DEST_DIR/.$NAME-installing.app"

step "3. Copying the app to $DEST_DIR"
rm -rf "$STAGE"
ditto "$SRC" "$STAGE"

step "4. Removing the download quarantine"
xattr -dr com.apple.quarantine "$STAGE" 2>/dev/null || true
echo "   done: macOS will not block it at first launch"

step "5. Signing it with your certificate"
# inside-out: the helper executables, then the bundle (which signs the menu app)
for exe in squeezelite lyrionplay-agent; do
	codesign --force --options runtime --timestamp=none --keychain "$KEYCHAIN" -s "$ID" \
		-i "$BUNDLE_ID.$exe" "$STAGE/Contents/MacOS/$exe" 2>"$tmp/sign.log" || { cat "$tmp/sign.log" >&2; fail "codesign failed"; }
done
codesign --force --options runtime --timestamp=none --keychain "$KEYCHAIN" -s "$ID" "$STAGE" 2>"$tmp/sign.log" ||
	{ cat "$tmp/sign.log" >&2; fail "codesign failed"; }
codesign --verify --strict "$STAGE" || fail "the signature does not verify"
echo "   signed and verified"

step "6. Installing"
# The player restarts only if its own code changed: restarting it stops whatever is playing. A
# helper's code hash covers its code and your certificate, not the date it was signed.
cdhashes() {
	for exe in lyrionplay-agent squeezelite; do
		codesign -dvvv "$1/Contents/MacOS/$exe" 2>&1 | sed -n 's/^CDHash=//p'
	done
}
OLD=""
WAS=""
[ -d "$DEST" ] && OLD=$(cdhashes "$DEST" 2>/dev/null || true) && WAS=$(version_of "$DEST")
NEW=$(cdhashes "$STAGE")
# A player left running reopens a missing menu within 2 s, and in the moment between the kill
# below and the swap it would open the OLD copy, which the final `open` then only brings to the
# front. The marker the menu writes at logout holds the player off for a minute; the new menu
# removes it when it starts.
if [ "$NO_START" != 1 ]; then
	mkdir -p "$(dirname "$SESSION_ENDING")"
	touch "$SESSION_ENDING"
fi
# The running menu app is whoever holds its lock file (the player opens that file for an
# instant every 2 s, so the holder's executable is checked too).
MENU=""
for pid in $(lsof -t "$LOCK" 2>/dev/null); do
	case "$(ps -p "$pid" -o comm= 2>/dev/null)" in
		*/Contents/MacOS/$NAME) MENU="$MENU $pid" ;;
	esac
done
if [ "$NO_START" != 1 ] && launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
	if [ "$OLD" = "$NEW" ]; then
		echo "   the player is unchanged: it keeps running"
	else
		launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
		echo "   stopped the old player; it starts again when the app opens"
	fi
fi
# The menu is replaced by SIGKILL, never a quit: quitting the menu switches the player off.
if [ "$NO_START" != 1 ] && [ -n "$MENU" ]; then
	for pid in $MENU; do kill -KILL "$pid" 2>/dev/null || true; done
	for pid in $MENU; do while kill -0 "$pid" 2>/dev/null; do sleep 0.1; done; done
fi
rm -rf "$DEST"
mv "$STAGE" "$DEST"
echo "   installed: $DEST, version $(version_of "$DEST")${WAS:+ (was $WAS)}"

if [ "$NO_START" != 1 ]; then
	step "7. Opening LyrionPlay"
	open "$DEST"
	echo "   look for its icon in the menu bar"
fi
echo
