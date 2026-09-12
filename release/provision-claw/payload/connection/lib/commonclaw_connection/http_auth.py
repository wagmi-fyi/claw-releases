"""The REST hook: an httpx auth for a session that calls a provider's HTTP API directly.

NEW, for the token service. Before each request it asks the service for the
current credential and sets it on the request. When the provider answers 401,
it reports the refused token with `rejected`, takes the answer, and retries
once. A static key has nothing to refresh, so its 401 is not reported. A second 401 is returned to the caller as it stands, so a
credential the provider will not take never becomes a loop.

    import httpx
    from commonclaw_connection.http_auth import token_auth
    client = httpx.Client(auth=token_auth("provider/account"))

THE HTTP LIBRARY IS THE CALLER'S. This module imports none at load. `token_auth`
builds the hook on `httpx` when it is importable and on `httpx2` otherwise,
and a caller names one with `http_module=`. The MCP Python SDK builds its
transports on `httpx2`, so a long-lived MCP client passes this hook as its
transport's auth: the SDK's own OAuth provider reads its token store once, at
its first request, and this hook asks before every request.

A static key goes in the Authorization header as a bearer by default. A
provider that wants it elsewhere is named with `header=` and `scheme=`.
"""

from .tokens_client import TokensClient

_CLASSES = {}


def _http_module(http_module=None):
    if http_module is not None:
        return http_module
    try:
        import httpx
        return httpx
    except ImportError:
        pass
    try:
        import httpx2
        return httpx2
    except ImportError:
        raise ImportError("the REST hook is an httpx auth, and neither httpx nor httpx2 is "
                          "installed in this environment")


def auth_class(http_module=None):
    """The hook's class, built once on the given library's Auth."""
    mod = _http_module(http_module)
    if mod in _CLASSES:
        return _CLASSES[mod]

    class TokenAuth(mod.Auth):
        requires_request_body = False
        requires_response_body = False

        def __init__(self, row, client=None, header="Authorization", scheme=None):
            self.row = row
            self.client = client or TokensClient()
            self.header = header
            self.scheme = scheme

        def _apply(self, request, cred):
            value = cred.get("access_token") if cred.get("kind") == "oauth" else cred.get("key")
            scheme = self.scheme
            if scheme is None:
                scheme = cred.get("token_type") or "Bearer"
                if scheme.lower() == "bearer":
                    scheme = "Bearer"
            request.headers[self.header] = ("%s %s" % (scheme, value)) if scheme else value
            return cred.get("fingerprint", "")

        def auth_flow(self, request):
            # A STATIC KEY HAS NOTHING TO REFRESH, so its 401 goes back to the
            # caller as it stands. Only an oauth credential is reported.
            cred = self.client.get(self.row)
            told = self._apply(request, cred)
            response = yield request
            if response.status_code == 401 and told and cred.get("kind") == "oauth":
                self._apply(request, self.client.rejected(self.row, told))
                yield request

    TokenAuth.__qualname__ = "TokenAuth"
    _CLASSES[mod] = TokenAuth
    return TokenAuth


def token_auth(row, client=None, header="Authorization", scheme=None, http_module=None):
    """The hook for one row, ready to pass as `auth=`."""
    return auth_class(http_module)(row, client=client, header=header, scheme=scheme)
