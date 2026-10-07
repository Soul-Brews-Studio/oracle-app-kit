#!/usr/bin/env zsh
# new-oracle-app.sh <Name> <org/repo> <mac checkout path> <#hex> <sf-symbol> ["<tagline>"]
#                   [--update] [--key=<key>] [--port=<n>] [--team=<id>] [--no-regen]     (also "--key <key>" …)
# Creates Apps/<Name>/: the identity (shared with the widget), the app (Memory engine, Map layout, MCP server),
# its Extras, a WidgetKit status widget, a Share extension, entitlements (App Group), icon and xcodegen targets —
# then regenerates the project. The output matches Neo / Pulse / Nexus; scripts/parity.sh proves it.
#   <Name>   a Swift identifier (struct <Name>App); its lower-case form is OracleConfig.<name> and the widget kind
#   --key    bundle-id suffix, App Group, URL scheme and the portal's key: co.laris.oracle.<key>.
#            Default: the portal's rule, the repo name minus "-oracle", lower-cased (DustBoy-Phd-Oracle → dustboy-phd).
#   --port   the app's MCP memory server. Default: the next port from 4791 that no other Apps/*/*App.swift uses
#            and nothing on this Mac listens on.
#   --team   Apple signing team (Team ID) for the App Group. Default: --update keeps the app's own; else
#            $ORACLE_APP_TEAM; else project.yml's DEVELOPMENT_TEAM if a certificate on this Mac has it, else this Mac's
#            only certificate's team (several: refuses and prints one command per team).
#   --update rewrites the generated files of an existing app; keeps <Name>Extras.swift, the icon, and — unless given
#            again — its key, port and team (read back from its app.yml / App.swift / entitlements).
# Needs: zsh, sed, lsof (/usr/sbin), security + openssl (team), xcodegen (regen), uv (icon: draws one, or resizes
# design/icons/<Name>.png).
# Refuses before writing anything.
set -e
die() { print -r -- "✗ $*"; exit 2; }
usage='usage:  zsh scripts/new-oracle-app.sh <Name> <org/repo> <mac checkout path> <#rrggbb> <sf-symbol> ['"'"'<tagline>'"'"'] [--update] [--key=k] [--port=n] [--team=id] [--no-regen]'
ARGS=("$@"); pos=(); UPDATE=0; REGEN=1; KEY=""; PORT=""; TEAM=""
while (( $# )); do
  case $1 in
    --update) UPDATE=1 ;;
    --no-regen) REGEN=0 ;;
    --key=*|--port=*|--team=*) v=${1#*=}; [ -n "$v" ] || die "$1: empty value — $usage"; typeset -g ${${1%%=*}#--}_opt=$v ;;
    --key|--port|--team) [ -n "${2:-}" ] && [[ $2 != --* ]] || die "$1 needs a value — $usage"; typeset -g ${1#--}_opt=$2; shift ;;
    --*) die "unknown option $1 — $usage" ;;
    *) pos+=("$1") ;;
  esac; shift
done
KEY=${key_opt:-}; PORT=${port_opt:-}; TEAM=${team_opt:-}; OLDPORT=""; KEYSRC=${key_opt:+--key}; TEAMSRC=${team_opt:+--team}
(( $#pos >= 5 && $#pos <= 6 )) || die "$usage"
N=$pos[1]; SLUG=$pos[2]; LP=$pos[3]; HEX=$pos[4]; SYM=$pos[5]; TAG=${pos[6]:-"$N oracle"}
R=${0:A:h}/..; R=${R:A}; D=$R/Apps/$N; low=${(L)N}
[[ $N =~ '^[A-Z][A-Za-z0-9]*$' ]] || die "Name must be a Swift type name (Neo, DustBoyPhd), got '$N' — the hyphenated portal key goes in --key"
# the lower-case Name becomes a declaration (static let <name> = OracleConfig(…)): not a Swift keyword
swiftkw=(associatedtype class deinit enum extension fileprivate func import init inout internal let operator private
  precedencegroup protocol public rethrows static struct subscript typealias var break case catch continue default defer
  do else fallthrough for guard if in repeat return throw switch where while as false is nil self super throws true try)
if (( ${swiftkw[(Ie)$low]} )); then
  alt=(); for a in "${ARGS[@]}"; do [[ $a == $N ]] && alt+=(${N}Oracle) || alt+=("$a"); done
  die "Name '$N' lower-cases to the Swift keyword '$low' (OracleConfig.$low would not compile); the key still comes from the repo — e.g.:  zsh $0 ${(q)alt[@]}"
fi
[[ $SLUG == */* ]] || die "repo must be org/repo, got '$SLUG'"
[[ $HEX =~ '^#[0-9a-fA-F]{6}$' ]] || die "colour must be #rrggbb, got '$HEX'"
# these land inside Swift string literals and are read back by scripts/parity.sh — no '"' or '\'
# ASCII controls only, spelled out: [[:cntrl:]] is per-locale, and in UTF-8 it also hits joiners, ZWSP, soft hyphen,
# bidi marks — characters a Swift literal takes fine (an emoji ZWJ sequence, Thai word breaks)
cc=$'[\001-\037\177"\\\\]'
for v in "$SLUG" "$LP" "$TAG" "$SYM"; do [[ $v == *${~cc}* ]] && die "no '\"', '\\' or ASCII control (tab, newline) in the identity (got: ${(q)v}) — e.g.:  zsh $0 ${(@q)${(@)ARGS//${~cc}/}}"; done
[[ $LP == /* ]] || die "mac checkout path must be absolute, got '$LP' — the oracle's main checkout:  ghq list -p --exact $SLUG"
[[ -n ${ORACLE_APP_SCRATCH:-} || -d $LP ]] || die "no checkout at $LP on this Mac — clone it:  ghq get -p $SLUG"
[ -n "$SYM" ] || die "sf-symbol is empty — pass one, e.g. star.fill"
# Apps/Hub, Apps/Shared, Apps/MapSpike… are not this generator's (no <Name>Config.swift): never write into them
if [ -e $D ] && [ ! -f $D/${N}Config.swift ]; then
  alt=(); for a in "${ARGS[@]}"; do [[ $a == $N ]] && alt+=(${N}Oracle) || [[ $a == --update ]] || alt+=("$a"); done
  die "Apps/$N exists but is not an app this generator made (no ${N}Config.swift) — use another Name:  zsh $0 ${(q)alt[@]}"
fi
[ -e $D ] && (( ! UPDATE )) && die "Apps/$N exists — regenerate it (keeps Extras, icon, key, port, team):  zsh $0 ${(q)ARGS[@]} --update"
[ ! -e $D ] && (( UPDATE )) && { new=("${(@)ARGS:#--update}"); die "Apps/$N does not exist — create it:  zsh $0 ${(q)new[@]}"; }
# --update: what the app already is wins over the defaults (an explicit option still wins over both)
if (( UPDATE )); then
  [ -n "$KEY" ]  || { KEY=$(sed -n 's/^ *PRODUCT_BUNDLE_IDENTIFIER: co\.laris\.oracle\.\([a-z0-9-]*\)$/\1/p' $D/app.yml 2>/dev/null | head -1); KEYSRC=${KEY:+Apps/$N/app.yml}; }
  OLDPORT=$(sed -n 's/.*port: \([0-9][0-9]*\).*/\1/p' $D/${N}App.swift 2>/dev/null | head -1); [ -n "$PORT" ] || PORT=$OLDPORT
  [ -n "$TEAM" ] || { TEAM=$(sed -n 's/.*<string>\([A-Z0-9]*\)\.co\.laris\.oracle\.[a-z0-9-]*<\/string>.*/\1/p' $D/${N}.entitlements 2>/dev/null | head -1); TEAMSRC=${TEAM:+Apps/$N/$N.entitlements}; }
fi
# the portal's rule (HubParse.appKey): repo minus "-oracle", lower-cased, "_" and "." → "-" (a bundle id has no "_")
if [ -z "$KEY" ]; then KEY=${(L)${SLUG#*/}}; KEY=${KEY%-oracle}; KEY=${KEY//[_.]/-}; KEYSRC="the repo name $SLUG"; fi
# the same command again, minus any --key — so a printed fix keeps --update / --port / --team / --no-regen
again=(); skip=0; for a in "${ARGS[@]}"; do if (( skip )); then skip=0; elif [[ $a == --key ]]; then skip=1; elif [[ $a != --key=* ]]; then again+=("$a"); fi; done
if [[ ! $KEY =~ '^[a-z0-9][a-z0-9-]*$' ]]; then   # a digit first is legal in a bundle id (3e-infra-oracle → 3e-infra)
  fix=${${(L)KEY}//[^a-z0-9-]/-}; fix=${fix#${fix%%[a-z0-9]*}}; [ -n "$fix" ] || fix=$low
  die "key '$KEY' (from $KEYSRC) may hold only a-z, 0-9 and '-', not first — e.g.:  zsh $0 ${(q)again[@]} --key=$fix"
fi
source $R/scripts/team.sh
[ -n "$TEAM" ] || { TEAM=${ORACLE_APP_TEAM:-}; TEAMSRC=${TEAM:+ORACLE_APP_TEAM}; }
if [ -z "$TEAM" ]; then
  pteam=$(project_team)
  if [[ -n ${ORACLE_APP_SCRATCH:-} ]]; then TEAM=$pteam; TEAMSRC=project.yml   # scratch generation: no keychain
  else
    teams=(${(f)"$(cert_teams)"})
    if (( ${teams[(Ie)$pteam]} )); then TEAM=$pteam; TEAMSRC="project.yml, a certificate on this Mac"
    elif (( $#teams == 1 )); then TEAM=$teams[1]; TEAMSRC="this Mac's only signing certificate"
    elif (( $#teams == 0 )); then die "no signing certificate on this Mac — Xcode → Settings → Accounts → sign in, then:  zsh $0 ${(q)ARGS[@]}"
    else die "several signing teams on this Mac (${teams[*]}), none is project.yml's $pteam — pick one:$(for t in $teams; do print -rn -- $'\n'"    zsh $0 ${(q)ARGS[@]} --team=$t"; done)"
    fi
  fi
fi
if [[ ! $TEAM =~ '^[A-Z0-9]{10}$' ]]; then   # the last --team wins, so the printed line overrides whatever was wrong
  sug=$(cert_teams | head -1)
  die "team '$TEAM' (from $TEAMSRC) is not a 10-character Team ID — e.g.:  zsh $0 ${(q)ARGS[@]} --team=${sug:-\$(security find-certificate -c 'Apple Development' -p | openssl x509 -noout -subject | sed -n 's/.*OU *= *\([A-Z0-9]*\).*/\1/p')}"
fi
# what every OTHER app already holds: bundle keys, MCP ports, colours
others=(); for a in $R/Apps/*/app.yml(N); do [[ ${a:h:t} == $N ]] || others+=(${a:h:t}); done
okeys=" "; oports=" "; ohex=" "
for o in $others; do
  okeys+="$(sed -n 's/^ *PRODUCT_BUNDLE_IDENTIFIER: co\.laris\.oracle\.\([a-z0-9-]*\)$/\1/p' $R/Apps/$o/app.yml | head -1) "
  for f in $R/Apps/$o/*App.swift(N); do oports+="$(sed -n 's/.*port: \([0-9][0-9]*\).*/\1/p' $f | head -1) "; done
  for f in $R/Apps/$o/*Config.swift(N); do ohex+="$(sed -n 's/.*colorHex: "\(#[0-9a-fA-F]*\)".*/\1/p' $f | head -1) "; done
done
if [[ $okeys == *" $KEY "* ]]; then
  free=$KEY-2; i=2; while [[ $okeys == *" $free "* ]]; do i=$((i + 1)); free=$KEY-$i; done
  die "key '$KEY' (from $KEYSRC) is already another app's (co.laris.oracle.$KEY) — a free one:  zsh $0 ${(q)again[@]} --key=$free"
fi
[[ ${(L)ohex} == *" ${(L)HEX} "* ]] && die "colour $HEX is already another app's — the taken ones, then pass another #rrggbb:  rg -o 'colorHex: \"#[0-9a-fA-F]{6}\"' $R/Apps/*/*Config.swift"
# a live listener check; scripts/parity.sh generates into a scratch copy and sets ORACLE_APP_SCRATCH=1 to skip it
live() { lsof -nP -iTCP:$1 -sTCP:LISTEN -t >/dev/null 2>&1 }   # false when lsof is missing
listening() {
  [[ -z ${ORACLE_APP_SCRATCH:-} ]] || return 1
  command -v lsof >/dev/null || die "lsof not found (macOS keeps it in /usr/sbin):  export PATH=\$PATH:/usr/sbin"
  live $1
}
if [ -n "$PORT" ]; then
  [[ $PORT =~ '^[1-9][0-9]{0,4}$' ]] && (( PORT <= 65535 )) || {
    free=4791; while [[ $oports == *" $free "* ]] || live $free; do free=$((free + 1)); done
    die "port must be 1–65535, no leading zero, got '$PORT' — a free one (the last --port wins):  zsh $0 ${(q)ARGS[@]} --port=$free"; }
  if [[ $oports == *" $PORT "* ]]; then
    free=4791; while [[ $oports == *" $free "* ]] || live $free; do free=$((free + 1)); done   # a suggestion must be free HERE, scratch or not
    die "port $PORT is already another app's MCP port — a free one (the last --port wins):  zsh $0 ${(q)ARGS[@]} --port=$free"
  fi
  # the app's own port is exempt (it is the app listening); any other port must be free
  if [[ $PORT != ${OLDPORT:-} ]] && listening $PORT; then die "something already listens on :$PORT —  lsof -nP -iTCP:$PORT -sTCP:LISTEN"; fi
else
  PORT=4791; while [[ $oports == *" $PORT "* ]] || listening $PORT; do PORT=$((PORT + 1)); done
fi
if (( REGEN )) && ! command -v xcodegen >/dev/null; then
  die "xcodegen is needed to regenerate the project:  brew install xcodegen   (or add --no-regen and run scripts/regen.sh later)"
fi
if [ -f $R/design/icons/$N.png ] && [[ $(file -b --mime-type $R/design/icons/$N.png) != image/* ]]; then
  die "design/icons/$N.png is not an image — set it aside and the generator draws the icon:  mv $R/design/icons/$N.png $R/design/icons/$N.png.bad"
fi
# an icon is there only when make_icon.py got to its LAST file (Contents.json): a failed run leaves an empty folder
if [[ -z ${ORACLE_APP_SCRATCH:-} ]] && [ ! -f $D/Assets.xcassets/AppIcon.appiconset/Contents.json ] && ! command -v uv >/dev/null; then
  die "uv is needed to make the icon:  brew install uv"
fi
GROUP="$TEAM.co.laris.oracle.$KEY"
KEYARG=""; [ "$KEY" != "$low" ] && KEYARG=", key: \"$KEY\""   # Neo/Pulse/Nexus: key == name, no argument
mkdir -p $D/Widget $D/Share $D/Assets.xcassets
[ -f $D/Assets.xcassets/Contents.json ] || print -r -- '{"info":{"version":1,"author":"xcode"}}' > $D/Assets.xcassets/Contents.json
# the icon: design/icons/<Name>.png (a Codex / imagegen emblem) resized when present, else drawn
icon_from=(); [ -f $R/design/icons/$N.png ] && icon_from=(--from $R/design/icons/$N.png)
[ -f $D/Assets.xcassets/AppIcon.appiconset/Contents.json ] || [ -n "${ORACLE_APP_SCRATCH:-}" ] || uv run --quiet --with pillow python $R/scripts/make_icon.py $D/Assets.xcassets/AppIcon.appiconset $HEX ${N[1]} $icon_from
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
            echo "error:   brew install rustup && /opt/homebrew/opt/rustup/bin/rustup default stable"
            exit 1
          fi
          cd "\$SRCROOT/ANEEmbed/tokenizer-ffi" && cargo build --release --locked
    postBuildScripts:
      - name: Stamp CalVer
        basedOnDependencyAnalysis: false
        inputFiles:                           # after ProcessInfoPlistFile, which would overwrite the stamp
          - \$(TARGET_BUILD_DIR)/\$(INFOPLIST_PATH)
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
echo "ready Apps/$N (+ ${N}Widget, ${N}Share) · key $KEY · co.laris.oracle.$KEY · MCP :$PORT · team $TEAM ($TEAMSRC)"
