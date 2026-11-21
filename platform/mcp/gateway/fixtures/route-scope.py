import contextlib
import json
import os
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


@contextlib.contextmanager
def server(name):
    calls = []

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            req = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            method = req['method']
            reply = {'jsonrpc': '2.0', 'id': req.get('id')}
            if method == 'initialize':
                result = {
                    'protocolVersion': '2025-06-18',
                    'serverInfo': {'name': name, 'version': '1'},
                    'capabilities': {'tools': {}},
                }
            elif method == 'tools/list':
                result = {'tools': [{'name': name, 'inputSchema': {'type': 'object'}}]}
            elif method == 'tools/call':
                if req['params']['name'] != name:
                    reply['error'] = {'code': -32602, 'message': 'No such tool'}
                    result = None
                else:
                    result = {'content': [{'type': 'text', 'text': name}]}
            else:
                calls.append(method)
                self.send_response(202)
                self.end_headers()
                return
            if result is not None:
                calls.append(method)
                reply['result'] = result
            payload = json.dumps(reply).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def log_message(self, format, *args):
            pass

    with ThreadingHTTPServer(('127.0.0.1', 0), Handler) as upstream:
        worker = threading.Thread(target=upstream.serve_forever)
        worker.start()
        try:
            yield f'http://127.0.0.1:{upstream.server_port}/mcp', calls
        finally:
            upstream.shutdown()
            worker.join()


def rpc(url, headers, method, request_id=None, **params):
    request = {'jsonrpc': '2.0', 'method': method}
    if request_id is not None:
        request.update(id=request_id, params=params)
    with urllib.request.urlopen(
        urllib.request.Request(url, json.dumps(request).encode(), headers), timeout=5
    ) as response:
        text = response.read().decode()
        body = next((line[6:] for line in text.splitlines() if line.startswith('data: ')), text)
        return (json.loads(body) if body else None), response.headers


@contextlib.contextmanager
def session(url):
    headers = {'content-type': 'application/json', 'accept': 'application/json, text/event-stream'}
    response, handshake = rpc(
        url, headers, 'initialize', 1,
        protocolVersion='2025-06-18', clientInfo={'name': 'check-route-scope', 'version': '1'}, capabilities={},
    )
    headers.update({'Mcp-Session-Id': handshake['Mcp-Session-Id'],
                    'Mcp-Protocol-Version': response['result']['protocolVersion']})
    rpc(url, headers, 'notifications/initialized')
    try:
        yield headers
    finally:
        with urllib.request.urlopen(urllib.request.Request(url, headers=headers, method='DELETE'), timeout=5) as response:
            assert response.status == 202


def verify(gateway, config):
    config['config'].update(adminAddr='off', statsAddr='off', readinessAddr='off')
    binding = config['binds'][0]
    listener = binding['listeners'][0]
    routes = {route['matches'][0]['path']['exact']: route for route in listener['routes']}
    default_path = '/mcp'
    selected_path = next(path for path in routes if path.startswith(default_path + '/'))
    listener['routes'] = [routes[default_path], routes[selected_path]]
    with server('ordinary') as (ordinary_url, ordinary_calls), server('selected') as (selected_url, selected_calls):
        for path, name, endpoint in ((default_path, 'ordinary', ordinary_url), (selected_path, 'selected', selected_url)):
            routes[path]['backends'][0]['mcp']['targets'] = [{'name': name, 'mcp': {'host': endpoint}}]
        with socket.socket() as reservation:
            reservation.bind(('127.0.0.1', 0))
            binding['port'] = reservation.getsockname()[1]
        base_url = f'http://127.0.0.1:{binding["port"]}'
        scenario = os.path.join(os.environ['TMPDIR'], 'route-scope.json')
        with open(scenario, 'w') as stream:
            json.dump(config, stream)
        with subprocess.Popen([gateway, '-f', scenario]) as process:
            try:
                for _ in range(80):
                    try:
                        with socket.create_connection(('127.0.0.1', binding['port']), timeout=0.1):
                            break
                    except OSError:
                        if process.poll() is not None:
                            raise RuntimeError('agentgateway exited during startup')
                        time.sleep(0.05)
                for path, name in ((default_path, 'ordinary'), (selected_path, 'selected')):
                    url = base_url + path
                    with session(url) as headers:
                        result, _ = rpc(url, headers, 'tools/list', 2)
                        assert [tool['name'] for tool in result['result']['tools']] == [name], result
                        result, _ = rpc(url, headers, 'tools/call', 3, name=name, arguments={})
                        assert result['result']['content'] == [{'type': 'text', 'text': name}], result
                        if path == default_path:
                            assert selected_calls == [], selected_calls
                            rejected, _ = rpc(url, headers, 'tools/call', 4, name='selected', arguments={})
                            assert 'error' in rejected or rejected['result'].get('isError'), rejected
                            assert selected_calls == [], selected_calls
                assert ordinary_calls.count('tools/call') == selected_calls.count('tools/call') == 1
                try:
                    with session(base_url + selected_path + '/unlisted'):
                        raise AssertionError('an unlisted route connected')
                except urllib.error.HTTPError as e:
                    assert e.code == 404, e
                print('ordinary and explicitly selected routes isolated; unlisted route rejected')
            finally:
                process.terminate()
                process.wait(timeout=5)


if __name__ == '__main__':
    verify(sys.argv[1], json.load(sys.stdin))
