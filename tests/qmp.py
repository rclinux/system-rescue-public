"""QMP inspection/control for a locally created test VM socket only."""
import json
from pathlib import Path
import socket
import sys
import time

path = Path(sys.argv[1]).resolve()
root = Path(__file__).resolve().parents[1] / 'packaging/build'
if not path.is_relative_to(root) or path.name != 'qmp.sock':
    raise SystemExit('Expected a project test-VM QMP socket')
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.connect(str(path))
f = s.makefile('rwb', buffering=0)
json.loads(f.readline())

def execute(name, arguments=None):
    f.write((json.dumps({'execute': name, 'arguments': arguments or {}}) + '\n').encode())
    while True:
        response = json.loads(f.readline())
        if 'error' in response: raise RuntimeError(response)
        if 'return' in response: return response['return']

execute('qmp_capabilities')
command = sys.argv[2]
if command == 'screen':
    print(execute('screendump', {'filename': str(path.parent / 'screen.ppm')}))
elif command == 'key':
    print(execute('send-key', {'keys': [{'type': 'qcode', 'data': k} for k in sys.argv[3].split('-')]}))
elif command == 'type':
    punctuation = {' ': 'spc', '/': 'slash', '.': 'dot', '-': 'minus', '_': 'shift-minus',
                   ':': 'shift-semicolon', ';': 'semicolon', '=': 'equal', '\n': 'ret',
                   "'": 'apostrophe', '"': 'shift-apostrophe'}
    for char in sys.argv[3]:
        code = punctuation.get(char, char.lower())
        if char.isupper(): code = 'shift-' + code
        execute('send-key', {'keys': [{'type': 'qcode', 'data': k} for k in code.split('-')], 'hold-time': 20})
        time.sleep(.035)
elif command == 'quit':
    execute('quit')
else:
    raise SystemExit('Use screen, key, type, or quit')
f.close(); s.close()
