import AppKit
import OracleKit

/// Share ▸ Relic5 Oracle — the panel lives in OracleKit (OracleShareViewController); this names the oracle.
final class ShareViewController: OracleShareViewController {
    override var config: OracleConfig { .relic5 }
}
