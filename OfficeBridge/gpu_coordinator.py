"""GPU ownership for the bridge and the ComfyUI queue gate. No background GPU load
is enabled until both the opt-in configuration and the queue gate are installed.
"""
import threading
import time


class GPUCoordinator:
    def init_gpu_coordinator(self):
        self.gpu_enabled = self.config.get('comfy_priority_enabled') is True
        self.comfy_requested = False
        self.comfy_worker_reserved = False
        self.restore_after_comfy = False
        self.comfy_idle_since = None
        self.gpu_phase = 'idle' if self.gpu_enabled else 'disabled'
        self.gpu_error = ''
        self.gpu_retry_after = 0

    def gpu_status(self):
        return {'gpuPolicy': 'comfy_priority' if self.gpu_enabled else 'manual',
                'gpuPhase': self.gpu_phase, 'gpuError': self.gpu_error,
                'manuallyReleased': self.manually_released}

    def comfy_queue_busy(self):
        queue = self.upstream.json('/queue', comfy=True)
        if not isinstance(queue.get('queue_running'), list) or not isinstance(queue.get('queue_pending'), list):
            raise self.failure('无法确认 ComfyUI 队列，保持等待', 503)
        return bool(queue['queue_running'] or queue['queue_pending'])

    def require_comfy_gate(self):
        state = self.upstream.json('/workbench/gpu-gate', comfy=True)
        if state.get('protocolVersion') != 1 or state.get('enabled') is not True:
            raise self.failure('ComfyUI 显存协调组件未就绪，未自动加载 Strata', 503)

    def acquire_comfy(self):
        """Called by the local queue worker BEFORE removing a pending prompt.
        A failed/unavailable response never grants permission to execute.
        """
        if not self.gpu_enabled:
            raise self.failure('显存协调未启用', 503)
        with self.lock:
            self.comfy_requested = True
            self.comfy_worker_reserved = True
            self.restore_after_comfy = not self.manually_released
            self.comfy_idle_since = None
            if self.maintenance or self.active:
                self.gpu_phase = 'waiting_strata'
                return {'ready': False, 'reason': '等待 Strata 当前请求结束'}
            self.maintenance = True
        try:
            self.check_idle()
            self.gpu_phase = 'yielding'
            if self.health().get('loaded'):
                self.upstream.json('/unload?wait=0', {})
                if not self.health().get('loaded'):
                    self.settle_after_unload()
            if self.health().get('loaded'):
                return {'ready': False, 'reason': '等待 Strata 卸载完成'}
            # The ComfyUI worker is still gated; no prompt has started yet.
            self.check_idle()
            self.gpu_phase, self.gpu_error = 'comfy', ''
            return {'ready': True}
        except Exception:
            self.gpu_phase = 'waiting_strata'
            self.gpu_error = '等待确认 Strata 已空闲并卸载，ComfyUI 任务保留在队列中'
            return {'ready': False, 'reason': self.gpu_error}
        finally:
            with self.lock:
                self.maintenance = False

    def comfy_idle(self):
        # The single worker sends this only after the previous prompt has returned
        # and there is no pending work. A reservation never expires on a timer.
        # This closes the cancel-then-new-prompt race between a grant and queue.get.
        with self.lock:
            if self.comfy_queue_busy():
                return {'idle': False}
            self.comfy_worker_reserved = False
            return {'idle': True}

    def wait_for_comfy_memory(self):
        deadline = time.monotonic() + 30
        while True:
            with self.lock:
                if self.paused or self.comfy_requested:
                    return False
            if self.comfy_queue_busy():
                return False
            gpu = self.upstream.json('/v1/status').get('machine', {}).get('gpu', {})
            try:
                free = float(gpu['total_mib']) - float(gpu['used_mib'])
            except (KeyError, ValueError, TypeError):
                raise self.failure('无法确认空闲显存，未恢复 Strata', 503)
            if free >= self.config.get('min_free_mib', 31000):
                return True
            if time.monotonic() >= deadline:
                raise self.failure('ComfyUI 缓存尚未释放，稍后重试恢复 Strata', 503)
            time.sleep(0.25)

    def coordinate_once(self):
        if not self.gpu_enabled:
            return
        try:
            busy = self.comfy_queue_busy()
        except Exception:
            # Unknown is not idle. Never restore on a disconnected / malformed queue.
            self.comfy_idle_since = None
            self.gpu_error = '无法确认 ComfyUI 队列，自动恢复等待重连'
            return
        with self.lock:
            if busy:
                self.comfy_requested = True
                self.restore_after_comfy = not self.manually_released
                self.comfy_idle_since = None
                return
            if self.maintenance or self.active:
                return
            if self.comfy_worker_reserved:
                return
            if self.manually_released:
                self.comfy_requested = False
                self.restore_after_comfy = False
                self.comfy_idle_since = None
                self.gpu_phase, self.gpu_error = 'idle', ''
                return
            if not self.restore_after_comfy:
                return
            now = time.monotonic()
            if self.comfy_idle_since is None:
                self.comfy_idle_since = now
            if now - self.comfy_idle_since < self.config.get('comfy_idle_seconds', 10):
                self.gpu_phase = 'settling'
                return
            if self.paused:
                self.comfy_requested = False
                self.restore_after_comfy = False
                self.gpu_phase, self.gpu_error = 'idle', ''
                return
            if now < self.gpu_retry_after:
                return
            self.maintenance = True
            self.comfy_requested = False
            self.gpu_phase = 'restoring'
        loaded = False
        try:
            self.require_comfy_gate()
            self.check_idle()
            if self.comfy_queue_busy():
                return
            # /free is a worker flag; the worker handles it even while gated.
            # It can return before the CUDA cache is actually released.
            self.upstream.json('/free', {'unload_models': True, 'free_memory': True}, comfy=True)
            if not self.wait_for_comfy_memory():
                return
            self.prepare_load()
            self.upstream.json('/load', {})
            loaded = self.health().get('loaded') is True
            if not loaded:
                raise self.failure('Strata 模型未确认就绪', 503)
            # New Comfy prompts and manual pause win even if a slow load was in flight.
            with self.lock:
                interrupted = self.paused or self.comfy_requested
            if interrupted or self.comfy_queue_busy():
                self.upstream.json('/unload?wait=0', {})
                return
            with self.lock:
                self.restore_after_comfy = False
                self.gpu_phase, self.gpu_error = 'idle', ''
        except Exception:
            self.gpu_error = '自动恢复尚未完成；保留 ComfyUI 优先，稍后重试'
            self.gpu_retry_after = time.monotonic() + 30
        finally:
            with self.lock:
                self.maintenance = False
                if self.restore_after_comfy:
                    self.gpu_phase = 'settling'
        if loaded:
            self.resume_gpu_tasks()

    def resume_gpu_tasks(self):
        with self.lock:
            if self.paused or self.comfy_requested or self.maintenance:
                return
            for task in self.tasks.values():
                if task['state'] == 'waiting_comfy':
                    task['state'] = 'running'
                    threading.Thread(target=self.run_task, args=(task,), daemon=True).start()
