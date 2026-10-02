"""Only synthetic values. Never pass real credentials to this test runner."""
import pathlib
import subprocess
import sys
import tempfile
import unittest
import os
import stat

ROOT = pathlib.Path(__file__).resolve().parents[3]
LAUNCHER = ROOT / 'scripts' / 'fleet-pairing-qr'

class LauncherTests(unittest.TestCase):
    def test_private_offline_page_and_nonsecret_prefill(self):
        self.assertTrue(LAUNCHER.is_file(), 'private Mac launcher must exist')
        with tempfile.TemporaryDirectory() as home:
            result = subprocess.run([sys.executable, str(LAUNCHER), '--prepare-only',
                '--url', 'https://gateway.example.ts.net:8443', '--name', 'Fixture </script>',
                '--username', 'fixture-user'], env={**os.environ, 'HOME':home},
                capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            page = pathlib.Path(result.stdout.strip())
            self.assertTrue(page.is_file())
            self.assertEqual(stat.S_IMODE(page.stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(page.parent.stat().st_mode), 0o700)
            text = page.read_text()
            self.assertIn('Content-Security-Policy', text)
            import html
            self.assertIn("connect-src 'none'", html.unescape(text))
            self.assertIn("form-action 'none'", html.unescape(text))
            self.assertIn('fixture-user', text)
            self.assertIn('Fixture &lt;/script&gt;', text)
            self.assertNotIn('<script src=', text)
            self.assertNotIn('https://gateway.example.ts.net:8443', result.stdout)

    def test_secret_flags_are_rejected_without_echo(self):
        self.assertTrue(LAUNCHER.is_file(), 'private Mac launcher must exist')
        for option in ['--password','--token','--grant','--session-token','--unknown']:
            result = subprocess.run([sys.executable,str(LAUNCHER),option,'fixture-rejected-value'],
                capture_output=True,text=True)
            self.assertNotEqual(result.returncode,0)
            self.assertNotIn('fixture-rejected-value', result.stdout+result.stderr)

    def test_template_marker_prefill_is_literal(self):
        with tempfile.TemporaryDirectory() as home:
            result = subprocess.run([sys.executable,str(LAUNCHER),'--prepare-only','--name','@@SCRIPTS@@'],
                env={**os.environ,'HOME':home},capture_output=True,text=True)
            self.assertEqual(result.returncode,0)
            text = pathlib.Path(result.stdout.strip()).read_text()
            self.assertIn('value="@@SCRIPTS@@"',text,'prefill must never be reinterpreted as template markup')

    def test_prefill_url_cannot_carry_credentials_or_query(self):
        for url in ['https://user:fixture@gateway.example.ts.net', 'https://gateway.example.ts.net?fixture',
                    'https://gateway.example.ts.net#fixture', 'http://gateway.example.ts.net',
                    'https://gateway.example.ts.net/path', 'https://gateway.example.ts.net:0',
                    'https://gateway.example.ts.net:65536', 'https://gateway.example.ts.net\\n']:
            with tempfile.TemporaryDirectory() as home:
                result = subprocess.run([sys.executable,str(LAUNCHER),'--prepare-only','--url',url],
                    env={**os.environ,'HOME':home},capture_output=True,text=True)
                self.assertNotEqual(result.returncode,0,'unsafe prefill origin must be rejected before writing')
                self.assertNotIn(url, result.stdout+result.stderr)
                self.assertFalse(list(pathlib.Path(home).rglob('index.html')))

    def test_private_directory_symlink_is_rejected(self):
        with tempfile.TemporaryDirectory() as home:
            support = pathlib.Path(home) / 'Library' / 'Application Support'
            support.mkdir(parents=True)
            public = pathlib.Path(home) / 'public'
            public.mkdir()
            (support / 'HermesFleet').symlink_to(public, target_is_directory=True)
            result = subprocess.run([sys.executable,str(LAUNCHER),'--prepare-only'],
                env={**os.environ,'HOME':home},capture_output=True,text=True)
            self.assertNotEqual(result.returncode,0,'private page may not be created through a symlink')
            self.assertFalse(list(public.rglob('index.html')))

if __name__ == '__main__': unittest.main()
