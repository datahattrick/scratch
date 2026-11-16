"""Log into Coder via Keycloak OIDC like a browser would; print the session token.

Usage: python3 -I oidc-login.py <coder-url> <username>   (password on stdin)
"""
import html, http.cookiejar, re, sys, urllib.parse, urllib.request

coder, user = sys.argv[1].rstrip("/"), sys.argv[2]
password = sys.stdin.readline().strip()

jar = http.cookiejar.CookieJar()
opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))

# 1. Coder -> Keycloak login page (redirects followed automatically).
page = opener.open(f"{coder}/api/v2/users/oidc/callback").read().decode()
m = re.search(r'<form[^>]*id="kc-form-login"[^>]*action="([^"]+)"', page)
if not m:
    sys.exit("could not find Keycloak login form")
action = html.unescape(m.group(1))

# 2. Submit credentials -> Keycloak -> Coder callback, which sets the session cookie.
data = urllib.parse.urlencode({"username": user, "password": password, "credentialId": ""}).encode()
opener.open(action, data)

token = next((c.value for c in jar if c.name == "coder_session_token"), None)
if not token:
    sys.exit("login failed: no coder_session_token cookie")
print(token)
