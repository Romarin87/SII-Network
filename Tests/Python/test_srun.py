import os
import re
import sys
import unittest
from pathlib import Path
from unittest import mock

REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPOSITORY_ROOT / "Tools"))

import sii_srun_autologin as srun


class CryptoTests(unittest.TestCase):
    def test_srun_info_matches_javascript_reference(self):
        actual = srun.srun_info(
            "testuser",
            "p@ssword",
            "192.0.2.8",  # RFC 5737 documentation-only address
            "1",
            "0123456789abcdef0123456789abcdef01234567",
        )
        expected = (
            "{SRBX1}1gJcmcpuaJdgjQ1+0oNQCmVxVQ8lSqKjcdKZIl7ghC1madiuHCkVvO09k7d1rmoJ"
            "KUhRcVpKj1+tIPDTLAYoaOMLmF20aQC9Is8e+aTtCyevZKEP1MyQoliIN7H/AVcr+DuoeS=="
        )
        self.assertEqual(actual, expected)

    def test_json_and_jsonp(self):
        self.assertEqual(srun._parse_json_or_jsonp('{"error":"ok"}')["error"], "ok")
        self.assertEqual(srun._parse_json_or_jsonp('cb({"error":"ok"});')["error"], "ok")


class WiredLinkTests(unittest.TestCase):
    def test_hardware_port_parsing_and_classification(self):
        ports = srun._hardware_port_map(
            """
Hardware Port: Thunderbolt Ethernet Slot 0
Device: en7
Ethernet Address: 02:00:00:00:00:01

Hardware Port: Wi-Fi
Device: en0
Ethernet Address: 02:00:00:00:00:02
"""
        )
        self.assertEqual(ports["en7"], "Thunderbolt Ethernet Slot 0")
        self.assertTrue(srun._is_wired_hardware_port(ports["en7"]))
        self.assertFalse(srun._is_wired_hardware_port(ports["en0"]))
        self.assertTrue(srun._is_wired_hardware_port("USB 10/100/1000 LAN"))
        self.assertFalse(srun._is_wired_hardware_port("Thunderbolt Bridge"))


class SecurityDefaultsTests(unittest.TestCase):
    def test_only_official_https_portal_is_allowed(self):
        self.assertEqual(
            srun.validate_base_url("https://auth.sii.edu.cn/"),
            "https://auth.sii.edu.cn",
        )
        for value in (
            "http://auth.sii.edu.cn",
            "https://auth.sii.edu.cn.example.com",
            "https://example.com",
            "https://auth.sii.edu.cn:444",
            "https://" + "user:placeholder@" + srun.ALLOWED_PORTAL_HOST,
        ):
            with self.subTest(value=value):
                with self.assertRaises(srun.SRunError):
                    srun.validate_base_url(value)

    def test_arbitrary_server_messages_are_not_returned_as_codes(self):
        response = {"error_msg": "untrusted free-form server text"}
        self.assertEqual(srun.safe_response_code(response, "unknown"), "unknown")

    def test_cross_origin_redirect_is_rejected(self):
        handler = srun.PortalRedirectHandler()
        request = srun.urllib.request.Request("https://auth.sii.edu.cn/cgi-bin/srun_portal")
        with self.assertRaises(srun.SRunError):
            handler.redirect_request(
                request,
                None,
                302,
                "Found",
                {},
                "https://example.com/capture",
            )

    def test_keychain_password_is_not_passed_in_process_arguments(self):
        completed = mock.Mock(returncode=0)
        with mock.patch.object(srun.sys, "platform", "darwin"), mock.patch.object(
            srun.subprocess,
            "run",
            return_value=completed,
        ) as run, mock.patch("builtins.print"):
            srun.keychain_store_interactive("testuser")

        command = run.call_args.args[0]
        self.assertEqual(command[-1], "-w")
        self.assertEqual(command.count("-w"), 1)
        self.assertNotIn("p@ssword", command)


class LiveReadOnlyTests(unittest.TestCase):
    @unittest.skipUnless(
        os.environ.get("SRUN_LIVE_TEST") == "1",
        "set SRUN_LIVE_TEST=1 to contact the configured campus portal",
    )
    def test_status_and_ip_discovery(self):
        client = srun.PortalClient(srun.Settings("protocol-test"))
        state = client.status()
        self.assertIsInstance(state.online, bool)
        self.assertRegex(client.discover_ip(), re.compile(r"^[0-9a-fA-F:.]+$"))


if __name__ == "__main__":
    unittest.main()
