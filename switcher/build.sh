#!/bin/bash
# Build CmuxSwitcher and, with --install, run it at login.
#
#   ./build.sh                 build ~/Applications/CmuxSwitcher.app
#   ./build.sh --install       build, then (re)start it as a login LaunchAgent
#   ./build.sh --uninstall     stop it and remove the LaunchAgent
#   ./build.sh --setup-signing create a local code-signing identity (once)
#   ./build.sh --set-password  give the helper the cmux socket password (optional)
#
# One-time setup, which only you can do:
#   1. cmux Settings > Automation: set the socket mode to Password and choose a
#      password. cmux keeps it in its own secure store; nothing secret goes in
#      this repo.
#   2. System Settings > Privacy & Security > Accessibility: enable CmuxSwitcher
#      (the prompt appears on first launch).
#   3. Optional, for faster switching: ./build.sh --set-password, and enter the
#      same password you chose in step 1. The helper keeps it in its own Keychain
#      item and talks to the cmux socket directly, so a switch takes a few
#      milliseconds instead of about 150. Skip it and everything still works,
#      through the cmux CLI.
#
# Signing: without a stable identity the app is signed ad hoc, and every rebuild
# changes its signature, so macOS asks for the Accessibility permission again.
# ./build.sh --setup-signing makes a self-signed identity that stays the same
# across rebuilds. It asks for your login password once, to trust the
# certificate for code signing.
#
# Logs: ~/Library/Logs/CmuxSwitcher.log

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$HOME/Applications/CmuxSwitcher.app"
LABEL="com.jonobri.cmux-switcher"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
IDENTITY_NAME="CmuxSwitcher Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

stop_agent() {
	launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
	# bootout returns before the job is gone; starting again too soon fails with
	# "Input/output error".
	local n=0
	while launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 && [ "$n" -lt 20 ]; do
		sleep 0.25
		n=$((n + 1))
	done
}

# Usable for signing: imported AND trusted for code signing.
have_identity() {
	security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY_NAME"
}

# Imported into the keychain, trusted or not.
identity_imported() {
	security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY_NAME"
}

trust_certificate() {
	local tmp
	tmp="$(mktemp -d)"
	security find-certificate -c "$IDENTITY_NAME" -p "$KEYCHAIN" >"$tmp/cert.pem"
	echo "Trusting the certificate for code signing (macOS asks for your login password)..."
	security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$tmp/cert.pem"
	rm -rf "$tmp"
}

setup_signing() {
	if have_identity; then
		echo "Signing identity \"$IDENTITY_NAME\" already exists."
		return
	fi
	if identity_imported; then
		trust_certificate
		have_identity && echo "Signing identity \"$IDENTITY_NAME\" is now trusted." && return
		echo "Still not trusted; run again and enter your login password when asked." >&2
		exit 1
	fi
	local tmp
	tmp="$(mktemp -d)"
	cat >"$tmp/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $IDENTITY_NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
	openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/openssl.cnf" \
		-keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
	# macOS's importer rejects OpenSSL 3's default PKCS#12 encryption.
	openssl pkcs12 -export -legacy -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
		-out "$tmp/id.p12" -passout pass:cmux-switcher 2>/dev/null ||
		openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -out "$tmp/id.p12" \
			-passout pass:cmux-switcher -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1
	security import "$tmp/id.p12" -k "$KEYCHAIN" -P cmux-switcher -T /usr/bin/codesign
	rm -rf "$tmp"
	trust_certificate
	if have_identity; then
		echo "Created signing identity \"$IDENTITY_NAME\"."
	else
		echo "The identity was imported but is not usable yet; check Keychain Access." >&2
		exit 1
	fi
}

case "${1:-}" in
--uninstall)
	stop_agent
	rm -f "$PLIST"
	echo "Stopped and removed the LaunchAgent. $APP is left in place."
	exit 0
	;;
--setup-signing)
	setup_signing
	exit 0
	;;
--set-password)
	[ -x "$APP/Contents/MacOS/CmuxSwitcher" ] || { echo "Build first: ./build.sh --install" >&2; exit 1; }
	echo "Enter the cmux socket password (the one set in cmux Settings > Automation)."
	# security prompts for the value itself, so it never appears in a process list.
	security add-generic-password -s "$LABEL" -a socket-password -T "$APP/Contents/MacOS/CmuxSwitcher" -U -w
	stop_agent
	launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null || true
	echo "Saved. The helper restarted and will use it."
	exit 0
	;;
esac

mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 -o "$APP/Contents/MacOS/CmuxSwitcher" "$HERE/CmuxSwitcher.swift"
cp "$HERE/Info.plist" "$APP/Contents/Info.plist"
if [ -n "${SIGN_ID:-}" ]; then
	SIGN="$SIGN_ID"
elif have_identity; then
	SIGN="$IDENTITY_NAME"
else
	SIGN="-"
	echo "Signing ad hoc: run ./build.sh --setup-signing so rebuilds keep the Accessibility permission."
fi
codesign --force --sign "$SIGN" "$APP"
echo "Built $APP (signed: $([ "$SIGN" = "-" ] && echo "ad hoc" || echo "$SIGN"))"

if [ "${1:-}" = "--install" ]; then
	mkdir -p "$(dirname "$PLIST")"
	cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$APP/Contents/MacOS/CmuxSwitcher</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ProcessType</key>
	<string>Interactive</string>
</dict>
</plist>
EOF
	stop_agent
	launchctl bootstrap "$DOMAIN" "$PLIST"
	echo "Installed and started $LABEL"
fi
