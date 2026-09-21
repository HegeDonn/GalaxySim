"""Send a Python file to the installed Blender MCP add-on on localhost:9876."""
import json
import socket
import sys
from pathlib import Path

script = Path(sys.argv[1]).resolve()
# Blender executes remotely without setting __file__; preserve the local script location.
code = "__file__ = " + repr(str(script)) + "\n" + script.read_text()
request = {"type": "execute", "code": code, "strict_json": True}
with socket.create_connection(("127.0.0.1", 9876), timeout=10) as connection:
    connection.settimeout(300)
    connection.sendall(json.dumps(request).encode() + b"\0")
    response = bytearray()
    while b"\0" not in response:
        chunk = connection.recv(65536)
        if not chunk:
            raise RuntimeError("Blender disconnected before completing its response")
        response.extend(chunk)
    payload = json.loads(response.split(b"\0", 1)[0])
    print(json.dumps(payload, indent=2))
    if payload.get("status") == "error":
        sys.exit(1)
