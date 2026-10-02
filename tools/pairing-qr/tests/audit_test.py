"""Public-source safety checks; no live account or endpoint required."""
from pathlib import Path
import hashlib
import json
import re
import unittest

ROOT = Path(__file__).resolve().parents[3]
ASSETS = ROOT / 'tools' / 'pairing-qr'

class AuditTests(unittest.TestCase):
    def test_vendored_bytes_match_official_pins(self):
        manifest = json.loads((ASSETS / 'vendor/provenance.json').read_text())
        self.assertEqual(manifest['license'], 'MIT')
        for name, digest in manifest['files'].items():
            self.assertEqual(hashlib.sha256((ASSETS / 'vendor' / name).read_bytes()).hexdigest(), digest)
        self.assertIn('Permission is hereby granted', (ASSETS / 'vendor/LICENSE').read_text())

    def test_runtime_has_no_network_storage_logging_or_export_apis(self):
        forbidden = r'\b(?:fetch|XMLHttpRequest|WebSocket|EventSource|localStorage|sessionStorage|indexedDB|serviceWorker|sendBeacon|clipboard|console|eval)\b|new\s+Function|document\.cookie|\bimport\s*\('
        for file in [ASSETS/'app.js',ASSETS/'core.js',ASSETS/'vendor/qrcode.js',ASSETS/'vendor/qrcode_UTF8.js']:
            self.assertIsNone(re.search(forbidden,file.read_text()),file.name)
        app = (ASSETS/'app.js').read_text()
        self.assertNotIn('innerHTML',app)
        self.assertNotIn('toDataURL',app)
        self.assertNotIn('toBlob',app)

    def test_scoped_public_files_have_no_private_operator_residue(self):
        files=[ROOT/'scripts/fleet-pairing-qr',ROOT/'docs/direct-pairing.md']
        files += [p for p in ASSETS.rglob('*') if p.is_file() and '__pycache__' not in p.parts]
        # Patterns assembled to avoid matching this safety test itself.
        forbidden=[r'/Users/' + r'[A-Za-z]',r'/home/' + r'[A-Za-z]',r'100\.' + r'70\.97\.111',
                   r'tail' + r'[a-f0-9]{6,}\.ts\.net']
        for file in files:
            for pattern in forbidden:
                self.assertIsNone(re.search(pattern,file.read_text()),file.name)

if __name__ == '__main__': unittest.main()
