import importlib.util
import io
import json
import unittest
from contextlib import redirect_stdout
from http.cookiejar import Cookie
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

spec = importlib.util.spec_from_file_location("feed", Path(__file__).parents[1] / "scripts/feed.py")
feed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(feed)


def cookie(domain, name="sessionid"):
    return Cookie(0, name, "secret", None, False, domain, True, domain.startswith("."),
                  "/", True, True, None, True, None, None, {}, False)


class FeedTests(unittest.TestCase):
    def test_reel_response_nodes(self):
        data = {"items": [{"media": {"product_type": "clips", "code": "Ab_c-1"}},
                          {"media": {"product_type": "feed", "code": "Photo"}},
                          {"media": {"clips_metadata": {"id": 1}, "code": "Second"}}]}
        self.assertEqual(list(feed.reel_codes(data)), ["Ab_c-1", "Second"])

    def test_cookie_domains(self):
        result = feed.instagram_cookies([cookie(".instagram.com"), cookie("www.instagram.com"),
                                        cookie("evilinstagram.com"), cookie("instagram.com.example.org")])
        self.assertEqual([c["domain"] for c in result], [".instagram.com", "www.instagram.com"])

    def test_invalid_shortcode(self):
        self.assertEqual(list(feed.reel_codes({"product_type": "clips", "code": "../../bad"})), [])


class BrowserTests(unittest.IsolatedAsyncioTestCase):
    async def test_auto_uses_installed_chrome(self):
        launch = AsyncMock(return_value=object())
        browser = await feed.launch_browser(SimpleNamespace(chromium=SimpleNamespace(launch=launch)), "auto", False)
        self.assertIs(browser, launch.return_value)
        launch.assert_awaited_once_with(channel="chrome", headless=True)

    async def test_auto_falls_back_when_chrome_is_missing(self):
        chromium = object()
        launch = AsyncMock(side_effect=[RuntimeError("Chromium distribution 'chrome' is not found at /opt/google/chrome/chrome"), chromium])
        browser = await feed.launch_browser(SimpleNamespace(chromium=SimpleNamespace(launch=launch)), "auto", True)
        self.assertIs(browser, chromium)
        self.assertEqual([call.kwargs for call in launch.await_args_list], [
            {"channel": "chrome", "headless": False}, {"channel": None, "headless": False}])

    async def test_explicit_channels_do_not_fall_back(self):
        for channel in ("chrome", "", "msedge"):
            with self.subTest(channel=channel):
                launch = AsyncMock(side_effect=RuntimeError("Executable doesn't exist at /secret/path"))
                with self.assertRaisesRegex(feed.FeedError, "install-retrieval.sh") as caught:
                    await feed.launch_browser(SimpleNamespace(chromium=SimpleNamespace(launch=launch)), channel, False)
                self.assertNotIn("/secret/path", str(caught.exception))
                launch.assert_awaited_once_with(channel=channel or None, headless=True)

    async def test_neither_browser_is_installed(self):
        launch = AsyncMock(side_effect=RuntimeError("Executable doesn't exist"))
        with self.assertRaisesRegex(feed.FeedError, "Neither Google Chrome nor bundled Chromium"):
            await feed.launch_browser(SimpleNamespace(chromium=SimpleNamespace(launch=launch)), "auto", False)
        self.assertEqual(launch.await_count, 2)

    async def test_startup_failure_is_not_hidden_by_fallback(self):
        cases = [
            ("Host system is missing dependencies to run browsers", "install-deps chromium"),
            ("error while loading shared libraries: libX11.so", "install-deps chromium"),
            ("Missing X server or $DISPLAY", "feed_headless = true"),
            ("Target page, context or browser has been closed", "could not start"),
        ]
        for detail, expected in cases:
            with self.subTest(detail=detail):
                launch = AsyncMock(side_effect=RuntimeError(detail + " sessionid=SECRET"))
                with self.assertRaisesRegex(feed.FeedError, expected) as caught:
                    await feed.launch_browser(SimpleNamespace(chromium=SimpleNamespace(launch=launch)), "auto", True)
                self.assertNotIn("SECRET", str(caught.exception))
                self.assertEqual(launch.await_count, 1)

    async def test_navigation_errors_are_actionable_and_sanitized(self):
        cases = [
            ("net::ERR_PROXY_CONNECTION_FAILED at https://user:SECRET@example.org", "ERR_PROXY_CONNECTION_FAILED"),
            ("net::ERR_NAME_NOT_RESOLVED sessionid=SECRET", "ERR_NAME_NOT_RESOLVED"),
            ("Timeout 45000ms exceeded sessionid=SECRET", "45 seconds"),
            ("Browser closed sessionid=SECRET", "browser started but could not open"),
        ]
        for detail, expected in cases:
            with self.subTest(detail=detail):
                page = SimpleNamespace(goto=AsyncMock(side_effect=RuntimeError(detail)))
                with self.assertRaisesRegex(feed.FeedError, expected) as caught:
                    await feed.open_feed(page)
                self.assertNotIn("SECRET", str(caught.exception))

    async def test_login_redirects_fail_before_feed_is_ready(self):
        for path in ("accounts/login/", "challenge/", "checkpoint/"):
            with self.subTest(path=path):
                page = SimpleNamespace(url="https://www.instagram.com/" + path, goto=AsyncMock(return_value=None))
                with self.assertRaisesRegex(feed.FeedError, "configured cookie browser"):
                    await feed.open_feed(page)

    async def test_http_failures(self):
        for status, expected in ((401, "denied access"), (403, "denied access"), (429, "rate limited"), (503, "HTTP 503")):
            with self.subTest(status=status):
                page = SimpleNamespace(url="https://www.instagram.com/reels/", goto=AsyncMock(return_value=SimpleNamespace(status=status)))
                with self.assertRaisesRegex(feed.FeedError, expected):
                    await feed.open_feed(page)

    async def test_successful_navigation(self):
        page = SimpleNamespace(url="https://www.instagram.com/reels/", goto=AsyncMock(return_value=SimpleNamespace(status=200)))
        await feed.open_feed(page)
        page.goto.assert_awaited_once_with("https://www.instagram.com/reels/", wait_until="domcontentloaded", timeout=45000)

    async def test_main_reports_safe_errors_as_protocol_events(self):
        args = SimpleNamespace(browser="firefox", check_login=False)
        for error, expected in ((feed.FeedError("Bundled Chromium is missing"), "Bundled Chromium is missing"),
                                (RuntimeError("sessionid=SECRET"), "failed while reading")):
            with self.subTest(error=type(error).__name__):
                output = io.StringIO()
                with patch.object(feed, "load_cookies", return_value=[{"name": "sessionid", "value": "SECRET"}]), \
                        patch.object(feed, "browse", new=AsyncMock(side_effect=error)), redirect_stdout(output):
                    self.assertEqual(await feed.main(args), 1)
                event = json.loads(output.getvalue())
                self.assertEqual(event["type"], "error")
                self.assertIn(expected, event["message"])
                self.assertNotIn("SECRET", output.getvalue())


if __name__ == "__main__":
    unittest.main()
