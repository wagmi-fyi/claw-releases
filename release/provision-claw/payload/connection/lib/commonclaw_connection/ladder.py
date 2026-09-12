"""The reconnect ladder, for a service that holds a connection to a provider.

Lifted from payload/email-gatekeeper/email-gatekeeper, `listen_forever`. The
wait doubles from the conf's minimum to its maximum, with a quarter of jitter,
so a provider outage does not give every claw on the rail one synchronised
retry. A success puts the wait back to the minimum.
"""

import random


class Ladder:
    def __init__(self, settings):
        self.lo, self.hi = settings.reconnect_bounds()
        self.wait = self.lo

    def next_wait(self):
        """Seconds to wait before the next attempt, and the step moves up."""
        w = self.wait + random.uniform(0, self.wait * 0.25)
        self.wait = min(self.hi, self.wait * 2)
        return w

    def reset(self):
        self.wait = self.lo
