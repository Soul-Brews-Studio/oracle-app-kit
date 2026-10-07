#!/usr/bin/env zsh
# new-oracle-app.sh <Name> <org/repo> <mac checkout path> <#hex> <sf-symbol> "<tagline>"
#                   [--update] [--key <key>] [--port <n>] [--team <id>] [--no-regen]
# Creates Apps/<Name>/: the identity (shared with the widget), the app (Memory engine, Map layout, MCP server),
# its Extras, a WidgetKit status widget, a Share extension, entitlements (App Group), icon and xcodegen targets —
# then regenerates the project. The output matches Neo / Pulse / Nexus; scripts/parity.sh proves it.
#   <Name>   a Swift identifier (struct <Name>App); its lower-case form is OracleConfig.<name> and the widget kind
#   --key    bundle-id suffix, App Group, URL scheme and the portal's key: co.laris.oracle.<key>.
#            Default: the portal's rule, the repo name minus "-oracle", lower-cased (DustBoy-Phd-Oracle → dustboy-phd).
#   --port   the app's MCP memory server. Default: the next port from 4791 not used by another Apps/*/*App.swift.
#   --team   Apple signing team for the App Group. Default: $ORACLE_APP_TEAM, else project.yml's DEVELOPMENT_TEAM.
#   --update rewrites the generated files of an existing app but keeps <Name>Extras.swift and the icon.
set -e
N=${1:?Name}; SLUG=${2:?org/repo}; LP=${3:?mac path}; HEX=${4:?#hex}; SYM=${5:?symbol}; TAG=${6:-"$N oracle"}
R=${0:A:h}/..; D=$R/Apps/$N; low=${(L)N}
UPDATE=0; REGEN=1; KEY=""; PORT=""; TEAM=${ORACLE_APP_TEAM:-}
shift $(( $# < 6 ? $# : 6 ))
while (( $# )); do
  case $1 in
    --update) UPDATE=1 ;;
    --no-regen) REGEN=0 ;;
    --key) KEY=${2:?--key value}; shift ;;
    --port) PORT=${2:?--port value}; shift ;;
    --team) TEAM=${2:?--team value}; shift ;;
    *) echo "unknown option $1"; exit 2 ;;
  esac; shift
done
[[ $N =~ '^[A-Z][A-Za-z0-9]*$' ]] || { echo "Name must be a Swift type name (Neo, DustBoyPhd), got '$N' — use --key for the hyphenated portal key"; exit 2; }
if [ -z "$KEY" ]; then KEY=${SLUG#*/}; KEY=${KEY%-[Oo]racle}; KEY=${(L)KEY}; fi
[[ $KEY =~ '^[a-z][a-z0-9-]*$' ]] || { echo "key must be lower-case letters, digits and '-', got '$KEY'"; exit 2; }
[ -n "$TEAM" ] || TEAM=$(sed -n 's/^ *DEVELOPMENT_TEAM: *//p' $R/project.yml | head -1)
[ -n "$TEAM" ] || { echo "no signing team: export ORACLE_APP_TEAM=<id>  (list them: security find-identity -v -p codesigning)"; exit 2; }
if [ -z "$PORT" ]; then
  used=" $(rg -o --no-filename 'port: [0-9]+' $R/Apps/*/*App.swift 2>/dev/null | rg -v "^$" | sed 's/port: //' | tr '\n' ' ') "
  # an app being updated keeps its own port
  [ -f $D/${N}App.swift ] && PORT=$(rg -o --no-filename 'port: [0-9]+' $D/${N}App.swift | sed 's/port: //' | head -1)
  if [ -z "$PORT" ]; then PORT=4791; while [[ $used == *" $PORT "* ]]; do PORT=$((PORT + 1)); done; fi
fi
GROUP="$TEAM.co.laris.oracle.$KEY"
KEYARG=""; [ "$KEY" != "$low" ] && KEYARG=", key: \"$KEY\""   # Neo/Pulse/Nexus: key == name, no argument
[ -e $D ] && [ $UPDATE = 0 ] && { echo "Apps/$N exists — use --update to regenerate (keeps Extras + icon)"; exit 2; }
mkdir -p $D/Widget $D/Share $D/Assets.xcassets
[ -f $D/Assets.xcassets/Contents.json ] || print -r -- '{"info":{"version":1,"author":"xcode"}}' > $D/Assets.xcassets/Contents.json
[ -d $D/Assets.xcassets/AppIcon.appiconset ] || uv run --quiet --with pillow python $R/scripts/make_icon.py $D/Assets.xcassets/AppIcon.appiconset $HEX ${N[1]}
cat > $D/${N}Config.swift <<SWIFT
import OracleKit

/// $N's identity — compiled into both the app and its widget.
extension OracleConfig {
    static let ${low} = OracleConfig(
        name: "$N", tagline: "$TAG", repoSlug: "$SLUG",
        localPath: OracleConfig.mac("$LP"),
        colorHex: "$HEX", symbol: "$SYM"$KEYARG)
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
    @StateObject private var store = OracleStore(config: .${low}.with(extras: ${N}Extras.extras))
    init() {
        #if os(macOS)
        BundledANE.installLazily()   // Memory page: EmbeddingGemma 2 in-process, loaded when the page first opens
        MapLayoutEngine.install()   // Map page: UMAP in-process (Apple's Rust crate)
        MCPServer.serve(name: "${low}-memory", port: $PORT) { GHIndex.history(OracleConfig.${low}.repoSlug) }   // agents search ${N}'s memory
        #endif
    }
    @AppStorage("oracle.menuBar") private var menuBar = false      // the oracle's tray: off until switched on
    var body: some Scene { OracleScene(store: store, menuBar: \$menuBar) }
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
        excludes: ["app.yml", "Info.plist", "Widget/**", "Share/**", "*.entitlements"]
      - path: Apps/Shared
    preBuildScripts:
      - name: Build the tokenizer + UMAP (Rust)
        basedOnDependencyAnalysis: false
        script: |
          [ "\$PLATFORM_NAME" = macosx ] || exit 0
          export PATH="/opt/homebrew/opt/rustup/bin:\$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:\$PATH"
          if ! command -v cargo >/dev/null; then
            echo "error: cargo not found: the Memory page's embedder builds its tokenizer with Rust. Install it, then build again:"
            echo "error:   brew install rustup && rustup-init -y && . ~/.cargo/env"
            exit 1
          fi
          cd "\$SRCROOT/ANEEmbed/tokenizer-ffi" && cargo build --release --locked
    postBuildScripts:
      - name: Stamp CalVer
        basedOnDependencyAnalysis: false
        script: sh "\$SRCROOT/scripts/calver-stamp.sh"
    dependencies:
      - package: OracleKit
      - package: ANEEmbed           # the Memory page's in-process embedder (Mac only)
        product: ANEEmbedCore
        destinationFilters: [macOS]
      - package: ANEEmbed
        product: MapLayoutUMAP
        destinationFilters: [macOS]
      - target: ${N}Widget
      - target: ${N}Share
        destinationFilters: [macOS]
    entitlements:
      path: Apps/$N/${N}.entitlements
      properties:          # xcodegen WRITES this file from here — a path alone becomes an empty <dict/>
        com.apple.security.application-groups: [$GROUP]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: co.laris.oracle.$KEY
        PRODUCT_NAME: $N
        INFOPLIST_KEY_CFBundleDisplayName: $N
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        TARGETED_DEVICE_FAMILY: "1,2"
        INFOPLIST_KEY_UILaunchScreen_Generation: YES
        ENABLE_APP_SANDBOX: NO
        ENABLE_HARDENED_RUNTIME: NO
        ENABLE_USER_SCRIPT_SANDBOXING: NO     # the tokenizer is built with cargo
        "ARCHS[sdk=macosx*]": arm64           # the Neural Engine and the Float16 code exist only on Apple silicon
    info:
      path: Apps/$N/Info.plist
      properties:
        CFBundleName: $N
        CFBundleDisplayName: $N
        CFBundleShortVersionString: \$(MARKETING_VERSION)
        CFBundleVersion: \$(CURRENT_PROJECT_VERSION)
        UILaunchScreen: {}
        CFBundleURLTypes:            # widget taps open oracle-<name>://open — the app must own the scheme
          - CFBundleURLName: co.laris.oracle.$KEY
            CFBundleURLSchemes: [oracle-$KEY]
        CFBundleDocumentTypes:
          - CFBundleTypeName: Anything for $N
            CFBundleTypeRole: Viewer
            LSHandlerRank: Alternate
            LSItemContentTypes: [public.item, public.content, public.folder, public.url, public.data]
        NSServices:                  # right-click → Services, anywhere: selected text, links, Finder files
          - NSMenuItem: { default: "New $N Oracle issue" }
            NSMessage: newIssue
            NSPortName: $N
            NSSendTypes: [public.utf8-plain-text, public.plain-text, public.url, public.file-url]
            NSSendFileTypes: [public.item]
            NSRequiredContext: {}       # enabled by default — without it macOS hides the service until switched on
          - NSMenuItem: { default: "Send to $N Oracle inbox" }
            NSMessage: sendToInbox
            NSPortName: $N
            NSSendTypes: [public.utf8-plain-text, public.plain-text, public.url, public.file-url]
            NSSendFileTypes: [public.item]
            NSRequiredContext: {}
          - NSMenuItem: { default: "Message $N Oracle" }
            NSMessage: messageOracle
            NSPortName: $N
            NSSendTypes: [public.utf8-plain-text, public.plain-text, public.url, public.file-url]
            NSSendFileTypes: [public.item]
            NSRequiredContext: {}
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
        PRODUCT_BUNDLE_IDENTIFIER: co.laris.oracle.$KEY.widget
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
  ${N}Share:                    # the macOS Share menu entry (Share ▸ ${N} Oracle) — OracleShareViewController
    type: app-extension
    supportedDestinations: [macOS]
    sources:
      - path: Apps/${N}/Share
        excludes: ["*.entitlements", "Info.plist"]
      - path: Apps/${N}/${N}Config.swift
    dependencies:
      - package: OracleKit
    entitlements:
      path: Apps/${N}/Share/${N}Share.entitlements
      properties:
        com.apple.security.app-sandbox: true
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: co.laris.oracle.${KEY}.share
        PRODUCT_NAME: ${N}Share
        SKIP_INSTALL: YES
        ENABLE_APP_SANDBOX: YES
    info:
      path: Apps/${N}/Share/Info.plist
      properties:
        CFBundleDisplayName: ${N} Oracle
        CFBundleShortVersionString: \$(MARKETING_VERSION)
        CFBundleVersion: \$(CURRENT_PROJECT_VERSION)
        NSExtension:
          NSExtensionPointIdentifier: com.apple.share-services
          NSExtensionPrincipalClass: \$(PRODUCT_MODULE_NAME).ShareViewController
          NSExtensionAttributes:
            NSExtensionActivationRule:
              NSExtensionActivationSupportsWebURLWithMaxCount: 1
              NSExtensionActivationSupportsText: true
              NSExtensionActivationSupportsFileWithMaxCount: 1
YML
cat > $D/Share/ShareViewController.swift <<SWIFT
import AppKit
import OracleKit

/// Share ▸ ${N} Oracle — the panel lives in OracleKit (OracleShareViewController); this names the oracle.
final class ShareViewController: OracleShareViewController {
    override var config: OracleConfig { .${low} }
}
SWIFT
(( REGEN )) && zsh $R/scripts/regen.sh
echo "ready Apps/$N (+ ${N}Widget, ${N}Share) · key $KEY · co.laris.oracle.$KEY · MCP :$PORT · team $TEAM"
