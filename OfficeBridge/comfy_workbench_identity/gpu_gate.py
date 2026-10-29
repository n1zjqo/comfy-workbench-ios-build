"""ComfyUI queue gate: no prompt is popped until Strata confirms release.
Does not change prompt JSON, execution graphs, node titles, or cancellation APIs.
"""
import json
from pathlib import Path
import threading
from urllib.parse import urlsplit
from urllib.request import Request, build_opener, ProxyHandler, HTTPRedirectHandler


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


class GateClient:
    def __init__(self, url, key_file):
        parts = urlsplit(url)
        if parts.scheme != 'http' or parts.hostname not in ('127.0.0.1', '::1') or parts.username or parts.password or parts.query or parts.fragment or parts.path not in ('', '/'):
            raise ValueError('GPU gate must use a loopback HTTP bridge')
        self.url = url.rstrip('/') + '/workbench/comfy/'
        self.key = Path(key_file).read_text().strip()
        if len(self.key) < 24:
            raise ValueError('GPU gate requires the existing bridge key')
        self.opener = build_opener(ProxyHandler({}), NoRedirect())

    def ready(self):
        return self.call('acquire', 'ready')

    def idle(self):
        return self.call('idle', 'idle')

    def call(self, action, field):
        request = Request(self.url + action, data=b'{}', headers={'Authorization': 'Bearer ' + self.key, 'Content-Type': 'application/json'})
        try:
            with self.opener.open(request, timeout=3) as response:
                data = response.read(16385)
                return response.status == 200 and len(data) <= 16384 and json.loads(data).get(field) is True
        except Exception:
            return False  # Keep the prompt pending on disconnect/auth/unload failure.


class QueueGate:
    def __init__(self, queue, client):
        for name in ('get', 'mutex', 'queue', 'not_empty'):
            if not hasattr(queue, name):
                raise RuntimeError('Unsupported ComfyUI queue; do not enable GPU coordination')
        self.queue, self.client = queue, client
        self.original_get = queue.get
        self.waiting = False
        self.worker_lock = threading.Lock()

    def get(self, timeout=None):
        # Only the single ComfyUI prompt worker consumes this queue. Never hold
        # its mutex across an HTTP request: cancellation and /queue must work.
        with self.worker_lock:
            with self.queue.mutex:
                empty = not self.queue.queue
            if empty:
                self.waiting = False
                self.client.idle()
                with self.queue.not_empty:
                    if not self.queue.queue:
                        self.queue.not_empty.wait(timeout=min(timeout, 1) if timeout is not None else 1)
                return None
            if not self.client.ready():
                self.waiting = True
                with self.queue.not_empty:
                    self.queue.not_empty.wait(timeout=0.5)
                return None
            self.waiting = False
            # A pending prompt may have been cancelled during the handshake.
            return self.original_get(timeout=0)


def install(queue, url, key_file):
    gate = QueueGate(queue, GateClient(url, key_file))
    queue.get = gate.get
    return gate
