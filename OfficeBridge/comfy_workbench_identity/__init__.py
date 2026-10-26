"""Optional ComfyUI identity endpoint. Set WORKBENCH_SERVER_ID to a fixed UUID.
Install and restart ComfyUI only after the owner approves that exact change.
"""
import os
import uuid
from aiohttp import web
from server import PromptServer

NODE_CLASS_MAPPINGS = {}
NODE_DISPLAY_NAME_MAPPINGS = {}


@PromptServer.instance.routes.get('/workbench/identity')
async def workbench_identity(request):
    try:
        identity = str(uuid.UUID(os.environ['WORKBENCH_SERVER_ID']))
    except (KeyError, ValueError):
        return web.json_response({'error': 'Workbench identity has not been configured'}, status=503)
    return web.json_response({'service': 'comfy-workbench', 'serverId': identity}, headers={'Cache-Control': 'no-store'})
