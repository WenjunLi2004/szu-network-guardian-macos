from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import requests


MODULE_PATH = Path(__file__).resolve().parents[1] / "Sources" / "guardian.py"
MENU_SOURCE_PATH = MODULE_PATH.with_name("MenuBarApp.swift")
SPEC = importlib.util.spec_from_file_location("szu_guardian", MODULE_PATH)
assert SPEC and SPEC.loader
guardian = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(guardian)


class Response:
    def __init__(self, text: str, status_code: int = 200, url: str = "https://example.invalid/") -> None:
        self.text = text
        self.status_code = status_code
        self.url = url

    def raise_for_status(self) -> None:
        if self.status_code >= 400:
            raise requests.HTTPError("synthetic failure")


class Session:
    def __init__(self, responses: list[Response] | None = None) -> None:
        self.responses = list(responses or [])
        self.calls: list[tuple[str, dict[str, object]]] = []

    def get(self, url: str, **kwargs: object) -> Response:
        self.calls.append((url, kwargs))
        if not self.responses:
            raise AssertionError("unexpected request")
        return self.responses.pop(0)


class GuardianTests(unittest.TestCase):
    def test_menu_refresh_preserves_unsaved_settings_draft(self) -> None:
        source = MENU_SOURCE_PATH.read_text(encoding="utf-8")
        self.assertIn("guard !settingsDirty else { return }", source)
        self.assertIn('Button(model.settingsDirty ? "保存*" : "保存")', source)

    def test_connectivity_check_uses_https_backup(self) -> None:
        session = Session([
            Response("not a captive success page", url="https://captive.apple.com/hotspot-detect.html"),
            Response("", url="https://www.baidu.com/favicon.ico"),
        ])
        self.assertTrue(guardian.is_online(session, "https://captive.apple.com/hotspot-detect.html"))
        self.assertEqual([call[0] for call in session.calls], [
            "https://captive.apple.com/hotspot-detect.html",
            "https://www.baidu.com/favicon.ico",
        ])
        self.assertTrue(all(call[1]["verify"] for call in session.calls))

    def test_connectivity_backup_rejects_captive_redirect(self) -> None:
        session = Session([
            Response("login", url="https://captive.apple.com/hotspot-detect.html"),
            Response("login", url="http://captive.portal/login"),
        ])
        self.assertFalse(guardian.is_online(session, "https://captive.apple.com/hotspot-detect.html"))

    def test_srun_requests_require_tls_verification(self) -> None:
        session = Session([Response('cb({"error":"ok"})')])
        guardian.jsonp_get(session, "/cgi-bin/get_challenge", {"username": "test-user"})
        _url, options = session.calls[0]
        self.assertTrue(options["verify"])

    def test_dormitory_json_and_jsonp_are_supported(self) -> None:
        self.assertEqual(guardian.parse_dormitory_response('{"result":"1"}')["result"], "1")
        self.assertEqual(guardian.parse_dormitory_response('cb({"result":1});')["result"], 1)

    def test_dormitory_login_disables_redirects(self) -> None:
        session = Session([Response('callback({"result":"1","msg":"success"})')])
        self.assertTrue(guardian.login_dormitory(session, "test-user", "test-secret"))
        url, options = session.calls[0]
        self.assertEqual(url, guardian.DORMITORY_LOGIN_URL)
        self.assertFalse(options["allow_redirects"])
        self.assertEqual(options["params"], {"user_account": "test-user", "user_password": "test-secret"})

    def test_dormitory_already_online_is_success(self) -> None:
        session = Session([Response('callback({"result":0,"ret_code":2,"msg":"IP: 172.24.0.2 已经在线！"})')])
        self.assertTrue(guardian.login_dormitory(session, "test-user", "test-secret"))

    def test_dormitory_failure_message_is_not_success(self) -> None:
        session = Session([Response('callback({"result":0,"ret_code":1,"msg":"认证失败"})')])
        self.assertFalse(guardian.login_dormitory(session, "test-user", "test-secret"))

    def test_dormitory_reachability_probe_has_no_credentials(self) -> None:
        session = Session([Response("{}")])
        self.assertTrue(guardian.dormitory_portal_reachable(session))
        _url, options = session.calls[0]
        self.assertNotIn("params", options)
        self.assertFalse(options["allow_redirects"])

    def test_dormitory_exception_is_replaced_with_safe_message(self) -> None:
        session = mock.Mock()
        session.get.side_effect = requests.ConnectionError(
            "http://portal.invalid/?user_account=test-user&user_password=test-secret"
        )
        with self.assertRaisesRegex(RuntimeError, "^dormitory request failed$") as raised:
            guardian.login_dormitory(session, "test-user", "test-secret")
        rendered = str(raised.exception)
        self.assertNotIn("test-user", rendered)
        self.assertNotIn("test-secret", rendered)
        self.assertNotIn("http://", rendered)

    @mock.patch.object(guardian.LOG, "write")
    @mock.patch.object(guardian, "login_dormitory")
    @mock.patch.object(guardian, "dormitory_portal_reachable")
    @mock.patch.object(guardian, "login_srun")
    def test_auto_prefers_teaching_and_does_not_probe_dormitory(
        self, login_srun: mock.Mock, reachable: mock.Mock, login_dormitory: mock.Mock, _log: mock.Mock
    ) -> None:
        login_srun.return_value = True
        success, method = guardian.authenticate_zone(mock.Mock(), "auto", "user", "secret")
        self.assertTrue(success)
        self.assertEqual(method, "teaching-office")
        reachable.assert_not_called()
        login_dormitory.assert_not_called()

    @mock.patch.object(guardian.LOG, "write")
    @mock.patch.object(guardian, "login_dormitory", return_value=True)
    @mock.patch.object(guardian, "dormitory_portal_reachable", return_value=True)
    @mock.patch.object(guardian, "login_srun", return_value=False)
    def test_auto_falls_back_only_after_private_portal_probe(
        self, _srun: mock.Mock, reachable: mock.Mock, dormitory: mock.Mock, _log: mock.Mock
    ) -> None:
        success, method = guardian.authenticate_zone(mock.Mock(), "auto", "user", "secret")
        self.assertTrue(success)
        self.assertEqual(method, "dormitory")
        reachable.assert_called_once()
        dormitory.assert_called_once()

    @mock.patch.object(guardian.LOG, "write")
    @mock.patch.object(guardian, "login_dormitory")
    @mock.patch.object(guardian, "dormitory_portal_reachable", return_value=False)
    @mock.patch.object(guardian, "login_srun", return_value=False)
    def test_auto_never_sends_dormitory_credentials_when_portal_is_absent(
        self, _srun: mock.Mock, _reachable: mock.Mock, dormitory: mock.Mock, _log: mock.Mock
    ) -> None:
        success, method = guardian.authenticate_zone(mock.Mock(), "auto", "user", "secret")
        self.assertFalse(success)
        self.assertEqual(method, "none")
        dormitory.assert_not_called()

    def test_config_accepts_supported_zones_and_rejects_unknown_zone(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            with mock.patch.object(guardian, "CONFIG_PATH", path):
                for zone in guardian.VALID_ZONES:
                    path.write_text(json.dumps({
                        "network_zone": zone,
                        "check_interval_seconds": 300,
                        "connectivity_probe": "https://captive.apple.com/hotspot-detect.html",
                    }))
                    self.assertEqual(guardian.read_config()["network_zone"], zone)
                path.write_text(json.dumps({
                    "network_zone": "unknown",
                    "check_interval_seconds": 300,
                    "connectivity_probe": "https://captive.apple.com/hotspot-detect.html",
                }))
                with self.assertRaisesRegex(RuntimeError, "unsupported network zone"):
                    guardian.read_config()

                path.write_text(json.dumps({
                    "network_zone": "teaching_office",
                    "check_interval_seconds": 86400,
                    "connectivity_probe": "https://captive.apple.com/hotspot-detect.html",
                }))
                self.assertEqual(guardian.read_config()["check_interval_seconds"], 86400)

    @mock.patch.object(guardian, "authenticate_zone")
    @mock.patch.object(guardian, "read_keychain")
    @mock.patch.object(guardian, "is_online", return_value=True)
    @mock.patch.object(guardian, "direct_session")
    @mock.patch.object(guardian, "read_config", return_value={
        "network_zone": "auto",
        "check_interval_seconds": 300,
        "connectivity_probe": "https://captive.apple.com/hotspot-detect.html",
    })
    def test_online_check_never_reads_credentials_or_authenticates(
        self,
        _config: mock.Mock,
        _session: mock.Mock,
        _online: mock.Mock,
        read_keychain: mock.Mock,
        authenticate: mock.Mock,
    ) -> None:
        self.assertTrue(guardian.run_check())
        read_keychain.assert_not_called()
        authenticate.assert_not_called()


if __name__ == "__main__":
    unittest.main()
