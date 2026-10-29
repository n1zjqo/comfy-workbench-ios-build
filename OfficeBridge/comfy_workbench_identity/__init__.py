"""Optional ComfyUI identity endpoint. Set WORKBENCH_SERVER_ID to a fixed UUID.
Install and restart ComfyUI only after the owner approves that exact change.
"""
import os
import uuid
from aiohttp import web
from server import PromptServer

NODE_CLASS_MAPPINGS = {}
NODE_DISPLAY_NAME_MAPPINGS = {}

_gpu_gate = None
if os.environ.get('WORKBENCH_GPU_COORDINATION') == '1':
    from .gpu_gate import install
    _gpu_gate = install(PromptServer.instance.prompt_queue,
                        os.environ['WORKBENCH_STRATA_BRIDGE_URL'],
                        os.environ['WORKBENCH_STRATA_KEY_FILE'])


@PromptServer.instance.routes.get('/workbench/gpu-gate')
async def gpu_gate_state(request):
    return web.json_response({'protocolVersion': 1, 'enabled': _gpu_gate is not None,
                              'waiting': _gpu_gate.waiting if _gpu_gate else False},
                             headers={'Cache-Control': 'no-store'})


@PromptServer.instance.routes.get('/workbench/identity')
async def workbench_identity(request):
    try:
        identity = str(uuid.UUID(os.environ['WORKBENCH_SERVER_ID']))
    except (KeyError, ValueError):
        return web.json_response({'error': 'Workbench identity has not been configured'}, status=503)
    return web.json_response({'service': 'comfy-workbench', 'serverId': identity}, headers={'Cache-Control': 'no-store'})
