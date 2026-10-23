import importlib.util
import pathlib
import unittest

SOURCE = pathlib.Path(__file__).resolve().parents[1] / "tools" / "change-nginx-port.py"
SPEC = importlib.util.spec_from_file_location("wa_port_change", SOURCE)
mod = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(mod)

SAMPLE = """# Configured by WhatsApp Translator deploy.sh
server {
    listen 80;
    server_name chat.example.test;
    location / { return 301 https://$host$request_uri; }
}
server {
    listen 443 ssl;
    server_name chat.example.test;
    ssl_certificate /etc/letsencrypt/live/chat.example.test/fullchain.pem;
    client_max_body_size 32k;
    location / { proxy_pass http://127.0.0.1:6060; }
}
"""

class NginxPortTests(unittest.TestCase):
    def test_port_443_to_7000(self):
        actual = mod.updated_config(SAMPLE, 443, 7000)
        self.assertIn("listen 7000 ssl;", actual)
        self.assertIn("return 301 https://$host:7000$request_uri;", actual)
        self.assertIn("client_max_body_size 3m;", actual)
        self.assertIn("127.0.0.1:6060", actual)
        self.assertNotIn("listen 443 ssl;", actual)
    def test_restore_default_port(self):
        adjusted = mod.updated_config(SAMPLE, 443, 7000)
        reverted = mod.updated_config(adjusted, 7000, 443)
        self.assertIn("return 301 https://$host$request_uri;", reverted)
        self.assertIn("listen 443 ssl;", reverted)
    def test_no_port_change_increases_vcard_limit(self):
        adjusted = mod.updated_config(SAMPLE, 443, 443)
        self.assertIn("client_max_body_size 3m;", adjusted)
    def test_unrelated_host_cannot_be_rewritten(self):
        with self.assertRaises(ValueError):
            mod.updated_config(SAMPLE.replace("Configured by WhatsApp Translator deploy.sh", "other app"), 443, 7000)
    def test_wrong_initial_port_refused(self):
        with self.assertRaises(ValueError):
            mod.updated_config(SAMPLE, 8443, 7000)

if __name__ == "__main__":
    unittest.main()
