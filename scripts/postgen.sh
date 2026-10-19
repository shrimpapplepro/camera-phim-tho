#!/bin/sh
# Runs after `xcodegen generate` (see project.yml).
set -e
PBX=TrueShot.xcodeproj/project.pbxproj

# XcodeGen tags .icon bundles as wrapper.icon; Xcode's Icon Composer type is folder.iconcomposer.icon.
sed -i '' 's/lastKnownFileType = wrapper.icon;/lastKnownFileType = folder.iconcomposer.icon;/' "$PBX"

# XcodeGen embeds ExtensionKit extensions as products-directory + "$(EXTENSIONS_FOLDER_PATH)", which
# breaks when archiving (Xcode: the .appex "is embedded in ../../../BuildProductsPath/…/Extensions").
# Make the destination relative to the app bundle instead: the Wrapper, subfolder "Extensions".
# (dstSubfolder only accepts PlugIns/Frameworks/Resources/Wrapper/Executables/SharedSupport.)
perl -0pi -e 's/dstPath = "\$\(EXTENSIONS_FOLDER_PATH\)";\s*dstSubfolderSpec = 16;/dstPath = Extensions;\n\t\t\tdstSubfolder = Wrapper;/g' "$PBX"

# Optional: put your Apple Developer Team ID in a local, git-ignored `.team` file so a
# regenerated project keeps signing (Xcode › Signing & Capabilities otherwise resets to None).
# Set once at project level (anchored on MARKETING_VERSION, a project-only setting); every target
# inherits it, as Xcode's recommended settings ask.
if [ -f .team ]; then
    TEAM=$(tr -d '[:space:]' < .team)
    perl -pi -e "s/(MARKETING_VERSION = [^;]+;)/\$1\n\t\t\t\tDEVELOPMENT_TEAM = $TEAM;/" "$PBX"
fi
