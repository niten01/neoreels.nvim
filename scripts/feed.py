#!/usr/bin/env python3
"""Demand-driven Reels discovery through an isolated, cookie-authenticated browser.

Only Reel URLs and sanitized errors cross stdout. No cookies or response bodies
are persisted. The browser follows Instagram's own web requests; there are no
hardcoded private API calls.
"""
import argparse
import asyncio
import json
import re
import signal
import sys
from collections import deque
from contextlib import suppress
from urllib.parse import urlsplit


def emit(kind, **fields):
    print(json.dumps({"type": kind, **fields}), flush=True)


def reel_codes(value):
    if isinstance(value, dict):
        code = value.get("code") or value.get("shortcode")
        is_reel = value.get("product_type") == "clips" or bool(value.get("clips_metadata"))
        if isinstance(code, str) and is_reel and all(c.isascii() and (c.isalnum() or c in "_-") for c in code):
            yield code
        for child in value.values():
            yield from reel_codes(child)
    elif isinstance(value, list):
        for child in value:
            yield from reel_codes(child)


def instagram_cookies(jar):
    result = []
    for cookie in jar:
        domain = cookie.domain.lstrip(".").lower()
        if domain != "instagram.com" and not domain.endswith(".instagram.com"):
            continue
        if cookie.is_expired():
            continue
        item = {"name": cookie.name, "value": cookie.value, "domain": cookie.domain,
                "path": cookie.path or "/", "secure": bool(cookie.secure),
                "httpOnly": cookie.has_nonstandard_attr("HttpOnly")}
        if cookie.expires is not None:
            item["expires"] = cookie.expires
        result.append(item)
    return result


class QuietLogger:
    def debug(self, *_args, **_kwargs): pass
    def info(self, *_args, **_kwargs): pass
    def warning(self, *_args, **_kwargs): pass
    def error(self, *_args, **_kwargs): pass


def load_cookies(browser):
    from yt_dlp import YoutubeDL, parse_options
    # Let yt-dlp parse its complete browser[:profile][::container] syntax.
    options = parse_options(["--cookies-from-browser", browser]).ydl_opts
    options.update({"quiet": True, "logger": QuietLogger()})
    with YoutubeDL(options) as ydl:
        return instagram_cookies(ydl.cookiejar)


class FeedError(Exception):
    """An actionable message safe to show without browser logs or cookie values."""


def missing_browser(error):
    message = str(error).lower()
    return "executable doesn't exist" in message or ("distribution" in message and "is not found" in message)


async def launch_browser(playwright, channel, visible):
    channels = ["chrome", None] if channel == "auto" else [channel or None]
    for index, candidate in enumerate(channels):
        try:
            return await playwright.chromium.launch(channel=candidate, headless=not visible)
        except Exception as error:
            if missing_browser(error):
                if index + 1 < len(channels):
                    continue
                if channel == "auto":
                    raise FeedError("Neither Google Chrome nor bundled Chromium is installed. Run sh scripts/install-retrieval.sh to install Chromium.") from None
                if not candidate:
                    raise FeedError("Bundled Chromium is missing or outdated. Run sh scripts/install-retrieval.sh to install the matching browser.") from None
                raise FeedError("The configured feed browser is not installed. Set feed_channel = 'auto' and run sh scripts/install-retrieval.sh, or install the selected browser.") from None
            message = str(error).lower()
            if "host system is missing dependencies" in message or "error while loading shared libraries" in message:
                raise FeedError("Feed browser system libraries are missing. Run the configured Python with -m playwright install-deps chromium.") from None
            if "missing x server" in message or "without having a xserver" in message:
                raise FeedError("The visible feed browser requires a graphical display. Set feed_headless = true or start Neovim in a desktop session.") from None
            raise FeedError("Feed browser could not start. Check its installation and system dependencies, or rerun sh scripts/install-retrieval.sh.") from None


def check_login_url(page):
    if any(fragment in urlsplit(page.url).path for fragment in ("/accounts/login", "/challenge/", "/checkpoint/")):
        raise FeedError("Instagram requires login or a challenge. Open the configured cookie browser, resolve it, then restart :NeoReelsPlay.")


async def open_feed(page):
    try:
        response = await page.goto("https://www.instagram.com/reels/", wait_until="domcontentloaded", timeout=45000)
    except Exception as error:
        # Extract only a browser network code; raw errors may contain cookies,
        # URLs with tokens, proxy credentials, or browser process diagnostics.
        code = re.search(r"\bnet::(ERR_[A-Z0-9_]+)\b", str(error))
        if code:
            raise FeedError("Instagram navigation failed (" + code[1] + "). Check network/VPN/proxy access for the feed browser; Firefox-only proxy settings are not inherited.") from None
        if type(error).__name__ == "TimeoutError" or "timeout" in str(error).lower():
            raise FeedError("Instagram did not load within 45 seconds. Check network/VPN/proxy access for the feed browser.") from None
        raise FeedError("The feed browser started but could not open Instagram. Set feed_headless = false to inspect the page and check network access.") from None
    check_login_url(page)
    if response is not None and response.status >= 400:
        if response.status in (401, 403):
            raise FeedError("Instagram denied access (HTTP " + str(response.status) + "). Check the session in your configured cookie browser and try feed_headless = false to inspect the feed browser.")
        if response.status == 429:
            raise FeedError("Instagram rate limited the feed (HTTP 429). Wait before restarting :NeoReelsPlay.")
        raise FeedError("Instagram returned HTTP " + str(response.status) + ". Try again later and check network access.")


async def browse(args, cookies):
    from playwright.async_api import async_playwright
    pending, seen = deque(), set()
    tasks = set()

    def add(code):
        if code and code not in seen and len(seen) < 5000:
            seen.add(code)
            pending.append("https://www.instagram.com/reel/" + code + "/")

    async def capture(response):
        parts = urlsplit(response.url)
        if parts.hostname not in {"www.instagram.com", "instagram.com", "i.instagram.com"}:
            return
        if "json" not in response.headers.get("content-type", ""):
            return
        try:
            data = await response.json()
            for code in reel_codes(data):
                add(code)
        except Exception:
            pass

    async with async_playwright() as playwright:
        browser = await launch_browser(playwright, args.channel, args.visible)
        try:
            context = await browser.new_context(viewport={"width": 1100, "height": 900}, locale="en-US")
            await context.add_cookies(cookies)
            page = await context.new_page()

            def response_received(response):
                task = asyncio.create_task(capture(response))
                tasks.add(task)
                task.add_done_callback(tasks.discard)

            page.on("response", response_received)
            await open_feed(page)
            emit("ready")
            while True:
                line = await asyncio.to_thread(sys.stdin.readline)
                if not line:
                    break
                try:
                    count = max(1, min(10, int(json.loads(line).get("count", 3))))
                except (ValueError, TypeError, json.JSONDecodeError):
                    emit("error", message="Invalid feed request")
                    continue
                delivered, attempts = 0, 0
                while delivered < count and attempts < 12:
                    check_login_url(page)
                    while pending and delivered < count:
                        emit("reel", url=pending.popleft())
                        delivered += 1
                    if delivered >= count:
                        break
                    # DOM links and the active URL are a fallback when response
                    # metadata changes. Only collect links in the Reels viewport.
                    links = await page.locator('main a[href*="/reel/"]').evaluate_all(
                        "els => els.filter(e => {const r=e.getBoundingClientRect(); return r.width>0 && r.height>0 && r.bottom>0 && r.top<innerHeight}).map(e=>e.href)"
                    )
                    for url in [page.url, *links]:
                        path = urlsplit(url).path.strip("/").split("/")
                        if len(path) == 2 and path[0] in {"reel", "reels"}:
                            add(path[1])
                    if pending:
                        continue
                    await page.mouse.move(700, 450)
                    await page.mouse.wheel(0, 850)
                    await page.wait_for_timeout(1200)
                    attempts += 1
                else:
                    emit("error", message="No new Reel URLs found. Instagram may be unavailable or its feed layout changed.")
                emit("batch_end", count=delivered)
        finally:
            for task in tasks:
                task.cancel()
            with suppress(Exception):
                await browser.close()


async def main(args):
    try:
        cookies = load_cookies(args.browser)
    except ModuleNotFoundError:
        emit("error", message="Cookie dependencies are missing. Run sh scripts/install-retrieval.sh.")
        return 1
    except (Exception, SystemExit):
        emit("error", message="Unable to read browser cookies. Check browser/profile selection and log into Instagram.")
        return 1
    authenticated = any(c["name"] == "sessionid" for c in cookies)
    if args.check_login:
        emit("login", authenticated=authenticated)
        return 0 if authenticated else 1
    if not authenticated:
        emit("error", message="No Instagram login found in this browser profile. Log into Instagram in the configured cookie browser, then use :NeoReelsPlay.")
        return 1
    try:
        await browse(args, cookies)
    except ModuleNotFoundError:
        emit("error", message="Feed dependencies are missing. Run sh scripts/install-retrieval.sh.")
        return 1
    except asyncio.CancelledError:
        pass
    except FeedError as error:
        emit("error", message=str(error))
        return 1
    except Exception:
        emit("error", message="Feed browser failed while reading Instagram's feed. Set feed_headless = false to inspect the browser, then restart :NeoReelsPlay.")
        return 1
    return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--browser", default="firefox")
    parser.add_argument("--channel", default="auto")
    parser.add_argument("--visible", action="store_true")
    parser.add_argument("--check-login", action="store_true")
    args = parser.parse_args()
    async def run_with_signals():
        task = asyncio.create_task(main(args))
        asyncio.get_running_loop().add_signal_handler(signal.SIGTERM, task.cancel)
        return await task

    try:
        raise SystemExit(asyncio.run(run_with_signals()))
    except KeyboardInterrupt:
        pass
