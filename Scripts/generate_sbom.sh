#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_path="${1:-"$repo_root/dist/sbom/screenq-sbom.json"}"

screenq_version="${SCREENQ_VERSION:-0.1.0-dev}"
freerdp_version="${FREERDP_VERSION:-3.25.0}"
openssl_version="${OPENSSL_VERSION:-3.6.2}"
git_revision="${GIT_REVISION:-$(git -C "$repo_root" rev-parse --short=12 HEAD 2>/dev/null || printf unknown)}"
timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
serial_uuid="$(uuidgen | tr '[:upper:]' '[:lower:]')"

mkdir -p "$(dirname "$output_path")"

cat > "$output_path" <<EOF
{
  "bomFormat": "CycloneDX",
  "specVersion": "1.5",
  "serialNumber": "urn:uuid:${serial_uuid}",
  "version": 1,
  "metadata": {
    "timestamp": "${timestamp}",
    "component": {
      "type": "application",
      "bom-ref": "screenq-app",
      "name": "Screen Q",
      "version": "${screenq_version}",
      "purl": "pkg:generic/screen-q@${screenq_version}?vcs_url=local"
    },
    "properties": [
      { "name": "screenq.gitRevision", "value": "${git_revision}" },
      { "name": "screenq.sbom.generator", "value": "Scripts/generate_sbom.sh" }
    ]
  },
  "components": [
    {
      "type": "application",
      "bom-ref": "screenq-app",
      "name": "Screen Q",
      "version": "${screenq_version}",
      "scope": "required"
    },
    {
      "type": "library",
      "bom-ref": "screenq-freerdp-bridge",
      "name": "ScreenQFreeRDPBridge",
      "version": "${screenq_version}",
      "scope": "required",
      "properties": [
        { "name": "screenq.sourcePath", "value": "Vendor/ScreenQFreeRDPBridge" }
      ]
    },
    {
      "type": "library",
      "bom-ref": "freerdp",
      "name": "FreeRDP",
      "version": "${freerdp_version}",
      "scope": "required",
      "purl": "pkg:github/FreeRDP/FreeRDP@${freerdp_version}"
    },
    {
      "type": "library",
      "bom-ref": "openssl",
      "name": "OpenSSL",
      "version": "${openssl_version}",
      "scope": "required",
      "purl": "pkg:generic/openssl@${openssl_version}"
    }
  ],
  "dependencies": [
    {
      "ref": "screenq-app",
      "dependsOn": [
        "screenq-freerdp-bridge",
        "freerdp",
        "openssl"
      ]
    }
  ]
}
EOF

echo "Wrote SBOM to $output_path"
