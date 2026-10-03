"""Explicit read-only check of a saved browser profile; never output identity or credentials.

Run manually, not as part of test discovery. A freshly opened test window is closed
afterward unless --keep-open is set; an already open provider window must be checked
through the app instead.
"""
import argparse
from pathlib import Path
import re
import sys
import time
from urllib.parse import urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from browser_sessions import BrowserSessions
from providers import PROVIDERS
from storage import SettingsStore


def run():
    parser = argparse.ArgumentParser()
    parser.add_argument('provider', choices=['chatgpt', 'claude'])
    parser.add_argument('--save-if-verified', action='store_true')
    parser.add_argument('--keep-open', action='store_true', help='Leave a verified native window open so the app can reattach.')
    args = parser.parse_args()
    browsers = BrowserSessions()
    pid = args.provider
    if browsers._endpoint(browsers.profile_root / pid):
        print('Provider window already open; use the app to verify it.')
        return
    result = None
    try:
        browsers.open_login(pid)
        deadline = time.monotonic() + 25
        while True:
            result = browsers.check(pid, login_poll=True)
            if result.authenticated or result.status == 'closed' or time.monotonic() >= deadline:
                break
            time.sleep(.5)
        print('Stored browser connection:', pid, result.status, 'verified' if result.authenticated else 'not verified')
        session = browsers.sessions.get(pid)
        if session and session.browser.is_connected():
            print('Native webdriver flag:', session.page.evaluate('navigator.webdriver'))
        if result.authenticated and args.save_if_verified:
            store = SettingsStore()
            store.data['providers'][pid]['connected'] = True
            store.save()
            print('Verified connection flag saved.')
        elif not result.authenticated and session and session.browser.is_connected():
            cookies = session.context.cookies()
            print('Saved session cookie present:', any(c.get('value') and any(c.get('name', '') == name or c.get('name', '').startswith(name + '.') for name in PROVIDERS[pid].session_cookies) for c in cookies))
            for page in session.context.pages[:5]:
                print('Page load:', {'host': urlsplit(page.url).hostname, 'ready': page.evaluate('document.readyState'),
                                     'network_error': page.locator('#main-frame-error').count() > 0,
                                     'body_elements': page.locator('body > *').count()})
                body_text = page.locator('body').inner_text()
                categories = {'upstream': r'upstream|gateway|proxy', 'server_error': r'internal server error|service unavailable|request timeout',
                              'security_check': r'cloudflare|verify.*human|just a moment|access denied',
                              'javascript': r'javascript|cookies', 'network_policy': r'network access|not allowed|blocked|forbidden',
                              'rate_limit': r'too many requests|rate limit'}
                print('Error-page categories:', [name for name, pattern in categories.items() if re.search(pattern, body_text + ' ' + page.title(), re.I)])
                print('Body shape:', page.locator('body > *').evaluate_all('(items) => items.map(i => i.tagName)'), 'text length:', len(body_text))
                if page.locator('#main-frame-error').count():
                    print('Network error code:', re.findall(r'ERR_[A-Z_]+', page.locator('#main-frame-error').inner_text())[:1])
                print('Visible account selectors:', [s for s in PROVIDERS[pid].account_selectors if page.locator(s).first.is_visible()])
                evidence = session.evidence.get(page)
                print('Observed identity:', evidence.authenticated if evidence else None)
                names = page.locator('[data-testid]').evaluate_all('(items) => items.map(i => i.getAttribute("data-testid"))')
                print('UI test IDs:', sorted({n for n in names if re.fullmatch(r'[A-Za-z_-]{1,70}', n or '')})[:40])
    finally:
        if args.keep_open and result is not None and result.authenticated:
            for session in browsers.sessions.values():
                session.browser.close()  # CDP reader disconnect; the native window stays open.
            browsers.sessions.clear()
            if browsers.playwright:
                browsers.playwright.stop()
        else:
            browsers.shutdown()


if __name__ == '__main__':
    run()
