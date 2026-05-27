import importlib.machinery
import importlib.util
import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(rel):
    return (ROOT / rel).read_text(encoding="utf-8")


def load_python_script(rel):
    path = ROOT / rel
    loader = importlib.machinery.SourceFileLoader(path.stem, str(path))
    spec = importlib.util.spec_from_loader(path.stem, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class MihomoContractsTest(unittest.TestCase):
    def test_service_status_does_not_treat_not_running_as_running(self):
        src = read("src/opnsense/mvc/app/controllers/OPNsense/Mihomo/Api/ServiceController.php")
        self.assertNotIn("stripos($out, ' running')", src)
        self.assertRegex(src, r"not running|pid file exists|wrapper is running")

    def test_core_update_prefers_generic_freebsd_amd64_asset(self):
        mod = load_python_script("src/opnsense/scripts/mihomo/update_core.sh")
        release = {
            "tag_name": "v1.19.25",
            "assets": [
                {"name": "mihomo-freebsd-amd64-compatible-v1.19.25.gz", "url": "compat"},
                {"name": "mihomo-freebsd-amd64-v1-v1.19.25.gz", "url": "v1"},
                {"name": "mihomo-freebsd-amd64-v1.19.25.gz", "url": "generic"},
                {"name": "mihomo-freebsd-amd64-v2-v1.19.25.gz", "url": "v2"},
                {"name": "mihomo-freebsd-amd64-v3-v1.19.25.gz", "url": "v3"},
            ],
        }
        self.assertEqual(mod.pick_asset(release)[0], "generic")

    def test_php_writable_mihomo_paths_keep_group_write(self):
        install = read("install.sh")
        trait = read("src/opnsense/mvc/app/controllers/OPNsense/Mihomo/Api/MihomoFileTrait.php")
        self.assertIn('chmod 770 "$CONF_DIR/mihomo/profiles"', install)
        self.assertIn('chmod 770 "$CONF_DIR/mihomo/backups"', install)
        self.assertIn('chmod 660 "$CONF_DIR/mihomo/base.yaml"', install)
        self.assertIn('chmod 660 "$CONF_DIR/mihomo/override.yaml"', install)
        self.assertIn("@chmod($file, 0660)", trait)
        self.assertIn("@chmod($tmp, 0660)", trait)

    def test_language_catalog_is_merged_into_opnsense_domain_and_php_reloaded(self):
        install = read("install.sh")
        self.assertIn("OPNsense.mo", install)
        self.assertRegex(install, r"msgunfmt|msgcat|msgfmt")
        self.assertRegex(install, r"php-fpm|php_fpm|webgui")

    def test_full_help_toggle_is_deduped_by_container_not_checkbox_only(self):
        view = read("src/opnsense/mvc/app/views/OPNsense/Mihomo/configuration.volt")
        self.assertIn("dedupeFullHelpToggles", view)
        self.assertRegex(view, r"closest\([^)]*(checkbox|form-group|act_toggle_full_help)")
        self.assertNotIn("parent('label')", view)


if __name__ == "__main__":
    unittest.main()
