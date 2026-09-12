"""commonclaw_connection -- the shared code every connection service imports.

A connection service holds a credential for the whole firm and hands a calling
session what it needs, never more. The parts that have to be right the same
way in every such service live here, once: where a setting comes from, the
socket door and who is calling it, the audit log, the health line, the sealed
store, and the read of the claw's machine vault.

HOW A SERVICE FINDS THIS PACKAGE. The installer lays it under
/opt/commonclaw/lib/python, and the unit it renders sets PYTHONPATH to that
directory and COMMONCLAW_CONN_NAME to the connection's name. A program writes
`import commonclaw_connection` and names no path of its own. The installer
reads the health line with the same two variables, so the program answers the
same way under its unit and under provisioning.

Each module names the gatekeeper function it was lifted from. The gatekeeper
itself is left as it is: mail is re-based onto this package in a later release.
"""

from .settings import Settings, connection_name, conf_text
from .door import Door, person_test, peer_of
from .audit import AuditLog
from .health import health_line, print_health
from .store import Store, SealError, NotBuilt, read_data_key, store_check
from .vault import resolve_reference
from .ladder import Ladder
from .log import log
# The token service's session side. `http_auth` and `mcp_storage` are imported
# by name, each by a caller that has the library it builds on.
from .tokens_client import TokensClient, TokensError, fingerprint

__all__ = [
    "Settings", "connection_name", "conf_text",
    "Door", "person_test", "peer_of",
    "AuditLog",
    "health_line", "print_health",
    "Store", "SealError", "NotBuilt", "read_data_key", "store_check",
    "resolve_reference",
    "Ladder",
    "log",
    "TokensClient", "TokensError", "fingerprint",
]
