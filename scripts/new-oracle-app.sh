#!/usr/bin/env zsh
# new-oracle-app.sh <Name> <org/repo> <mac checkout path> <#hex> <sf-symbol> "<tagline>" [--update]
# Creates Apps/<Name>/: the identity (shared with the widget), the app, its Extras, a WidgetKit status
# widget, entitlements (App Group), icon and xcodegen targets — then regenerates the project.
# --update rewrites the generated files of an existing app but keeps <Name>Extras.swift and the icon.
set -e
N=${1:?Name}; SLUG=${2:?org/repo}; LP=${3:?mac path}; HEX=${4:?#hex}; SYM=${5:?symbol}; TAG=${6:-"$N oracle"}
UPDATE=0; [[ " $* " == *" --update "* ]] && UPDATE=1
R=${0:A:h}/..; D=$R/Apps/$N; low=${(L)N}; GROUP="6K28WEXX78.co.laris.oracle.$low"
[ -e $D ] && [ $UPDATE = 0 ] && { echo "Apps/$N exists — use --update to regenerate (keeps Extras + icon)"; exit 2; }
mkdir -p $D/Widget $D/Assets.xcassets
[ -f $D/Assets.xcassets/Contents.json ] || print -r -- '{"info":{"version":1,"author":"xcode"}}' > $D/Assets.xcassets/Contents.json
[ -d $D/Assets.xcassets/AppIcon.appiconset ] || uv run --quiet --with pillow python $R/scripts/make_icon.py $D/Assets.xcassets/AppIcon.appiconset $HEX ${N[1]}
cat > $D/${N}Config.swift <<SWIFT
import OracleKit

/// $N's identity — compiled into both the app and its widget.
extension OracleConfig {
    static let ${low} = OracleConfig(
        name: "$N", tagline: "$TAG", repoSlug: "$SLUG",
        localPath: OracleConfig.mac("$LP"),
        colorHex: "$HEX", symbol: "$SYM")
}
SWIFT
cat > $D/${N}App.swift <<SWIFT
import SwiftUI
import OracleKit

@main
struct ${N}App: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(OracleAppDelegate.self) var delegate
    #endif
    var body: some Scene { OracleScene(config: .${low}.with(extras: ${N}Extras.extras)) }
}
SWIFT
[ -f $D/${N}Extras.swift ] || cat > $D/${N}Extras.swift <<SWIFT
import SwiftUI
import OracleKit

/// $N's own panels. Empty is fine; add ExtraSection(id:title:symbol:view:) entries to grow the app.
enum ${N}Extras {
    static let extras = Extras(sections: [])
}
SWIFT
cat > $D/Widget/${N}Widget.swift <<SWIFT
import WidgetKit
import SwiftUI
import OracleKit

@main
struct ${N}Widgets: WidgetBundle {
    var body: some Widget { ${N}StatusWidget() }
}

/// The configuration lives HERE, in the extension, with literal names (like homelab's working widget).
/// Built inside the OracleKit package it crashed at load: WidgetKit asserts on configurations made in a package.
/// NEVER change \`kind\`: widgets already on a desktop are bound to it. Renaming it (2026-10-07) left every
/// placed widget on a grey placeholder — chronod kept reloading the old kind and failed (CHSErrorDomain 1050).
struct ${N}StatusWidget: Widget {
    let kind = "oracle.status.${low}"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: OracleProvider(config: .${low})) { OracleWidgetView(entry: \$0) }
            .configurationDisplayName("$N Oracle")
            .description("$N Oracle: working panes, open PRs, issues and inbox.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
SWIFT
# the widget's emblem: the oracle's Codex icon when design/icons/<Name>.png exists (else an SF Symbol)
if [ -f $R/design/icons/$N.png ]; then
  E=$D/Widget/Assets.xcassets/Emblem.imageset; mkdir -p $E
  print -r -- '{"info":{"version":1,"author":"xcode"}}' > $D/Widget/Assets.xcassets/Contents.json
  sips -Z 96 $R/design/icons/$N.png --out $E/emblem.png >/dev/null
  print -r -- '{"images":[{"idiom":"universal","filename":"emblem.png"}],"info":{"version":1,"author":"xcode"}}' > $E/Contents.json
fi
cat > $D/${N}.entitlements <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.application-groups</key><array><string>$GROUP</string></array>
</dict></plist>
PL
cat > $D/Widget/${N}Widget.entitlements <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.app-sandbox</key><true/>
  <key>com.apple.security.application-groups</key><array><string>$GROUP</string></array>
</dict></plist>
PL
cat > $D/app.yml <<YML
targets:
  $N:
    type: application
    supportedDestinations: [macOS, iOS]
    sources:
      - path: Apps/$N
        excludes: ["app.yml", "Info.plist", "Widget/**", "*.entitlements"]
    dependencies:
      - package: OracleKit
      - target: ${N}Widget
    entitlements:
      path: Apps/$N/${N}.entitlements
      properties:          # xcodegen WRITES this file from here — a path alone becomes an empty <dict/>
        com.apple.security.application-groups: [$GROUP]
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
        CFBundleURLTypes:            # widget taps open oracle-<name>://open — the app must own the scheme
          - CFBundleURLName: co.laris.oracle.$low
            CFBundleURLSchemes: [oracle-$low]
        CFBundleDocumentTypes:
          - CFBundleTypeName: Anything for $N
            CFBundleTypeRole: Viewer
            LSHandlerRank: Alternate
            LSItemContentTypes: [public.item, public.content, public.folder, public.url, public.data]
  ${N}Widget:
    type: app-extension
    supportedDestinations: [macOS, iOS]
    sources:
      - path: Apps/$N/Widget
        excludes: ["*.entitlements", "Info.plist"]
      - path: Apps/$N/${N}Config.swift
    dependencies:
      - package: OracleKit
      - sdk: WidgetKit.framework
      - sdk: SwiftUI.framework
    entitlements:
      path: Apps/$N/Widget/${N}Widget.entitlements
      properties:
        com.apple.security.app-sandbox: true
        com.apple.security.application-groups: [$GROUP]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: co.laris.oracle.$low.widget
        PRODUCT_NAME: ${N}Widget
        TARGETED_DEVICE_FAMILY: "1,2"
        SKIP_INSTALL: YES
        ENABLE_APP_SANDBOX: YES
    info:
      path: Apps/$N/Widget/Info.plist
      properties:
        CFBundleDisplayName: $N Oracle
        CFBundleShortVersionString: \$(MARKETING_VERSION)
        CFBundleVersion: \$(CURRENT_PROJECT_VERSION)
        NSExtension:
          NSExtensionPointIdentifier: com.apple.widgetkit-extension
YML
zsh $R/scripts/regen.sh
echo "ready Apps/$N (+ ${N}Widget)"
