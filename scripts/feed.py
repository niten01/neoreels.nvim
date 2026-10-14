#!/usr/bin/env python3
"""Demand-driven Reels discovery through an isolated, cookie-authenticated browser.

Only Reel URLs and generic errors cross stdout. No cookies or response bodies
are persisted. The browser follows Instagram's own web requests; there are no
hardcoded private API calls.
"""
import argparse
import asyncio
import json
import signal
import sys
from collections import deque
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
        browser = await playwright.chromium.launch(channel=args.channel or None, headless=not args.visible)
        try:
            context = await browser.new_context(viewport={"width": 1100, "height": 900}, locale="en-US")
            await context.add_cookies(cookies)
            page = await context.new_page()

            def response_received(response):
                task = asyncio.create_task(capture(response))
                tasks.add(task)
                task.add_done_callback(tasks.discard)

            page.on("response", response_received)
            await page.goto("https://www.instagram.com/reels/", wait_until="domcontentloaded", timeout=45000)
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
                    if any(fragment in page.url for fragment in ("/accounts/login", "/challenge/", "/checkpoint/")):
                        emit("error", message="Instagram requires login or a challenge. Open Firefox, resolve it, then restart :NeoReelsPlay.")
                        break
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
            await browser.close()


async def main(args):
    try:
        cookies = load_cookies(args.browser)
    except (Exception, SystemExit):
        emit("error", message="Unable to read browser cookies. Check browser/profile selection and log into Instagram.")
        return 1
    authenticated = any(c["name"] == "sessionid" for c in cookies)
    if args.check_login:
        emit("login", authenticated=authenticated)
        return 0 if authenticated else 1
    if not authenticated:
        emit("error", message="No Instagram login found in this browser profile. Log into Instagram in Firefox, then use :NeoReelsPlay.")
        return 1
    try:
        await browse(args, cookies)
    except ModuleNotFoundError:
        emit("error", message="Feed dependencies are missing. Run sh scripts/install-retrieval.sh.")
        return 1
    except asyncio.CancelledError:
        pass
    except Exception:
        emit("error", message="Feed browser could not load Instagram. Check network access, browser installation, and Instagram login.")
        return 1
    return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--browser", default="firefox")
    parser.add_argument("--channel", default="chrome")
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
