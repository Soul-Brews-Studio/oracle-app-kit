#!/usr/bin/env zsh
# new-oracle-app.sh <Name> <org/repo> <mac checkout path> <#hex> <sf-symbol> "<tagline>"
# Creates Apps/<Name>/ (thin app: config + optional extras), its icon, its xcodegen target, then regenerates.
set -e
N=${1:?Name}; SLUG=${2:?org/repo}; LP=${3:?mac path}; HEX=${4:?#hex}; SYM=${5:?symbol}; TAG=${6:-"$N oracle"}
R=${0:A:h}/..; D=$R/Apps/$N; low=${(L)N}
[ -e $D ] && { echo "Apps/$N exists — refusing to overwrite"; exit 2; }
mkdir -p $D/Assets.xcassets
print -r -- '{"info":{"version":1,"author":"xcode"}}' > $D/Assets.xcassets/Contents.json
uv run --quiet --with pillow python $R/scripts/make_icon.py $D/Assets.xcassets/AppIcon.appiconset $HEX ${N[1]}
cat > $D/${N}App.swift <<SWIFT
import SwiftUI
import OracleKit

@main
struct ${N}App: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(OracleAppDelegate.self) var delegate
    #endif
    var body: some Scene { OracleScene(config: .${low}) }
}

extension OracleConfig {
    static let ${low} = OracleConfig(
        name: "$N", tagline: "$TAG", repoSlug: "$SLUG",
        localPath: OracleConfig.mac("$LP"),
        colorHex: "$HEX", symbol: "$SYM",
        extras: ${N}Extras.extras)
}
SWIFT
cat > $D/${N}Extras.swift <<SWIFT
import SwiftUI
import OracleKit

/// $N's own panels. Empty is fine; add ExtraSection(id:title:symbol:view:) entries to grow the app.
enum ${N}Extras {
    static let extras = Extras(sections: [])
}
SWIFT
cat > $D/app.yml <<YML
targets:
  $N:
    type: application
    supportedDestinations: [macOS, iOS]
    sources:
      - path: Apps/$N
        excludes: ["app.yml", "Info.plist"]
    dependencies:
      - package: OracleKit
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: co.laris.oracle.$low
        PRODUCT_NAME: $N
        INFOPLIST_KEY_CFBundleDisplayName: $N
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        TARGETED_DEVICE_FAMILY: "1,2"
        INFOPLIST_KEY_UILaunchScreen_Generation: YES
        ENABLE_APP_SANDBOX: NO
        ENABLE_HARDENED_RUNTIME: NO
    info:
      path: Apps/$N/Info.plist
      properties:
        CFBundleName: $N
        CFBundleDisplayName: $N
        CFBundleShortVersionString: \$(MARKETING_VERSION)
        CFBundleVersion: \$(CURRENT_PROJECT_VERSION)
        UILaunchScreen: {}
        CFBundleDocumentTypes:
          - CFBundleTypeName: Anything for $N
            CFBundleTypeRole: Viewer
            LSHandlerRank: Alternate
            LSItemContentTypes: [public.item, public.content, public.folder, public.url, public.data]
YML
zsh $R/scripts/regen.sh
echo "created Apps/$N"
