"""The MCP store: a token store for the MCP Python SDK's OAuth client provider.

NEW, for the token service. The SDK takes as its store any object with four
async methods, and this is one. It hands the SDK the current access token and
never a refresh token, so the SDK has nothing to refresh with and cannot race
the service. Every write the SDK would make is refused with one sentence, and
so is the redirect a new authorization would need, so a session on a claw can
never start an authorization of its own.

    from mcp.client.auth import OAuthClientProvider
    from commonclaw_connection.mcp_storage import TokenStore
    store = TokenStore("provider/account")
    auth = OAuthClientProvider(server_url=..., client_metadata=...,
                               storage=store,
                               redirect_handler=store.redirect_handler,
                               callback_handler=store.callback_handler)

WHAT THE SDK DOES WITH IT, read in the SDK's source. The provider reads its
store once, at its first request, and keeps the token in memory after that.
When that token has expired it sends the request without one, and the 401 that
comes back starts a full authorization, which reaches the refusals below. So
this store serves a client that lives within one access token's life. A
long-lived client passes `http_auth.token_auth(row, http_module=httpx2)` as its
transport's auth instead, because that hook asks the service before every
request.

The SDK's types are imported when a method runs, so this module loads in an
environment without the SDK.
"""

import time

from .tokens_client import TokensClient


def refusal(row):
    return ("this claw's token service refreshes %s, so a session never stores a token or a "
            "client for it. A new approval goes through the seed door: token status %s names "
            "its path" % (row, row))


class TokenStore:
    def __init__(self, row, client=None):
        self.row = row
        self.client = client or TokensClient()

    async def get_tokens(self):
        from mcp.shared.auth import OAuthToken
        cred = self.client.get(self.row)
        if cred.get("kind") != "oauth":
            raise RuntimeError("%s holds a static key, and the MCP store serves an oauth row"
                               % self.row)
        left = None
        if cred.get("expires_at"):
            left = max(0, int(cred["expires_at"] - time.time()))
        return OAuthToken(access_token=cred["access_token"],
                          token_type=cred.get("token_type") or "Bearer",
                          expires_in=left)

    async def set_tokens(self, tokens):
        raise RuntimeError(refusal(self.row))

    async def get_client_info(self):
        from mcp.shared.auth import OAuthClientInformationFull
        client = dict(self.client.get(self.row).get("client") or {})
        client.pop("client_secret", None)
        if not client.get("client_id"):
            return None
        return OAuthClientInformationFull.model_validate(client)

    async def set_client_info(self, client_info):
        raise RuntimeError(refusal(self.row))

    async def redirect_handler(self, authorization_url):
        raise RuntimeError(refusal(self.row))

    async def callback_handler(self):
        raise RuntimeError(refusal(self.row))
