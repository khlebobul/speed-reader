#!/usr/bin/env bash
#
# scripts/release.sh — pre-flight for a Speed Reader release.
#
# Does the mechanical parts:
#   1. Validate git state and tooling
#   2. Bump MARKETING_VERSION / CURRENT_PROJECT_VERSION in Config.xcconfig
#   3. Commit the bump (and push unless --no-push)
#   4. make dmg-release → dist/SpeedReader.dmg
#   5. Run Sparkle sign_update on the DMG
#   6. Print ready-to-paste appcast <item> and `gh release create` command
#
# Manual follow-up (intentionally out of scope):
#   - gh release create
#   - prepend <item> to appcast.xml in this repository
#   - verify
#
# Usage:
#   scripts/release.sh <version>              # e.g. 1.0.7 — bumps + pushes + builds
#   scripts/release.sh <version> --no-push    # skip `git push` after the bump commit
#   scripts/release.sh <version> --no-commit  # edit Config.xcconfig but leave git alone

set -euo pipefail

# ---------- colors ----------
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
BOLD=$'\033[1m'
NC=$'\033[0m'

info()  { printf "%s[info]%s  %s\n" "$GREEN" "$NC" "$1"; }
warn()  { printf "%s[warn]%s  %s\n" "$YELLOW" "$NC" "$1"; }
error() { printf "%s[err ]%s  %s\n" "$RED" "$NC" "$1" >&2; exit 1; }
step()  { printf "\n%s▶ %s%s\n" "$BOLD$BLUE" "$1" "$NC"; }

# ---------- args ----------
VERSION=""
PUSH=1
COMMIT=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-push)   PUSH=0; shift ;;
        --no-commit) COMMIT=0; PUSH=0; shift ;;
        -h|--help)
            awk '/^set -e/{exit} NR>1{print}' "$0"
            exit 0
            ;;
        -*)
            error "Unknown option: $1"
            ;;
        *)
            if [[ -z "$VERSION" ]]; then
                VERSION="$1"
            else
                error "Unexpected argument: $1"
            fi
            shift
            ;;
    esac
done

[[ -n "$VERSION" ]] || error "Version is required. Usage: scripts/release.sh <version>"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || error "Version must be X.Y.Z (got: $VERSION)"

# ---------- locate repo root ----------
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

CONFIG_FILE="SpeedReader/Config.xcconfig"
DMG_OUTPUT="dist/SpeedReader.dmg"
PUBLIC_REPO="khlebobul/speed-reader"

[[ -f "$CONFIG_FILE" ]] || error "Not inside the speed_reader_app repo (missing $CONFIG_FILE)"

# ---------- pre-flight ----------
step "Pre-flight checks"

# Tools
for tool in xcodebuild xcodegen create-dmg xcrun security; do
    command -v "$tool" >/dev/null 2>&1 || error "Required tool not found: $tool"
done
info "Required tools available"

# Git state (only if we're going to commit)
if (( COMMIT )); then
    BRANCH=$(git rev-parse --abbrev-ref HEAD)
    if [[ "$BRANCH" != "main" ]]; then
        warn "Current branch is '$BRANCH'; releases normally come from 'main'. Continuing anyway."
    fi

    if [[ -n "$(git status --porcelain)" ]]; then
        error "Working tree is not clean. Commit or stash first."
    fi
    info "Git tree clean (branch: $BRANCH)"
fi

# ---------- version bump ----------
step "Bumping version to $VERSION"

CURRENT_MARKETING=$(grep -E '^MARKETING_VERSION' "$CONFIG_FILE" | awk -F= '{gsub(/ /,""); print $2}')
CURRENT_BUILD=$(grep -E '^CURRENT_PROJECT_VERSION' "$CONFIG_FILE" | awk -F= '{gsub(/ /,""); print $2}')

info "Current: MARKETING_VERSION=$CURRENT_MARKETING  CURRENT_PROJECT_VERSION=$CURRENT_BUILD"

if [[ "$CURRENT_MARKETING" == "$VERSION" ]]; then
    error "MARKETING_VERSION is already $VERSION — nothing to bump"
fi

NEW_BUILD=$(( CURRENT_BUILD + 1 ))

# Rewrite xcconfig (portable sed: write to temp, then mv)
TMP=$(mktemp)
awk -v v="$VERSION" -v b="$NEW_BUILD" '
    /^MARKETING_VERSION[[:space:]]*=/        { print "MARKETING_VERSION = " v; next }
    /^CURRENT_PROJECT_VERSION[[:space:]]*=/  { print "CURRENT_PROJECT_VERSION = " b; next }
    { print }
' "$CONFIG_FILE" > "$TMP"
mv "$TMP" "$CONFIG_FILE"

info "New:     MARKETING_VERSION=$VERSION          CURRENT_PROJECT_VERSION=$NEW_BUILD"

# ---------- commit ----------
if (( COMMIT )); then
    step "Committing version bump"
    git add "$CONFIG_FILE"
    git commit -m "chore: bump to $VERSION"
    info "Committed"

    if (( PUSH )); then
        git push
        info "Pushed to origin/$BRANCH"
    else
        warn "Skipped git push (--no-push). Push manually before creating the release."
    fi
else
    warn "Skipped commit (--no-commit). Config.xcconfig is modified but not staged."
fi

# ---------- build + sign + notarize ----------
step "make dmg-release (build → sign → notarize)"
make dmg-release
[[ -f "$DMG_OUTPUT" ]] || error "Expected $DMG_OUTPUT after make dmg-release but it's missing"
DMG_SIZE=$(stat -f %z "$DMG_OUTPUT")
info "Built & notarized: $DMG_OUTPUT ($(du -h "$DMG_OUTPUT" | awk '{print $1}'))"

# ---------- Sparkle sign ----------
step "Signing DMG for Sparkle"

SIGN_UPDATE=$(find SpeedReader/.build/SourcePackages/artifacts/sparkle/Sparkle/bin \
              -maxdepth 1 -name sign_update -type f 2>/dev/null | head -1)

if [[ -z "$SIGN_UPDATE" ]]; then
    SIGN_UPDATE=$(find "$HOME/Library/Developer/Xcode/DerivedData" \
                  -path "*/sparkle/Sparkle/bin/sign_update" -type f 2>/dev/null | head -1)
fi

[[ -n "$SIGN_UPDATE" && -x "$SIGN_UPDATE" ]] || error "sign_update binary not found"
info "Using sign_update: $SIGN_UPDATE"

SPARKLE_OUTPUT=$("$SIGN_UPDATE" "$DMG_OUTPUT")
# Output looks like: sparkle:edSignature="..." length="..."
ED_SIGNATURE=$(printf '%s' "$SPARKLE_OUTPUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')
LENGTH=$(printf '%s' "$SPARKLE_OUTPUT" | sed -n 's/.*length="\([^"]*\)".*/\1/p')

[[ -n "$ED_SIGNATURE" && -n "$LENGTH" ]] || error "Failed to parse sign_update output: $SPARKLE_OUTPUT"
info "Sparkle signature computed"

# ---------- summary for manual steps ----------
PUB_DATE=$(date -u "+%a, %d %b %Y %H:%M:%S +0000")
TAG="v$VERSION"
DOWNLOAD_URL="https://github.com/$PUBLIC_REPO/releases/download/$TAG/SpeedReader.dmg"

step "Done. Manual steps remaining:"

cat <<EOF

${BOLD}1) Create the GitHub release${NC}
   ${YELLOW}(run from anywhere — attaches the DMG we just built)${NC}

   gh release create $TAG "$REPO_ROOT/$DMG_OUTPUT" \\
     --repo $PUBLIC_REPO \\
     --title "$VERSION" \\
     --notes "Release notes here"

${BOLD}2) Prepend this <item> to appcast.xml${NC}
   ${YELLOW}(in this repository, then commit + push)${NC}

  <item>
    <title>Version $VERSION</title>
    <pubDate>$PUB_DATE</pubDate>
    <sparkle:version>$NEW_BUILD</sparkle:version>
    <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
    <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
    <enclosure
      url="$DOWNLOAD_URL"
      sparkle:edSignature="$ED_SIGNATURE"
      length="$LENGTH"
      type="application/octet-stream"/>
  </item>

${BOLD}3) Verify${NC}
   - https://github.com/$PUBLIC_REPO/releases/latest/download/SpeedReader.dmg
   - https://raw.githubusercontent.com/$PUBLIC_REPO/main/appcast.xml
   - Launch an older build → Check for Updates…

EOF
