import AppKit
import OracleKit

/// Share ▸ Sate Oracle — the panel lives in OracleKit (OracleShareViewController); this names the oracle.
final class ShareViewController: OracleShareViewController {
    override var config: OracleConfig { .sate }
}
