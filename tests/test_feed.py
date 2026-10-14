import importlib.util
import unittest
from http.cookiejar import Cookie
from pathlib import Path

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


if __name__ == "__main__":
    unittest.main()
