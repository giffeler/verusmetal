#!/usr/bin/env python3
"""Local Stratum integration: fragmented input, latest job, CPU-checked shares, reconnect.

No external pool is contacted. The synthetic address must never receive funds.
"""
from pathlib import Path
import ctypes
import json
import socket
import subprocess
import threading
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / 'build/miner/Build/Products/Release/verusmetal'
CHECKER = ROOT / 'build/setup/libverus-check.dylib'
WALLET = 'R9HDHYTuwAr3PyRkXrhYgwycrxC7Xja8zs'
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
    assert len(params) == 5 and params[0] == WALLET+'.m4'
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
                send(sock,{'id':sub['id'],'result':[None,prefix],'error':None},fragment=True)
                auth=json.loads(stream.readline());assert auth['method']=='mining.authorize'
                assert auth['params']==[WALLET+'.m4','x']
                send(sock,{'method':'mining.set_target','params':[f'{TARGET:064x}']})
                # A job can arrive before authorization, and a clean job can supersede it.
                send(sock,{'method':'mining.notify','params':job('superseded',7)})
                send(sock,{'method':'mining.notify','params':work})
                send(sock,{'id':auth['id'],'result':True,'error':None})
                while True:
                    line=stream.readline()
                    if not line:raise AssertionError('client closed before submitting')
                    request=json.loads(line)
                    assert request['method']=='mining.submit'
                    validate_share(request['params'],work,prefix)
                    accepted.append({'session':session,'job':work[0]})
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
result=subprocess.run([str(BINARY),'mine','--pool',f'stratum+tcp://127.0.0.1:{port}',
    '--wallet',WALLET,'--worker','m4','--batch','64','--duration','15','--stop-after-shares','2',
    '--stats-file',str(log),'--stats-interval','1','--api-bind',f'127.0.0.1:{api_port}'],capture_output=True,text=True,timeout=25)
thread.join(timeout=1)
print(result.stdout);print(result.stderr)
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
