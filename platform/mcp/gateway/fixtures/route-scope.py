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


def verify(gateway, config, expectation):
    config['config'].update(adminAddr='off', statsAddr='off', readinessAddr='off')
    binding = config['binds'][0]
    listener = binding['listeners'][0]
    routes = {route['matches'][0]['path']['exact']: route for route in listener['routes']}
    members = {
        path: [target['name'] for target in route['backends'][0]['mcp']['targets']]
        for path, route in routes.items()
    }
    default_path, probe_path = expectation['default'], expectation['probe']
    lazy = set(expectation['lazy'])
    assert lazy and lazy <= set(members[default_path]), members
    assert not lazy & set(members[probe_path]), members
    names = sorted({name for route_members in members.values() for name in route_members})
    with contextlib.ExitStack() as stack:
        upstreams = {name: stack.enter_context(server(name)) for name in names}
        for path, route in routes.items():
            route['backends'][0]['mcp']['targets'] = [
                {'name': name, 'mcp': {'host': upstreams[name][0]}} for name in members[path]
            ]
        with socket.socket() as reservation:
            reservation.bind(('127.0.0.1', 0))
            binding['port'] = reservation.getsockname()[1]
        base_url = f'http://127.0.0.1:{binding["port"]}'
        scenario = os.path.join(os.environ['TMPDIR'], 'route-scope.json')
        with open(scenario, 'w') as stream:
            json.dump(config, stream)

        def exposed(path, name):
            return name if len(members[path]) == 1 else f'{name}_{name}'

        def contacted():
            return sorted(name for name, (_, calls) in upstreams.items() if calls)

        def call(url, headers, request_id, name):
            result, _ = rpc(url, headers, 'tools/call', request_id, name=name, arguments={})
            return result

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
                for path in sorted(routes):
                    for _, calls in upstreams.values():
                        calls.clear()
                    url = base_url + path
                    # probe 経路は doctor と同じく全 target を呼び、既定経路は lazy target だけを呼ぶ
                    called = sorted(lazy) if path == default_path else members[path]
                    with session(url) as headers:
                        result, _ = rpc(url, headers, 'tools/list', 2)
                        tools = sorted(tool['name'] for tool in result['result']['tools'])
                        assert tools == sorted(exposed(path, name) for name in members[path]), result
                        for request_id, name in enumerate(called, start=3):
                            result = call(url, headers, request_id, exposed(path, name))
                            assert result['result']['content'] == [{'type': 'text', 'text': name}], result
                        if path == default_path:
                            for name in sorted(set(names) - set(members[path])):
                                try:
                                    rejected = call(url, headers, 99, f'{name}_{name}')
                                except urllib.error.HTTPError:
                                    continue
                                assert 'error' in rejected or rejected['result'].get('isError'), rejected
                    # 初期化・一覧・呼出しのどれも経路外の target へ届かないこと
                    assert contacted() == sorted(members[path]), (path, contacted())
                    for name in called:
                        assert upstreams[name][1].count('tools/call') == 1, (path, name)
                try:
                    with session(base_url + default_path + '/unlisted'):
                        raise AssertionError('an unlisted route connected')
                except urllib.error.HTTPError as e:
                    assert e.code == 404, e
                print('probe route never reaches lazy targets; default route calls them; '
                      'selected routes isolated; unlisted route rejected')
            finally:
                process.terminate()
                process.wait(timeout=5)


if __name__ == '__main__':
    with open(sys.argv[2]) as stream:
        verify(sys.argv[1], json.load(sys.stdin), json.load(stream))
