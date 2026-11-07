#!/bin/zsh
# Builds a signed, notarized release and publishes it on GitHub.
#
#   ./release.sh 1.1 "What's new in this version."
#
# Uploads Cores.dmg (for people downloading it) and Cores.zip (what the app's built-in updater
# installs). Commit your changes first.
#
# One-off setup on the Mac you release from:
#   - The "Developer ID Application: Steve Morris & Son LLP (BAZ32PFTJS)" certificate and its private
#     key in your keychain. It can only be created by the team's Account Holder; export it from
#     Keychain Access as a .p12 to release from another Mac.
#   - Notary credentials (Apple ID plus an app-specific password from account.apple.com):
#       xcrun notarytool store-credentials Cores-notary --team-id BAZ32PFTJS
#   - The GitHub CLI, signed in: gh auth login
set -euo pipefail
cd "${0:A:h}"

VERSION="${1:?Usage: ./release.sh <version> [notes], e.g. ./release.sh 1.1 \"Adds automatic updates.\"}"
NOTES="${2:-}"
TAG="v$VERSION"
PROFILE="${NOTARY_PROFILE:-Cores-notary}"
GH="$(command -v gh || echo "$HOME/.local/bin/gh")"
APP=build/Cores.app
DMG=build/Cores.dmg # same names every release: the README's download link and the updater rely on them
ZIP=build/Cores.zip

step() { print -P "\n%B==> $1%b" }

# MARK: - Checks before anything is changed

IDENTITY="$(security find-identity -v -p codesigning | sed -nE 's/.*"(Developer ID Application: [^"]+)".*/\1/p' | head -1)"
[[ -n "$IDENTITY" ]] || { echo "No 'Developer ID Application' certificate in your keychain. See README → Releasing."; exit 1; }
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
  || { echo "No notary credentials saved as '$PROFILE'. Run: xcrun notarytool store-credentials $PROFILE"; exit 1; }
"$GH" auth status >/dev/null 2>&1 || { echo "gh isn't signed in. Run: $GH auth login"; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "Commit or stash your changes first."; exit 1; }
! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || { echo "Tag $TAG already exists."; exit 1; }

# Submits a file to Apple's notary service, waits, and stops with Apple's log if it's rejected.
notarize() {
  local result id notary_status
  result="$(xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait --output-format json)"
  id="$(print -r -- "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
  notary_status="$(print -r -- "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')"
  if [[ "$notary_status" != "Accepted" ]]; then
    echo "Notarization of $1 came back '$notary_status'. Apple's log:"
    xcrun notarytool log "$id" --keychain-profile "$PROFILE"
    exit 1
  fi
  echo "Notarized $1"
}

# MARK: - Version

step "Setting version $VERSION"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Resources/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(( $(git rev-list --count HEAD) + 1 ))" Resources/Info.plist
git commit -q -m "Release $VERSION" Resources/Info.plist

# MARK: - Build, sign and notarize the app

step "Building and signing with $IDENTITY"
CODESIGN_IDENTITY="$IDENTITY" ./build.sh
codesign --verify --strict --verbose=1 "$APP"

step "Notarizing the app (usually a minute or two)"
ditto -c -k --keepParent "$APP" "$ZIP"
notarize "$ZIP"
xcrun stapler staple "$APP" # attach the ticket so it opens even when the Mac is offline
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP" # re-zip with the ticket attached: this is what the updater downloads

# MARK: - Disk image

step "Packaging $DMG"
STAGE="$(mktemp -d)"
ditto "$APP" "$STAGE/Cores.app"
ln -s /Applications "$STAGE/Applications" # drag Cores onto this to install
rm -f "$DMG"
hdiutil create -quiet -volname "Cores" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

step "Notarizing the disk image"
notarize "$DMG"
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

# MARK: - Publish

step "Publishing $TAG on GitHub"
git tag -a "$TAG" -m "Cores $VERSION"
git push -q origin HEAD "$TAG"
"$GH" release create "$TAG" "$DMG" "$ZIP" --title "Cores $VERSION" --notes "${NOTES:+$NOTES

}Download **Cores.dmg**, open it and drag Cores into Applications. If you already have Cores, it updates itself.

Needs an Apple Silicon Mac with macOS 14 or later."

step "Done: $("$GH" release view "$TAG" --json url --jq .url)"
