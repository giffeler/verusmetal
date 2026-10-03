#!/usr/bin/env python3
"""Local Stratum integration: fragmented input, latest job, CPU-checked shares, reconnect.

No external pool is contacted. The synthetic address must never receive funds.
"""
from pathlib import Path
import ctypes
import datetime
import math
import re
import argparse
import errno
import fcntl
import json
import os
import pty
import socket
import struct
import subprocess
import termios
import threading
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--terminal-width', type=int, help='Exercise status output in a pseudo-terminal')
parser.add_argument('--quiet', action='store_true', help='Verify silent mining with telemetry and API enabled')
parser.add_argument('--credentials-case', choices=['default','cli','environment'], default='default')
options = parser.parse_args()
if options.quiet and options.terminal_width is not None:
    parser.error('quiet and terminal-width checks run separately')
if options.terminal_width is not None and options.terminal_width < 2:
    parser.error('terminal width must be at least 2')
BINARY = ROOT / 'build/miner/Build/Products/Release/verusmetal'
CHECKER = ROOT / 'build/setup/libverus-check.dylib'
WALLET = 'R9HDHYTuwAr3PyRkXrhYgwycrxC7Xja8zs'
WORKER = 'rig1' if options.credentials_case == 'default' else None
USER = WALLET + ('.' + WORKER if WORKER else '')
PASSWORD = {'default':'x','cli':'pool-test-password','environment':'environment-test-password'}[options.credentials_case]
ENVIRONMENT = dict(os.environ)
ENVIRONMENT.pop('VERUSMETAL_POOL_PASSWORD', None)
if options.credentials_case != 'default':
    ENVIRONMENT['VERUSMETAL_POOL_PASSWORD'] = 'environment-test-password'
TARGET = ((1 << 256)-1)//32
lib = ctypes.CDLL(str(CHECKER))
lib.vm_cpu_hashes.argtypes = [ctypes.c_void_p,ctypes.POINTER(ctypes.c_uint32),ctypes.c_uint32,
                              ctypes.c_uint32,ctypes.c_void_p,ctypes.c_void_p]
lib.vm_cpu_hashes.restype = None


def digest(data):
    storage = ctypes.create_string_buffer(data)
    output = ctypes.create_string_buffer(32)
    scratch = ctypes.create_string_buffer(8896)
    length = ctypes.c_uint32(len(data))
    lib.vm_cpu_hashes(storage,ctypes.byref(length),len(data),1,output,scratch)
    return output.raw


def job(name, version):
    solution = bytearray(124)
    solution[0] = version; solution[5] = 1; solution[6:8] = (4).to_bytes(2,'little')
    solution[8:124] = bytes(range(8,124))
    return [name,'04000100','11'*32,'22'*32,'33'*32,'12345678','ffff071f',True,solution.hex()]


def send(sock, payload, fragment=False):
    data = (json.dumps(payload)+'\n').encode()
    if fragment:
        sock.sendall(data[:9]); time.sleep(.005); sock.sendall(data[9:])
    else:
        sock.sendall(data)


def validate_share(params, work, prefix):
    assert len(params) == 5 and params[0] == USER
    assert params[1] == work[0] and params[2] == work[5], 'stale job or nTime'
    nonce = bytes.fromhex(prefix+params[3]); assert len(nonce)==32
    serialized_solution = bytes.fromhex(params[4])
    assert len(serialized_solution)==1347 and serialized_solution[:3]==bytes.fromhex('fd4005')
    sol = serialized_solution[3:]
    reserved = bytes.fromhex(work[8]); assert sol[:len(reserved)]==reserved
    assert sol[1329:1333] == bytes.fromhex(prefix), 'subscription prefix missing'
    block = bytearray(bytes.fromhex(''.join(work[1:7]))+nonce+serialized_solution)
    if sol[0] >= 7:
        for lo,hi in [(4,100),(104,140),(151,215)]:block[lo:hi]=bytes(hi-lo)
    assert int.from_bytes(digest(bytes(block)),'little') <= TARGET, 'CPU rejected share target'


server = socket.socket(); server.bind(('127.0.0.1',0)); server.listen(2); server.settimeout(15)
port=server.getsockname()[1]
with socket.socket() as probe:
    probe.bind(('127.0.0.1',0)); api_port=probe.getsockname()[1]
errors=[]; accepted=[]

def serve():
    try:
        for session in range(2):
            sock,_=server.accept(); sock.settimeout(10)
            with sock:
                stream=sock.makefile('rb')
                prefix = '01020304' if session==0 else '05060708'
                work=job('current'+str(session),8 if session==0 else 4)
                sub=json.loads(stream.readline());assert sub['method']=='mining.subscribe'
                if session == 0:time.sleep(1.2)
                send(sock,{'id':sub['id'],'result':[None,prefix],'error':None},fragment=True)
                auth=json.loads(stream.readline());assert auth['method']=='mining.authorize'
                assert auth['params']==[USER,PASSWORD]
                send(sock,{'method':'mining.set_target','params':[f'{1:064x}']})
                # Exercise both authorization/job orders and a clean superseding job.
                if session == 0:
                    send(sock,{'id':auth['id'],'result':True,'error':None})
                    time.sleep(2.1)
                if session == 1:send(sock,{'method':'mining.notify','params':job('superseded',7)})
                send(sock,{'method':'mining.notify','params':work})
                if session == 1:send(sock,{'id':auth['id'],'result':True,'error':None})
                # Allow a real rate sample before any share; no easy-target backpressure.
                time.sleep(1.2)
                send(sock,{'method':'mining.set_target','params':[f'{TARGET:064x}']})
                while True:
                    line=stream.readline()
                    if not line:raise AssertionError('client closed before submitting')
                    request=json.loads(line)
                    assert request['method']=='mining.submit'
                    validate_share(request['params'],work,prefix)
                    accepted.append({'session':session,'job':work[0]})
                    # A pending share retains its submission target across an update.
                    send(sock,{'method':'mining.set_target','params':[f'{TARGET//2:064x}']})
                    time.sleep(.15)
                    send(sock,{'id':request['id'],'result':True,'error':None})
                    # Exercise clean disconnect and a fresh subscription after one accepted share.
                    time.sleep(.02)
                    if session == 0:
                        for path in ['/v1/status','/v1/devices','/healthz']:
                            with urllib.request.urlopen(f'http://127.0.0.1:{api_port}'+path,timeout=3) as response:
                                assert response.status == 200
                                assert json.load(response)
                    stream.close()
                    break
    except BaseException as e:
        errors.append(repr(e))
    finally:server.close()

thread=threading.Thread(target=serve,daemon=True);thread.start()
log=ROOT/'build/setup/local-pool-events.jsonl'
if log.exists():log.unlink()
command=[str(BINARY),'mine','--pool',f'stratum+tcp://127.0.0.1:{port}',
    '--wallet',WALLET,'--batch-nonces','64','--duration','15','--stop-after-shares','2',
    '--stats-file',str(log),'--stats-interval','240','--telemetry-interval','1','--api-bind',f'127.0.0.1:{api_port}']
if WORKER:command.extend(['--worker',WORKER])
if options.credentials_case == 'cli':command.extend(['--password',PASSWORD])
if options.quiet:command.append('--quiet')
if options.terminal_width is None:
    captured=subprocess.run(command,capture_output=True,timeout=25,env=ENVIRONMENT)
    result=subprocess.CompletedProcess(command,captured.returncode,captured.stdout.decode(),captured.stderr.decode())
    assert '\x1b' not in result.stdout and '\r' not in result.stdout
else:
    master,slave=pty.openpty()
    fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',24,options.terminal_width,0,0))
    chunks=[]
    def read_terminal():
        try:
            while True:
                chunk=os.read(master,4096)
                if not chunk:break
                chunks.append(chunk)
        except OSError as error:
            if error.errno != errno.EIO:errors.append(repr(error))
    process=subprocess.Popen(command,stdin=subprocess.DEVNULL,stdout=slave,stderr=slave,env=ENVIRONMENT)
    os.close(slave)
    reader=threading.Thread(target=read_terminal,daemon=True);reader.start()
    try:
        code=process.wait(timeout=25)
    finally:
        if process.poll() is None:process.kill();process.wait()
        reader.join(timeout=2)
        os.close(master)
    output=b''.join(chunks).decode()
    result=subprocess.CompletedProcess(command,code,output,'')
    refresh='\r\x1b[2K'
    assert output.count(refresh)>=2,repr(output)
    assert output.endswith('\r\n'),repr(output)
    for frame in output.split(refresh)[1:]:
        line=frame.split('\r')[0].split('\n')[0]
        if 'MH/s' in line:
            assert len(line)<options.terminal_width,(len(line),line)
            assert '\n' not in frame.rstrip('\r\n'),repr(frame)
    assert 'shares=2/0' in output and 'stopped' in output,repr(output)
thread.join(timeout=1)
print(result.stdout);print(result.stderr)
if options.quiet:
    assert result.stdout == result.stderr == '', (result.stdout,result.stderr)
else:
    for phase in ['Preparing GPU...', 'Connecting to pool...', 'Subscribing...',
                  'Authorizing worker...', 'Waiting for first job...', 'Reconnecting in 1s...']:
        assert phase in result.stdout,(phase,result.stdout)
    rates=re.findall(r'(?:current=)?([0-9.]+)(?: avg=[0-9.]+ effective=[0-9.]+)? MH/s[^\r\n]* mining',result.stdout)
    assert sum(float(rate)>0 for rate in rates)>=2, 'a nonzero rate must appear promptly on both connections'
    if options.terminal_width is not None:
        assert re.search(r'(Subscribing|Waiting for first job)\.\.\. [1-9]\d*s',result.stdout),result.stdout
    else:
        assert result.stdout.count('Waiting for first job...') == 1
assert 'Share accepted' not in result.stdout
assert not errors,errors
assert result.returncode==0,result.returncode
assert len(accepted)==2,accepted
records=[json.loads(line) for line in log.read_text().splitlines()]
assert len({r['sessionID'] for r in records})==1
assert sum(r['type']=='share_accepted' for r in records)==2
assert sum(r['type']=='session_ended' for r in records)==1
assert sum(r['type']=='connected' for r in records)>=2
assert records[-1]['fields']['accepted']=='2'
print('Local pool integration passed: two CPU-verified shares, PBaaS and legacy jobs, clean replacement, reconnect, loopback API.')

assert all(r['schemaVersion']==2 for r in records)
assert all(re.search(r'\.\d{3}Z$',r['timestamp']) for r in records)
for r in records:datetime.datetime.fromisoformat(r['timestamp'].replace('Z','+00:00'))
monotonic=[r['monotonicNanoseconds'] for r in records]
assert monotonic==sorted(monotonic)
submissions={r['fields']['id']:r for r in records if r['type']=='share_submitted'}
for reply in (r for r in records if r['type']=='share_accepted'):
    original=submissions[reply['fields']['id']]
    assert records.index(original)<records.index(reply)
    for field in ['job','generation','target_hex']:
        assert reply['fields'][field]==original['fields'][field]
    assert reply['fields']['target_hex']==f'{TARGET:064x}'
    assert 100<=float(reply['fields']['response_ms'])<10000,reply
assert any(r['type']=='target_changed' and r['fields']['target_hex']==f'{TARGET//2:064x}' for r in records)
snapshots=[r['fields'] for r in records if r['type']=='performance_snapshot']
assert snapshots[0]['kind']=='initial' and snapshots[-1]['kind']=='final'
assert any(s['kind']=='periodic' for s in snapshots)
assert sum(int(s['interval_nonces']) for s in snapshots)==int(records[-1]['fields']['nonces'])
assert sum(int(s['interval_dispatches']) for s in snapshots)==int(records[-1]['fields']['dispatches'])
assert int(records[-1]['fields']['submitted'])==len(submissions)
for s in snapshots:
    assert s['batch_size']=='64'
    for field in ['interval_seconds','interval_gpu_seconds','interval_command_wall_seconds','interval_hashrate']:
        assert math.isfinite(float(s[field])) and float(s[field])>=0
    if float(s['interval_seconds'])>0:
        assert math.isclose(float(s['interval_hashrate']),int(s['interval_nonces'])/float(s['interval_seconds']))
assert WALLET not in log.read_text()
print('Telemetry passed: interval snapshots, target changes, submission context, monotonic response timing, append-only schema.')

if options.credentials_case != 'default':
    assert PASSWORD not in result.stdout + result.stderr + log.read_text()
    assert ', worker ' not in result.stdout
print('Credentials passed:', options.credentials_case)
