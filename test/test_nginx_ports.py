import importlib.util
from pathlib import Path
import unittest

module_path = Path(__file__).resolve().parent.parent / "tools" / "change-nginx-port.py"
spec = importlib.util.spec_from_file_location("change_nginx_port", module_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class PortRewriteTests(unittest.TestCase):
    def test_new_nginx_site(self):
        initial = (
            "# Configured by WhatsApp Translator deploy.sh\n"
            "server { listen 80; location / { return 301 https://$host$request_uri; } }\n"
            "server {\n    listen 443 ssl;\n    client_max_body_size 32k;\n}\n"
        )
        output = module.updated_config(initial,443,8443)
        self.assertIn("listen 8443 ssl;",output)
        self.assertIn("https://$host:8443$request_uri;",output)
        self.assertIn("client_max_body_size 3m;",output)
        back = module.updated_config(output,8443,443)
        self.assertIn("https://$host$request_uri;",back)
        self.assertNotIn("8443",back)

    def test_existing_nginx_site_without_port80_redirect(self):
        initial = "# WhatsApp Translator: отдельный сайт\nserver {\n listen 443 ssl;\n client_max_body_size 32k;\n}"
        output = module.updated_config(initial,443,9443)
        self.assertIn("listen 9443 ssl;",output)
        self.assertIn("client_max_body_size 3m;",output)

    def test_refuse_other_users_nginx_config(self):
        with self.assertRaises(ValueError):
            module.updated_config("server { listen 443 ssl; }",443,9443)

if __name__ == "__main__":
    unittest.main()
