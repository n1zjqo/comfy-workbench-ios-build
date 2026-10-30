import importlib.util
import io
import json
from pathlib import Path
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from bridge import Gateway, Failure, Handler, WaitingForComfy
import test_bridge as support

spec = importlib.util.spec_from_file_location('queue_gate', Path(__file__).parent / 'comfy_workbench_identity/gpu_gate.py')
queue_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(queue_module)


class GatedUpstream(support.FakeUpstream):
    gate_enabled = True
    def json(self, path, body=None, comfy=False):
        if path == '/workbench/gpu-gate':
            return {'protocolVersion': 1, 'enabled': self.gate_enabled}
        return super().json(path, body, comfy)


class GPUCoordinatorTests(unittest.TestCase):
    def setUp(self):
        support.BridgeTests.setUp(self)
        self.config.update(comfy_priority_enabled=True, comfy_idle_seconds=10)
        self.up = GatedUpstream()
        self.gate = Gateway(self.config, self.up)
    tearDown = support.BridgeTests.tearDown

    def cycle(self, now):
        with patch('gpu_coordinator.time.monotonic', return_value=now):
            self.gate.coordinate_once()

    def finish_comfy(self):
        self.up.comfy_running = self.up.comfy_pending = []
        self.assertTrue(self.gate.comfy_idle()['idle'])
        self.cycle(100)
        self.cycle(111)

    def test_comfy_grant_requires_confirmed_strata_unload(self):
        self.up.comfy_pending = ['synthetic']
        self.assertTrue(self.gate.acquire_comfy()['ready'])
        self.assertFalse(self.up.loaded)
        self.assertIn('/unload?wait=0', self.up.calls)
        self.assertTrue(self.gate.comfy_worker_reserved)

    def test_current_strata_reply_finishes_and_new_replies_wait(self):
        with self.gate.admission():
            self.up.comfy_pending = ['synthetic']
            self.assertFalse(self.gate.acquire_comfy()['ready'])
            self.assertTrue(self.up.loaded)
        with self.assertRaises(WaitingForComfy):
            with self.gate.admission():
                pass
        self.assertTrue(self.gate.acquire_comfy()['ready'])

    def test_upstream_still_generating_blocks_grant_after_client_disconnect(self):
        self.up.running = 1
        self.assertFalse(self.gate.acquire_comfy()['ready'])
        self.assertNotIn('/unload?wait=0', self.up.calls)

    def test_false_unload_ack_never_grants_gpu(self):
        original = self.up.json
        self.up.json = lambda p, *a, **k: {} if p.startswith('/unload') else original(p, *a, **k)
        self.assertFalse(self.gate.acquire_comfy()['ready'])
        self.assertTrue(self.up.loaded)

    def test_cancelled_queue_does_not_expire_worker_reservation(self):
        self.gate.acquire_comfy()
        self.cycle(100); self.cycle(100000)
        self.assertNotIn('/load', self.up.calls)
        self.assertTrue(self.gate.comfy_worker_reserved)
        self.finish_comfy()
        self.assertTrue(self.up.loaded)

    def test_end_of_all_jobs_releases_comfy_then_restores_strata(self):
        self.gate.acquire_comfy()
        self.finish_comfy()
        self.assertTrue(self.up.loaded)
        self.assertLess(self.up.calls.index('/free'), self.up.calls.index('/load'))
        self.assertEqual(self.gate.gpu_phase, 'idle')
        self.assertFalse(self.gate.comfy_requested)

    def test_pending_and_running_jobs_both_prevent_restoration(self):
        self.gate.acquire_comfy()
        for name in ('comfy_running', 'comfy_pending'):
            setattr(self.up, name, ['synthetic'])
            self.assertFalse(self.gate.comfy_idle()['idle'])
            self.cycle(1); self.cycle(100)
            setattr(self.up, name, [])
        self.assertNotIn('/free', self.up.calls)
        self.assertNotIn('/load', self.up.calls)

    def test_short_idle_gap_does_not_reload_between_images(self):
        self.gate.acquire_comfy(); self.gate.comfy_idle()
        self.cycle(1); self.cycle(9)
        self.up.comfy_pending = ['next']; self.cycle(10)
        self.up.comfy_pending = []; self.cycle(15); self.cycle(24)
        self.assertNotIn('/load', self.up.calls)
        self.cycle(26)
        self.assertTrue(self.up.loaded)

    def test_manual_pause_remains_paused_after_comfy_finishes(self):
        self.gate.control('pause')
        self.assertTrue(self.gate.acquire_comfy()['ready'])
        self.finish_comfy()
        self.assertTrue(self.gate.paused)
        self.assertFalse(self.up.loaded)
        self.assertNotIn('/load', self.up.calls)

    def test_manual_release_cancels_pending_automatic_restore(self):
        self.gate.acquire_comfy()
        self.gate.comfy_idle()
        self.cycle(100)
        result = self.gate.control('release')
        self.assertFalse(result['maintenance'])
        self.assertTrue(result['manuallyReleased'])
        self.cycle(111)
        self.assertFalse(self.up.loaded)
        self.assertFalse(self.gate.comfy_requested)
        self.assertNotIn('/load', self.up.calls)

    def test_manual_release_persists_and_chat_can_wake_it(self):
        self.gate.control('release')
        gate = Gateway(self.config, self.up)
        self.assertTrue(gate.manually_released)
        self.assertFalse(gate.paused)
        self.gate = gate
        gate.acquire_comfy()
        self.finish_comfy()
        self.assertFalse(self.up.loaded)
        with gate.admission():
            self.assertFalse(gate.manually_released)
        gate.acquire_comfy()
        self.finish_comfy()
        self.assertTrue(self.up.loaded)

    def test_manual_release_never_discards_comfy_worker_reservation(self):
        self.gate.acquire_comfy()
        self.gate.control('release')
        self.cycle(100000)
        self.assertTrue(self.gate.comfy_worker_reserved)
        self.assertFalse(self.up.loaded)

    def test_explicit_load_reenables_automatic_restore(self):
        self.gate.control('release')
        self.gate.control('load')
        self.assertFalse(self.gate.manually_released)
        self.gate.acquire_comfy()
        self.finish_comfy()
        self.assertTrue(self.up.loaded)

    def test_paused_during_slow_restore_unloads_again(self):
        self.gate.acquire_comfy()
        self.up.on_load = lambda: self.gate.control('pause')
        self.finish_comfy()
        self.assertFalse(self.up.loaded)
        self.assertTrue(self.gate.paused)

    def test_new_prompt_during_slow_restore_waits_then_unloads_strata(self):
        self.gate.acquire_comfy()
        observed = []
        def queued():
            self.up.comfy_pending = ['arrived-during-load']
            observed.append(self.gate.acquire_comfy()['ready'])
        self.up.on_load = queued
        self.finish_comfy()
        self.assertEqual(observed, [False])
        self.assertFalse(self.up.loaded)
        self.assertTrue(self.gate.acquire_comfy()['ready'])

    def test_unknown_queue_never_means_idle(self):
        self.gate.acquire_comfy(); self.gate.comfy_idle()
        original = self.up.json
        self.up.json = lambda p, *a, **k: {} if p == '/queue' else original(p, *a, **k)
        self.cycle(100); self.cycle(1000)
        self.assertNotIn('/free', self.up.calls)
        self.assertNotIn('/load', self.up.calls)
        self.assertTrue(self.gate.gpu_error)

    def test_missing_queue_gate_blocks_manual_and_automatic_load(self):
        self.gate.acquire_comfy()
        self.up.gate_enabled = False
        self.finish_comfy()
        with self.assertRaises(Failure):
            self.gate.control('load')
        self.assertNotIn('/load', self.up.calls)

    def test_queue_check_applies_even_if_strata_is_already_loaded(self):
        self.up.comfy_pending = ['synthetic']
        with self.assertRaises(WaitingForComfy):
            with self.gate.admission():
                pass

    def test_insufficient_vram_defers_restore_with_backoff(self):
        self.gate.acquire_comfy(); self.gate.comfy_idle()
        self.cycle(100)
        self.up.free = 1
        with patch('gpu_coordinator.time.monotonic', side_effect=[111, 111, 142, 142]), patch('gpu_coordinator.time.sleep'):
            self.gate.coordinate_once()
        self.assertNotIn('/load', self.up.calls)
        self.assertFalse(self.gate.maintenance)
        self.assertGreater(self.gate.gpu_retry_after, 142)

    def test_file_task_waits_without_consuming_a_step(self):
        self.gate.comfy_requested = True
        task = {'state': 'running', 'step': 3, 'events': [], '_messages': []}
        self.gate.run_task(task)
        self.assertEqual(task['state'], 'waiting_comfy')
        self.assertEqual(task['step'], 3)

    def test_waiting_tasks_resume_once_and_cancelled_tasks_stay_cancelled(self):
        self.gate.tasks = {'a': {'state': 'waiting_comfy'}, 'b': {'state': 'cancelled'}}
        with patch('gpu_coordinator.threading.Thread') as thread:
            self.gate.resume_gpu_tasks(); self.gate.resume_gpu_tasks()
        self.assertEqual(thread.call_count, 1)
        self.assertEqual(self.gate.tasks['b']['state'], 'cancelled')

    def test_default_configuration_does_not_enable_automatic_gpu_changes(self):
        self.config['comfy_priority_enabled'] = False
        gate = Gateway(self.config, self.up)
        with self.assertRaises(Failure):
            gate.acquire_comfy()
        gate.coordinate_once()
        self.assertEqual(self.up.calls, [])

    def request(self, address, key):
        handler = object.__new__(Handler)
        handler.server = SimpleNamespace(gate=self.gate, key='synthetic-key')
        handler.path = '/workbench/comfy/acquire'; handler.client_address = (address, 1234)
        handler.headers = {'Authorization': 'Bearer ' + key, 'Content-Length': '2'}
        handler.rfile = io.BytesIO(b'{}'); handler.connection = SimpleNamespace(settimeout=lambda _: None)
        result = []
        handler.reply = lambda value, status=200: result.append((status, value))
        handler.handle_request(True)
        return result[0][0]

    def test_gpu_grants_require_key_and_loopback(self):
        self.assertEqual(self.request('127.0.0.1', 'wrong'), 401)
        self.assertEqual(self.request('192.0.2.1', 'synthetic-key'), 403)
        self.assertTrue(self.up.loaded)
        self.assertEqual(self.request('127.0.0.1', 'synthetic-key'), 200)


class FakeQueue:
    def __init__(self):
        self.mutex = threading.RLock(); self.not_empty = threading.Condition(self.mutex)
        self.queue = ['synthetic']; self.popped = []
    def get(self, timeout=None):
        with self.mutex:
            if not self.queue:
                return None
            item = self.queue.pop(0); self.popped.append(item)
            return item, len(self.popped)


class QueueGateTests(unittest.TestCase):
    def test_failed_grant_keeps_prompt_pending_and_cancellable(self):
        queue = FakeQueue()
        gate = queue_module.QueueGate(queue, SimpleNamespace(ready=lambda: False))
        with patch.object(queue.not_empty, 'wait'):
            self.assertIsNone(gate.get())
        self.assertEqual(queue.queue, ['synthetic'])
        self.assertEqual(queue.popped, [])

    def test_network_call_does_not_hold_queue_mutex(self):
        queue = FakeQueue()
        def ready():
            seen = []
            def cancel():
                with queue.mutex:
                    queue.queue.clear(); seen.append(True)
            worker = threading.Thread(target=cancel); worker.start(); worker.join(timeout=1)
            self.assertEqual(seen, [True], 'Queue must remain cancellable during a handshake')
            return True
        gate = queue_module.QueueGate(queue, SimpleNamespace(ready=ready))
        self.assertIsNone(gate.get())
        self.assertEqual(queue.popped, [])

    def test_granted_prompt_is_consumed_exactly_once(self):
        queue = FakeQueue()
        idle = []
        gate = queue_module.QueueGate(queue, SimpleNamespace(ready=lambda: True, idle=lambda: idle.append(True)))
        self.assertEqual(gate.get(), ('synthetic', 1))
        self.assertIsNone(gate.get(timeout=0))
        self.assertEqual(queue.popped, ['synthetic'])
        self.assertEqual(idle, [True])

    def test_remote_bridge_and_embedded_credentials_are_rejected(self):
        for url in ('http://192.0.2.1:8086', 'https://example.com', 'http://user:secret@127.0.0.1:8086', 'http://127.0.0.1:8086/bad'):
            with self.assertRaises(ValueError):
                queue_module.GateClient(url, 'never-read')


if __name__ == '__main__':
    unittest.main()
