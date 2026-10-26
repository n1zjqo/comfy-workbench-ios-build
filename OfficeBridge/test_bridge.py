import contextlib
import json
import io
from pathlib import Path
import tempfile
import threading
import unittest
from types import SimpleNamespace
from unittest.mock import patch
from bridge import Gateway, Failure, Upstream, Handler, LIMIT


class FakeUpstream:
    def __init__(self):
        self.loaded = True
        self.calls = []
        self.running = 0
        self.comfy_running = []
        self.comfy_pending = []
        self.free = 32000
        self.on_load = None
    def json(self, path, body=None, comfy=False):
        self.calls.append(path)
        if path == '/health':
            return {'loaded': self.loaded, 'model': 'test-model'}
        if path == '/v1/status':
            return {'activity': {'in_flight': self.running}, 'machine': {'gpu': {'total_mib': 32000, 'used_mib': 32000 - self.free}}}
        if path.startswith('/unload'):
            self.loaded = False
            return {'status': 'unloaded'}
        if path == '/load':
            if self.on_load:
                self.on_load()
            self.loaded = True
            return {'status': 'loaded'}
        if path == '/queue':
            return {'queue_running': self.comfy_running, 'queue_pending': self.comfy_pending}
        if path == '/free':
            return {}
        raise AssertionError(path)


class BridgeTests(unittest.TestCase):
    def setUp(self):
        # Workspace-contained synthetic data only. No listener, GPU or clipboard access.
        self.temp = tempfile.TemporaryDirectory(dir=Path(__file__).parent)
        self.root = Path(self.temp.name)
        self.config = {'state_file': str(self.root / 'state.json'), 'server_id': '20dc53dc-5504-4d0d-911e-1b107e886f88', 'task_workspace': str(self.root / 'tasks'), 'comfy_url': 'http://127.0.0.1:8188', 'model': 'test'}
        (self.root / 'tasks').mkdir()
        self.up = FakeUpstream()
        self.gate = Gateway(self.config, self.up)
    def tearDown(self):
        self.temp.cleanup()
    def test_release_keeps_auto_wake_enabled(self):
        self.gate.control('release')
        self.assertFalse(self.up.loaded)
        self.assertFalse(self.gate.paused)
        with self.gate.admission():
            self.assertEqual(self.gate.active, 1)
        self.assertEqual(self.gate.active, 0)
    def test_pause_blocks_legacy_and_app_until_resume(self):
        self.gate.control('pause')
        self.assertFalse(self.up.loaded)
        with self.assertRaises(Failure) as caught:
            with self.gate.admission():
                pass
        self.assertEqual(caught.exception.status, 423)
        self.gate.control('resume')
        self.assertTrue(self.up.loaded)
        self.assertFalse(self.gate.paused)
    def test_pause_drains_in_flight_without_interrupting(self):
        with self.gate.admission():
            self.gate.control('pause')
            self.assertTrue(self.up.loaded)
            self.gate.drain_once()
            self.assertTrue(self.up.loaded)
        self.gate.drain_once()
        self.assertFalse(self.up.loaded)
    def test_pause_persists_across_restart(self):
        self.gate.control('pause')
        self.assertTrue(Gateway(self.config, self.up).paused)
    def test_corrupt_state_fails_closed(self):
        Path(self.config['state_file']).write_text('invalid')
        self.assertTrue(Gateway(self.config, self.up).paused)
    def test_unload_failure_keeps_pause(self):
        original = self.up.json
        def fail(path, *args, **kwargs):
            if path.startswith('/unload'):
                raise Failure('offline', 503)
            return original(path, *args, **kwargs)
        self.up.json = fail
        with self.assertRaises(Failure):
            self.gate.control('pause')
        self.assertTrue(self.gate.paused)
        self.assertFalse(self.gate.maintenance)
    def test_release_refuses_native_upstream_busy(self):
        self.up.running = 1
        with self.assertRaises(Failure):
            self.gate.control('release')
        self.assertTrue(self.up.loaded)
    def test_pause_wins_over_slow_resume(self):
        self.gate.control('pause')
        self.up.on_load = lambda: self.gate.control('pause')
        self.gate.control('resume')
        self.assertTrue(self.gate.paused)
        self.gate.drain_once()
        self.assertFalse(self.up.loaded)
    def test_persistence_failure_does_not_claim_pause(self):
        with patch('bridge.atomic_json', side_effect=OSError('disk full')):
            with self.assertRaises(OSError):
                self.gate.control('pause')
        self.assertFalse(self.gate.paused)
        self.assertTrue(self.up.loaded)
    def test_busy_comfy_blocks_load(self):
        self.up.loaded = False
        for field in ('comfy_running', 'comfy_pending'):
            setattr(self.up, field, ['job'])
            with self.assertRaises(Failure):
                self.gate.control('load')
            setattr(self.up, field, [])
        self.assertNotIn('/load', self.up.calls)
    def test_low_vram_blocks_automatic_and_manual_load(self):
        self.up.loaded = False
        self.up.free = 100
        with self.assertRaises(Failure):
            self.gate.control('load')
        with self.assertRaises(Failure):
            with self.gate.admission():
                pass
    def test_free_comfy_does_not_interrupt_queue(self):
        self.up.comfy_pending = ['job']
        with self.assertRaises(Failure):
            self.gate.control('free_comfy')
        self.assertNotIn('/free', self.up.calls)
    def test_mutating_unknown_tool_is_rejected(self):
        with self.assertRaises(Failure):
            self.gate.tool('shell', {'command': 'echo bad'}, approved=True)
    def test_file_write_requires_approval_and_cannot_overwrite(self):
        args = {'path': 'result.txt', 'content': 'synthetic output'}
        with self.assertRaises(Failure):
            self.gate.tool('write_file', args)
        self.gate.tool('write_file', args, approved=True)
        self.assertEqual(self.gate.tool('read_file', {'path': 'result.txt'}), 'synthetic output')
        with self.assertRaises(Failure):
            self.gate.tool('write_file', args, approved=True)
    def test_workspace_escape_is_rejected(self):
        for name in ('../secret', '/etc/passwd', ''):
            with self.assertRaises(Failure):
                self.gate.file_path(name)
    def test_approval_is_bound_to_server_arguments_and_used_once(self):
        pending = {'id': 'approval', 'tool': 'write_file', 'arguments': {'path': 'approved.txt', 'content': 'approved'}, 'callId': 'call'}
        task = {'id': 'task', 'state': 'approval', 'pending': pending, '_messages': [], 'events': []}
        self.gate.tasks['task'] = task
        with patch.object(threading.Thread, 'start'):
            self.gate.task_action('task', {'action': 'approve', 'approvalId': 'approval', 'arguments': {'path': '../bad'}})
        self.assertEqual((self.root / 'tasks/approved.txt').read_text(), 'approved')
        with self.assertRaises(Failure):
            self.gate.task_action('task', {'action': 'approve', 'approvalId': 'approval'})
    def test_cancel_prevents_pending_write(self):
        self.gate.tasks['task'] = {'id': 'task', 'state': 'approval', 'pending': {'id': 'a'}, 'events': []}
        self.gate.task_action('task', {'action': 'cancel'})
        with self.assertRaises(Failure):
            self.gate.task_action('task', {'action': 'approve', 'approvalId': 'a'})
    def test_upstream_must_be_loopback_and_no_embedded_credentials(self):
        for url in ('https://example.com', 'http://192.168.1.20', 'http://name:secret@127.0.0.1'):
            with self.assertRaises(ValueError):
                Upstream(url, 'synthetic')
    def request(self, path, body=None, key='synthetic-secret', size=None):
        handler = object.__new__(Handler)
        handler.path = path
        data = json.dumps(body).encode() if body is not None else b''
        handler.headers = {'Authorization': 'Bearer ' + key, 'Content-Length': str(len(data) if size is None else size)}
        handler.rfile = io.BytesIO(data)
        handler.server = SimpleNamespace(gate=self.gate, key='synthetic-secret')
        handler.connection = SimpleNamespace(settimeout=lambda _: None)
        result = []
        handler.reply = lambda value, status=200: result.append((status, value))
        handler.handle_request(body is not None)
        return result[0]
    def test_http_control_requires_key(self):
        code, _ = self.request('/workbench/control', {'action': 'pause'}, key='wrong')
        self.assertEqual(code, 401)
        self.assertFalse(self.gate.paused)
    def test_http_identity_has_no_credentials(self):
        code, body = self.request('/workbench/info', key='')
        self.assertEqual(code, 200)
        self.assertEqual(set(body), {'protocolVersion', 'service', 'serverId', 'name'})
    def test_http_all_generation_routes_respect_pause(self):
        self.gate.control('pause')
        for path in ('/v1/chat/completions', '/v1/messages', '/v1/responses', '/v1/completions'):
            code, body = self.request(path, {'model': 'synthetic', 'stream': True})
            self.assertEqual(code, 423, path)
    def test_http_legacy_load_unload_reply_remains_compatible(self):
        code, result = self.request('/unload?wait=0', {})
        self.assertEqual((code, result['status']), (200, 'unloaded'))
        code, result = self.request('/load', {})
        self.assertEqual((code, result['status']), (200, 'loaded'))
    def test_http_blocks_unknown_mutation_and_oversized_payload(self):
        self.assertEqual(self.request('/config', {'host': '0.0.0.0'})[0], 404)
        self.assertEqual(self.request('/workbench/control', {}, size=LIMIT + 1)[0], 413)
    def test_task_pauses_between_model_steps(self):
        self.gate.paused = True
        task = {'state': 'running', 'step': 0, 'events': [], '_messages': []}
        self.gate.run_task(task)
        self.assertEqual(task['state'], 'paused')
        self.assertEqual(task['step'], 0)
        self.assertEqual(self.up.calls, [])
    def test_paused_task_blocks_duplicate_new_task(self):
        self.gate.tasks['existing'] = {'state': 'paused'}
        with self.assertRaises(Failure):
            self.gate.new_task({'prompt': 'synthetic task'})


if __name__ == '__main__':
    unittest.main()
