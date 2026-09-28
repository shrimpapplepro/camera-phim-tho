#!/bin/sh
# Runs after `xcodegen generate` (see project.yml).
set -e
PBX=TrueShot.xcodeproj/project.pbxproj

# XcodeGen tags .icon bundles as wrapper.icon; Xcode's Icon Composer type is folder.iconcomposer.icon.
sed -i '' 's/lastKnownFileType = wrapper.icon;/lastKnownFileType = folder.iconcomposer.icon;/' "$PBX"

# Optional: put your Apple Developer Team ID in a local, git-ignored `.team` file so a
# regenerated project keeps signing (Xcode › Signing & Capabilities otherwise resets to None).
if [ -f .team ]; then
    TEAM=$(tr -d '[:space:]' < .team)
    perl -pi -e "s/(PRODUCT_BUNDLE_IDENTIFIER = [^;]+;)/\$1\n\t\t\t\tDEVELOPMENT_TEAM = $TEAM;/" "$PBX"
fi
