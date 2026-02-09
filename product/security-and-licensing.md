# Security & Privacy

## Local-First Security Model
- Services bind to 127.0.0.1 only by default
- All API keys (local + frontier) stored encrypted via OS keychain (macOS Keychain, Windows Credential Manager)
- Model downloads verified via checksum/manifest
- No remote telemetry unless opt-in
- No network calls to external services unless user explicitly configures a frontier API provider

## Frontier API Security (cloud providers)
- **Explicit consent required**: First use of any cloud provider triggers a consent modal ("Your data leaves your device")
- **Per-provider consent tracking**: Stored locally, user can revoke in Settings
- **API keys**: Never stored in plaintext — always in OS keychain with app-scoped reference
- **Data-in-transit**: All frontier API calls use HTTPS/TLS. App refuses non-HTTPS endpoints for cloud providers.
- **No key sharing**: API keys are never sent to Studiomc servers, never logged, never included in diagnostics export
- **Provider isolation**: Each provider's key is stored and managed independently. Disabling a provider removes it from the model list but preserves the key for re-enabling.
- **Clear labeling**: All cloud models show amber "Cloud" badge. User always knows when data leaves device.

## Threat Model
Protect against:
- Local malware scraping files — best effort: encryption at rest for keys only, OS keychain for API keys
- Malicious model files — sandbox + checksum + allowlist for curated downloads
- Prompt injection via documents — RAG sanitizer + source display
- Accidental cloud data leakage — no cloud calls without explicit provider configuration + per-provider consent
- API key exposure — keys in OS keychain only, never in logs/diagnostics/config files

## LRE Security (critical for REPL-like system)
- **Hard rule: No unrestricted shell** — LRE is NOT a general OS REPL
- No bash, no file writes outside app sandbox
- Read-only access to user-approved folders
- Allowlist of operations with strict parameter validation
- Safe tools only: search, grep, open, summarize, table_extract, cite

## Permission UX
- First time user adds a folder: OS-native permission prompt
- "This app can read these folders only"
- Clear revoke option in Settings
- First time user adds a cloud provider: consent modal with privacy explanation
- Clear disable/remove option per provider in Settings → Advanced → Model Backends

---

# Licensing & Compliance (Apache 2.0 and Mixed OSS)

## Compliance Objectives
- Ship a commercial desktop app while fully complying with Apache 2.0 obligations
- Maintain a complete and auditable third-party notice trail inside the installer and app UI

## Required Artifacts (must ship)
- `/THIRD_PARTY_NOTICES.md` — inventory of all third-party components with license type and source
- `/LICENSES/` directory — `APACHE-2.0.txt` + all bundled dependency license texts
- `/NOTICE` file — upstream NOTICE contents verbatim (Apache 2.0 §4(d)) + our addendum

## In-App Disclosure
- Settings → About → "Open Source Licenses" — displays THIRD_PARTY_NOTICES, full license texts, NOTICE file
- Installer includes a "Third-party licenses" link

## Engineering Rules
- Any modified Apache-derived file must contain header: "Modified by [Company] on [YYYY-MM-DD]" + brief description
- CI blocks merges if: dependency introduced without license metadata, NOTICE obligations not satisfied, license texts missing

## Release Checklist
- Run OSS license scan (ScanCode/FOSSA or equivalent)
- Generate THIRD_PARTY_NOTICES + LICENSES bundle
- Verify NOTICE propagation requirements
- Confirm product branding does not imply upstream endorsement

---

# Engineering Risks (and Mitigation)

1. **Python packaging hell** — Mitigation: embed runtime, pin deps, ship wheels, minimize native compilation on user machine
2. **User disappointment from slow models** — Mitigation: recommendation engine + warnings + speed rating + hard defaults
3. **Model format fragmentation** — Mitigation: curated list + import support + background verification
4. **Support burden** — Mitigation: diagnostics export + deterministic installers + strong defaults
5. **CLaRa end-to-end training is non-trivial** — Mitigation: ship with CLaRa compression first, train later
6. **Citations require text mapping** — Mitigation: minimal text-on-demand layer
7. **Model compatibility/licensing** — Mitigation: keep CLaRa modules optional, pluggable, local
