"""Owner-operated Strata admission gateway. Python 3.10+, standard library only.

Deploy ONLY with the inference server bound to loopback on a different port.
All inference clients must use this gateway for pause to be authoritative.
"""
import argparse
import contextlib
import hmac
import json
import os
from pathlib import Path
import threading
from gpu_coordinator import GPUCoordinator
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit
from urllib.request import Request, build_opener, ProxyHandler, HTTPRedirectHandler
from urllib.error import HTTPError

LIMIT = 12 * 1024 * 1024


class Failure(Exception):
    def __init__(self, message, status=409):
        super().__init__(message)
        self.status = status


def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = path.with_suffix('.tmp')
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w', encoding='utf-8') as out:
        json.dump(value, out, ensure_ascii=False)
        out.flush()
        os.fsync(out.fileno())
    os.replace(temporary, path)


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


class Upstream:
    def __init__(self, url, key, comfy_url=''):
        for value in [url] + ([comfy_url] if comfy_url else []):
            parts = urlsplit(value)
            if parts.scheme != 'http' or parts.hostname not in ('127.0.0.1', '::1') or parts.username or parts.query or parts.fragment:
                raise ValueError('Upstream services must use explicit loopback HTTP addresses')
        self.url, self.key, self.comfy_url = url.rstrip('/'), key, comfy_url.rstrip('/')
        self.opener = build_opener(ProxyHandler({}), NoRedirect())

    def open(self, path, body=None, comfy=False):
        root = self.comfy_url if comfy else self.url
        if not root:
            raise Failure('尚未配置 ComfyUI 资源检查', 503)
        headers = {'Accept': 'application/json', 'Content-Type': 'application/json'}
        if not comfy:
            headers['Authorization'] = 'Bearer ' + self.key
        request = Request(root + path, data=None if body is None else json.dumps(body).encode(), headers=headers)
        try:
            slow = path == '/load' or path.startswith(('/v1/chat/', '/v1/responses', '/v1/messages', '/v1/completions'))
            return self.opener.open(request, timeout=600 if slow else 8)
        except HTTPError as error:
            # Do not relay upstream pages, configuration, prompts or credentials in error messages.
            error.close()
            raise Failure('推理服务返回错误，请检查办公室服务状态', error.code)
        except OSError:
            raise Failure('办公室推理服务暂不可达', 503)

    def json(self, path, body=None, comfy=False):
        with self.open(path, body, comfy) as response:
            data = response.read(LIMIT + 1)
            status = response.status
        if len(data) > LIMIT:
            raise Failure('响应超过大小限制', 502)
        # ComfyUI /free acknowledges with HTTP 200 and an empty body. Only this
        # known operation may omit JSON; status/identity responses stay strict.
        if comfy and path == '/free' and body is not None and status in (200, 204) and not data:
            return {}
        return json.loads(data)


class WaitingForComfy(Failure):
    pass


class Gateway(GPUCoordinator):
    failure = Failure
    def __init__(self, config, upstream):
        self.config, self.upstream = config, upstream
        self.lock = threading.RLock()
        self.active = 0
        self.maintenance = False
        self.pause_revision = 0
        self.state_path = Path(config['state_file'])
        self.paused = False
        self.manually_released = False
        if self.state_path.exists():
            try:
                value = json.loads(self.state_path.read_text())
                if type(value['paused']) is not bool:
                    raise ValueError('Invalid pause state')
                self.paused = value['paused']
                self.manually_released = value.get('manually_released') is True
            except Exception:
                # Corruption must never turn a paused server back on.
                self.paused = True
        self.tasks = {}
        self.init_gpu_coordinator()

    def info(self):
        return {'protocolVersion': 1, 'service': 'strata-workbench', 'serverId': self.config['server_id'], 'name': self.config.get('name', '办公室 5090')}

    def health(self):
        return self.upstream.json('/health')

    def status(self):
        with self.lock:
            value = dict(self.info(), paused=self.paused, activeRequests=self.active, maintenance=self.maintenance, **self.gpu_status())
        try:
            health = self.health()
            status = self.upstream.json('/v1/status')
            value.update(online=True, loaded=health.get('loaded') is True, model=health.get('model', ''),
                         inFlight=int(status['activity']['in_flight']), gpu={k: float(v) for k, v in status.get('machine', {}).get('gpu', {}).items() if k in ('total_mib', 'used_mib') and isinstance(v, (int, float))})
        except Exception:
            value.update(online=False, loaded=False, model='', inFlight=0, gpu={})
        try:
            value['comfyResources'] = self.comfy_resources()
        except Exception:
            value['comfyResources'] = None
        return value

    def persist_pause(self, value):
        atomic_json(self.state_path, {'paused': value, 'manually_released': self.manually_released})
        self.paused = value

    def comfy_resources(self):
        value = self.upstream.json('/workbench/resources', comfy=True)
        count = value.get('loadedModels')
        if value.get('protocolVersion') != 1 or type(count) is not int or count < 0:
            raise Failure('无法确认 ComfyUI 驻留模型状态', 503)
        return {'loadedModels': count}

    def wait_for_comfy_release(self):
        deadline = time.monotonic() + 30
        while True:
            if self.comfy_queue_busy():
                raise Failure('ComfyUI 有新任务，未确认模型释放；没有中断任务')
            if self.comfy_resources()['loadedModels'] == 0:
                return
            if time.monotonic() >= deadline:
                raise Failure('ComfyUI 已接收释放请求，但尚未确认模型卸载，请刷新状态')
            time.sleep(0.25)

    def check_idle(self):
        state = self.upstream.json('/v1/status')
        try:
            count = int(state['activity']['in_flight'])
        except (KeyError, ValueError, TypeError):
            raise Failure('无法确认运行队列，未执行卸载')
        if self.active or count:
            raise Failure('模型正在处理任务，请等待完成')

    def prepare_load(self):
        if self.gpu_enabled:
            self.require_comfy_gate()
            if self.comfy_requested:
                raise WaitingForComfy('ComfyUI 正在使用显存，请等待生产完成')
        if self.config.get('comfy_url'):
            queue = self.upstream.json('/queue', comfy=True)
            if not isinstance(queue.get('queue_running'), list) or not isinstance(queue.get('queue_pending'), list):
                raise Failure('无法确认 ComfyUI 队列，未加载模型')
            if queue['queue_running'] or queue['queue_pending']:
                error_type = WaitingForComfy if self.gpu_enabled else Failure
                raise error_type('ComfyUI 正在运行或排队，请等待后再开启 Strata')
        if self.health().get('loaded'):
            return
        gpu = self.upstream.json('/v1/status').get('machine', {}).get('gpu', {})
        try:
            free = float(gpu['total_mib']) - float(gpu['used_mib'])
        except (KeyError, ValueError, TypeError):
            raise Failure('无法确认空闲显存，未加载模型')
        if free < self.config.get('min_free_mib', 31000):
            raise Failure('空闲显存不足，请先在 ComfyUI 释放驻留模型')

    def settle_after_unload(self):
        # Engine exit and the sampled VRAM telemetry are not synchronous. Keep
        # maintenance active briefly so an immediate auto-wake sees fresh data.
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            try:
                gpu = self.upstream.json('/v1/status')['machine']['gpu']
                if float(gpu['total_mib']) - float(gpu['used_mib']) >= self.config.get('min_free_mib', 31000):
                    return
            except (Failure, OSError, ValueError, TypeError, KeyError):
                return  # A later load still requires valid, sufficient telemetry.
            time.sleep(0.25)

    @contextlib.contextmanager
    def admission(self):
        with self.lock:
            if self.paused:
                raise Failure('Strata 已暂停，请在连接页手动恢复', 423)
            if self.gpu_enabled and (self.comfy_requested or self.gpu_phase == 'restoring'):
                raise WaitingForComfy('ComfyUI 优先生产，等待显存切换完成')
            if self.maintenance:
                raise Failure('正在切换模型，请稍后重试')
            # Serialize generations: avoids simultaneous lazy loads and provides predictable GPU use.
            if self.active:
                raise Failure('Strata 正在处理另一个请求，请稍后发送')
            self.prepare_load()
            if self.manually_released:
                self.manually_released = False
                self.persist_pause(self.paused)
            self.active += 1
        try:
            yield
        finally:
            with self.lock:
                self.active -= 1

    def control(self, action):
        if action not in ('load', 'release', 'pause', 'resume', 'reload', 'free_comfy'):
            raise Failure('未知操作', 400)
        with self.lock:
            if action == 'pause':
                # Close admission and persist BEFORE waiting for any existing request.
                if not self.paused:
                    self.persist_pause(True)
                self.pause_revision += 1
            elif self.paused and action not in ('resume', 'free_comfy'):
                raise Failure('Strata 已暂停，请先手动恢复', 423)
            if self.maintenance:
                if action == 'pause':
                    return self.status()
                raise Failure('正在切换模型，请稍后重试')
            if action == 'pause' and self.active:
                return self.status()
            self.check_idle()
            if action == 'release':
                self.manually_released = True
                self.restore_after_comfy = False
                self.persist_pause(self.paused)
            self.maintenance = True
            pause_revision = self.pause_revision
        try:
            if action == 'free_comfy':
                queue = self.upstream.json('/queue', comfy=True)
                if queue.get('queue_running') != [] or queue.get('queue_pending') != []:
                    raise Failure('ComfyUI 队列未清空，不能释放模型')
                self.comfy_resources()  # Require the paired observer before issuing a release.
                self.upstream.json('/free', {'unload_models': True, 'free_memory': True}, comfy=True)
                self.wait_for_comfy_release()
            elif action in ('release', 'pause', 'reload'):
                if self.health().get('loaded'):
                    self.upstream.json('/unload?wait=0', {})
                    if not self.health().get('loaded'):
                        self.settle_after_unload()
                if self.health().get('loaded'):
                    raise Failure('尚未确认模型资源已释放')
            if action in ('load', 'resume', 'reload'):
                with self.lock:
                    if self.pause_revision != pause_revision:
                        return self.status()
                self.prepare_load()
                self.upstream.json('/load', {})
                if not self.health().get('loaded'):
                    raise Failure('模型尚未就绪', 503)
                with self.lock:
                    # Pause requested during a slow load must win over its completion.
                    if self.pause_revision == pause_revision:
                        self.manually_released = False
                        self.persist_pause(self.paused)
                    if action == 'resume' and self.pause_revision == pause_revision:
                        self.persist_pause(False)
        finally:
            with self.lock:
                self.maintenance = False
                if action == 'resume' and not self.paused:
                    for task in self.tasks.values():
                        if task['state'] in ('paused', 'waiting_comfy'):
                            task['state'] = 'running'
                            threading.Thread(target=self.run_task, args=(task,), daemon=True).start()
        return self.status()

    def drain_once(self):
        with self.lock:
            ready = self.paused and not self.active and not self.maintenance
        if ready:
            try:
                self.control('pause')
            except Exception:
                pass  # Remain paused; retry release without reopening admission.
        self.coordinate_once()

    def file_path(self, name, write=False):
        root = Path(self.config['task_workspace']).resolve()
        relative = Path(name)
        if relative.is_absolute() or not name or '..' in relative.parts:
            raise Failure('只能访问任务目录内的相对路径', 400)
        path = root / relative
        if any(part.is_symlink() for part in [path, *path.parents] if part != root.parent):
            raise Failure('任务目录不接受符号链接', 400)
        if not path.resolve().is_relative_to(root):
            raise Failure('文件超出任务目录', 400)
        if write and path.exists():
            raise Failure('文件已存在，请使用新的文件名，避免覆盖', 409)
        return path

    def tool(self, name, args, approved=False):
        if name == 'list_files':
            root = Path(self.config['task_workspace'])
            return '\n'.join(str(p.relative_to(root)) for p in sorted(root.rglob('*')) if p.is_file() and not p.is_symlink())[:16000]
        if name == 'read_file':
            path = self.file_path(args['path'])
            if path.stat().st_size > 128000:
                raise Failure('文件超过 128 KB')
            return path.read_text(encoding='utf-8')
        if name == 'write_file':
            if not approved:
                raise Failure('写入文件需要用户确认', 403)
            text = args['content']
            if not isinstance(text, str) or len(text.encode()) > 128000:
                raise Failure('文件内容超过限制', 400)
            path = self.file_path(args['path'], write=True)
            path.parent.mkdir(parents=True, exist_ok=True)
            with path.open('x', encoding='utf-8') as out:
                out.write(text)
            return '已创建 ' + args['path']
        raise Failure('此工具未获准，未执行', 403)

    def new_task(self, body):
        prompt = body.get('prompt', '')
        if not isinstance(prompt, str) or not 0 < len(prompt) <= 16000:
            raise Failure('任务描述为空或过长', 400)
        with self.lock:
            if self.paused:
                raise Failure('Strata 已暂停', 423)
            if any(t['state'] in ('running', 'approval', 'paused', 'waiting_comfy') for t in self.tasks.values()):
                raise Failure('请先完成或取消当前任务')
            if len(self.tasks) >= 30:
                self.tasks.pop(next(iter(self.tasks)))
            task = {'id': str(uuid.uuid4()), 'state': 'running', 'title': prompt[:100], 'events': [], 'output': '', 'pending': None, 'step': 0,
                    '_messages': [{'role': 'system', 'content': 'You assist the owner on the named office computer. Files are limited to a dedicated task workspace. Use only provided tools. File writes require human approval. Never claim to run shell commands or access other computers.'}, {'role': 'user', 'content': prompt}]}
            self.tasks[task['id']] = task
        threading.Thread(target=self.run_task, args=(task,), daemon=True).start()
        return self.task_view(task)

    def task_view(self, task):
        with self.lock:
            return {k: v for k, v in task.items() if not k.startswith('_')}

    def run_task(self, task):
        tools = [{'type': 'function', 'function': {'name': name, 'description': description, 'parameters': schema}} for name, description, schema in [
            ('list_files', 'List task workspace files', {'type': 'object', 'properties': {}, 'additionalProperties': False}),
            ('read_file', 'Read a UTF-8 file from task workspace', {'type': 'object', 'properties': {'path': {'type': 'string'}}, 'required': ['path']}),
            ('write_file', 'Propose a new UTF-8 file; the owner must approve it', {'type': 'object', 'properties': {'path': {'type': 'string'}, 'content': {'type': 'string'}}, 'required': ['path', 'content']})]]
        try:
            while task['step'] < 12:
                with self.lock:
                    if task['state'] != 'running':
                        return
                    if self.paused:
                        task['state'] = 'paused'
                        task['events'].append('等待手动恢复 Strata 后继续后续步骤')
                        return
                with self.admission():
                    with self.lock:
                        task['step'] += 1
                        task['events'].append('正在处理第 %d 步' % task['step'])
                    response = self.upstream.json('/v1/chat/completions', {'model': self.config['model'], 'messages': task['_messages'], 'tools': tools, 'parallel_tool_calls': False, 'max_tokens': 4096, 'stream': False})
                with self.lock:
                    if task['state'] != 'running':
                        return
                    message = response['choices'][0]['message']
                    calls = message.get('tool_calls') or []
                    if not calls:
                        task.update(state='completed', output=message.get('content') or '任务完成')
                        return
                    if len(calls) != 1:
                        raise Failure('模型请求了多个并行工具，已停止，请重新描述任务')
                    call = calls[0]
                    name = call['function']['name']
                    args = json.loads(call['function']['arguments'])
                    task['_messages'].append(message)
                    if name == 'write_file':
                        self.file_path(args['path'], write=True)
                        task.update(state='approval', pending={'id': str(uuid.uuid4()), 'tool': name, 'arguments': args, 'callId': call['id']})
                        return
                    result = self.tool(name, args)
                    task['events'].append('已执行 ' + name)
                    task['_messages'].append({'role': 'tool', 'tool_call_id': call['id'], 'content': result})
            raise Failure('任务达到 12 步上限，已停止')
        except WaitingForComfy:
            with self.lock:
                if task['state'] != 'cancelled':
                    task['state'] = 'waiting_comfy'
                    task['events'].append('等待 ComfyUI 生产完成后继续')
        except Exception as error:
            with self.lock:
                if task['state'] != 'cancelled':
                    task.update(state='failed', output=str(error) if isinstance(error, Failure) else '任务未完成，请检查文件或模型响应')

    def task_action(self, task_id, body):
        with self.lock:
            task = self.tasks.get(task_id)
            if not task:
                raise Failure('任务不存在，控制服务可能已重启', 404)
            if body.get('action') == 'cancel':
                task.update(state='cancelled', pending=None)
                task['events'].append('已取消后续步骤；正在生成的步骤结束后不再执行工具')
            elif body.get('action') == 'approve':
                pending = task.get('pending')
                if task['state'] != 'approval' or not pending or pending['id'] != body.get('approvalId'):
                    raise Failure('确认已失效，未执行')
                if self.paused:
                    raise Failure('Strata 已暂停，请先恢复', 423)
                # Approval body never supplies new tool arguments.
                result = self.tool(pending['tool'], pending['arguments'], approved=True)
                task['_messages'].append({'role': 'tool', 'tool_call_id': pending['callId'], 'content': result})
                task['events'].append(result)
                task.update(state='running', pending=None)
                threading.Thread(target=self.run_task, args=(task,), daemon=True).start()
            else:
                raise Failure('未知任务操作', 400)
            return self.task_view(task)


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass  # No prompts, credentials or request URLs in logs.

    def reply(self, value, status=200):
        data = json.dumps(value, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(data)

    def page(self, path):
        with self.server.gate.upstream.open(path) as response:
            mime = response.headers.get('Content-Type', 'application/octet-stream')
            data = response.read(LIMIT + 1)
        if len(data) > LIMIT:
            raise Failure('网页资源过大', 502)
        self.send_response(200)
        self.send_header('Content-Type', mime)
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.handle_request(False)

    def do_POST(self):
        self.handle_request(True)

    def handle_request(self, post):
        gate = self.server.gate
        path = urlsplit(self.path).path
        try:
            if not post and path == '/workbench/info':
                self.reply(gate.info())
                return
            if not post and (path == '/' or (path.startswith(('/web/', '/fonts/')) and '..' not in path and '%' not in path and '\\' not in path)):
                self.page(path)
                return
            if not post and path in ('/health', '/api/health'):
                self.reply(gate.health())
                return
            if not hmac.compare_digest(self.headers.get('Authorization', ''), 'Bearer ' + self.server.key):
                raise Failure('API 密钥不正确', 401)
            if self.headers.get('Transfer-Encoding'):
                raise Failure('不支持此请求编码', 400)
            size = int(self.headers.get('Content-Length', '0'))
            if not 0 <= size <= LIMIT:
                raise Failure('请求过大', 413)
            self.connection.settimeout(20)
            body = json.loads(self.rfile.read(size)) if post and size else {}
            if not isinstance(body, dict):
                raise Failure('请求必须是 JSON 对象', 400)
            if not post and path == '/workbench/status':
                self.reply(gate.status())
            elif post and path in ('/workbench/comfy/acquire', '/workbench/comfy/idle'):
                if self.client_address[0] not in ('127.0.0.1', '::1'):
                    raise Failure('仅供本机 ComfyUI 队列组件调用', 403)
                self.reply(gate.acquire_comfy() if path.endswith('/acquire') else gate.comfy_idle())
            elif post and path == '/workbench/control':
                self.reply(gate.control(body.get('action')))
            elif post and path == '/workbench/tasks':
                self.reply(gate.new_task(body))
            elif path.startswith('/workbench/tasks/'):
                task_id = path.rsplit('/', 1)[-1]
                if post:
                    self.reply(gate.task_action(task_id, body))
                else:
                    with gate.lock:
                        task = gate.tasks.get(task_id)
                        if not task:
                            raise Failure('任务不存在，控制服务可能已重启', 404)
                        self.reply(gate.task_view(task))
            elif post and path in ('/load', '/unload', '/v1/load', '/v1/unload'):
                loading = path.endswith('/load')
                value = gate.control('load' if loading else 'release')
                value['status'] = 'loaded' if loading else 'unloaded'
                self.reply(value)
            elif post and path in ('/v1/chat/completions', '/v1/responses', '/v1/completions', '/v1/messages'):
                if not body.get('model'):
                    body['model'] = gate.config['model']
                with gate.admission():
                    with gate.upstream.open(path, body) as response:
                        if body.get('stream') is True:
                            self.send_response(200)
                            self.send_header('Content-Type', 'text/event-stream')
                            self.send_header('Cache-Control', 'no-cache')
                            self.send_header('Connection', 'close')
                            self.end_headers()
                            self.close_connection = True
                            while True:
                                data = response.readline(262144)
                                if not data:
                                    break
                                self.wfile.write(data)
                                self.wfile.flush()
                        else:
                            data = response.read(LIMIT + 1)
                            if len(data) > LIMIT:
                                raise Failure('响应过大', 502)
                            self.reply(json.loads(data))
            elif not post and path in ('/v1/status', '/v1/models', '/models', '/settings', '/config', '/mcp', '/props', '/slots', '/metrics'):
                self.reply(gate.upstream.json(path))
            elif post and path == '/settings':
                self.reply(gate.upstream.json(path, body))
            else:
                raise Failure('此接口未开放', 404)
        except (BrokenPipeError, ConnectionResetError, TimeoutError):
            self.close_connection = True
        except Exception as error:
            self.close_connection = True
            try:
                self.reply({'error': str(error) if isinstance(error, Failure) else '请求无法处理'}, getattr(error, 'status', 400))
            except OSError:
                pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--config', required=True)
    args = parser.parse_args()
    config = json.loads(Path(args.config).read_text())
    uuid.UUID(config['server_id'])
    key = Path(config['api_key_file']).read_text().strip()
    if len(key) < 24:
        raise ValueError('Use an API key of at least 24 characters')
    gate = Gateway(config, Upstream(config['upstream'], key, config.get('comfy_url', '')))
    server = ThreadingHTTPServer((config.get('listen', '127.0.0.1'), config.get('port', 8086)), Handler)
    server.daemon_threads = True
    server.gate, server.key = gate, key
    def drain():
        while True:
            gate.drain_once()
            time.sleep(3)
    threading.Thread(target=drain, daemon=True).start()
    server.serve_forever()


if __name__ == '__main__':
    main()
