#!/usr/bin/env python3
"""Регрессионные тесты ping-monitor. Все цели — из TEST-NET, сеть не используется."""
import csv
import fcntl
import os
from pathlib import Path
import pty
import re
import select
import signal
import struct
import subprocess
import tempfile
import termios
import time
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'ping-monitor.sh'
MOCK = r'''#!/usr/bin/env python3
import os, sys, pathlib, time, signal
args=sys.argv[1:]
if '-V' in args: print('ping from iputils mock'); sys.exit(0)
if '-h' in args: print('-M do dont want probe'); sys.exit(0)
assert '-w' not in args, 'regression: -w combined with -c 1'
assert args[args.index('-c')+1]=='1'
addr=args[-1]; d=pathlib.Path(os.environ['MOCK_DIR']); f=d/addr.replace(':','_')
n=int(f.read_text())+1 if f.exists() else 1; f.write_text(str(n))
mode=os.environ.get('MOCK_MODE','sequence')
if mode=='hang':
    signal.signal(signal.SIGTERM,signal.SIG_IGN)
    (d/'pid').write_text(str(os.getpid()))
    time.sleep(60)
if mode=='sequence':
    if n in (2,3):
        print('1 packets transmitted, 0 received, 100% packet loss'); sys.exit(1)
    if n==4:
        print('ping: '+ 'long diagnostic text '*35); sys.exit(2)
    if n==5:
        print('successful response, changed format'); sys.exit(0)
if mode=='render' and 3<=n<=6:
    print('ping: '+ 'long diagnostic text '*35); sys.exit(2)
if mode=='slow' and addr.endswith('.2'): time.sleep(.32)
if mode=='stale': time.sleep(.6)
print('64 bytes: icmp_seq=1 ttl=64 time=0.1235 ms')
print('1 packets transmitted, 1 received, 0% packet loss')
'''

class MonitorTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name); self.bin=self.root/'bin'; self.bin.mkdir()
        self.mock=self.bin/'ping'; self.mock.write_text(MOCK); self.mock.chmod(0o755)
        self.env=os.environ.copy(); self.env.update(PATH=str(self.bin)+':'+self.env['PATH'], MOCK_DIR=str(self.root), TERM='xterm-256color', TMPDIR=str(self.root))
    def run_monitor(self, *args, mode='sequence', log=True):
        env=dict(self.env,MOCK_MODE=mode)
        cmd=[str(SCRIPT),'--plain','--refresh','0.1','-i','0.1','-W','0.1',*args]
        path=self.root/'log.tsv'
        if log: cmd += ['-l',str(path),'--samples']
        p=subprocess.run(cmd,env=env,capture_output=True,text=True,timeout=15)
        self.assertEqual(p.returncode,0,p.stderr+'\n'+p.stdout[-2000:])
        if log:
            with path.open() as f: rows=list(csv.DictReader(f,delimiter='\t'))
            self.assertTrue(all(None not in r and None not in r.values() and len(r)==28 for r in rows))
            return p,rows
        return p,[]
    def test_statistics_and_single_probe(self):
        p,rows=self.run_monitor('-n','6','192.0.2.1')
        samples=[r for r in rows if r['event']=='SAMPLE']
        self.assertEqual([r['status'] for r in samples],['UP','DOWN','DOWN','ERROR','UP','UP'])
        final=next(r for r in rows if r['event']=='FINAL')
        self.assertEqual([final[k] for k in ('attempts','sent','lost','errors','outages','rtt_count','rtt_parse_errors')],['6','5','2','1','1','2','1'])
        self.assertEqual(final['rtt_avg_ms'],'0.124'); self.assertIn('RTT ОШИБ.',p.stdout)
    def test_independent_workers(self):
        _,rows=self.run_monitor('-n','5','192.0.2.1','192.0.2.2',mode='slow')
        def periods(ip): return [int(r['period_ms']) for r in rows if r['event']=='SAMPLE' and r['ip']==ip and r['period_ms']!='-']
        fast,slow=periods('192.0.2.1'),periods('192.0.2.2')
        self.assertEqual(len(fast),4); self.assertEqual(len(slow),4)
        self.assertLess(max(fast),min(slow))
    def test_ipv6_dedup(self):
        _,rows=self.run_monitor('-n','1','2001:db8::1','2001:0DB8:0:0:0:0:0:1',mode='up')
        self.assertEqual(len([r for r in rows if r['event']=='FINAL']),1)
    def test_profiles(self):
        for profile in ('compact','standard','extended','full'):
            p,_=self.run_monitor('--'+profile,'-n','2','192.0.2.1',mode='up',log=False)
            self.assertIn('Профиль: '+profile,p.stdout); self.assertIn('ИТОГОВЫЙ ОТЧЁТ',p.stdout)
    def test_stop_stubborn_worker(self):
        env=dict(self.env,MOCK_MODE='hang')
        with subprocess.Popen([str(SCRIPT),'--plain','--refresh','0.1','-W','30','192.0.2.1'],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True) as p:
            deadline=time.monotonic()+5
            while not (self.root/'pid').exists() and time.monotonic()<deadline: time.sleep(.03)
            self.assertTrue((self.root/'pid').exists())
            pid=int((self.root/'pid').read_text()); t=time.monotonic(); p.send_signal(signal.SIGTERM)
            out,err=p.communicate(timeout=7)
            self.assertEqual(p.returncode,143,err); self.assertLess(time.monotonic()-t,5)
            self.assertIn('ИТОГОВЫЙ ОТЧЁТ',out)
            # В отдельных контейнерах PID 1 может не собирать сиротские zombie.
            proc=Path(f'/proc/{pid}/stat')
            if proc.exists(): self.assertEqual(proc.read_text().split(') ',1)[1][0],'Z')
    def test_stale_is_not_packet_loss(self):
        p,rows=self.run_monitor('--stale','0.2','-n','2','192.0.2.1',mode='stale')
        self.assertIn('УСТАРЕЛО',p.stdout)
        final=next(r for r in rows if r['event']=='FINAL')
        self.assertEqual((final['status'],final['lost'],final['errors']),('UP','0','0'))
    def test_log_lock_does_not_stop_probes(self):
        log=self.root/'log.tsv'; addr='192.0.2.1'; counter=self.root/addr
        env=dict(self.env,MOCK_MODE='up')
        cmd=[str(SCRIPT),'--plain','--compact','--refresh','0.2','-i','0.1','-W','0.1','-n','12',addr,'-l',str(log),'--samples']
        with subprocess.Popen(cmd,env=env,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,text=True) as p:
            try:
                deadline=time.monotonic()+8
                while not counter.exists() and time.monotonic()<deadline: time.sleep(.03)
                self.assertTrue(counter.exists())
                with log.open('a') as fd:
                    fcntl.flock(fd,fcntl.LOCK_EX)
                    first=int(counter.read_text() or '0')
                    deadline=time.monotonic()+3
                    last=first
                    while last<first+2 and time.monotonic()<deadline:
                        time.sleep(.05)
                        try: last=int(counter.read_text())
                        except ValueError: pass
                    self.assertGreaterEqual(last,first+2,'probes stopped while log was locked')
                _,err=p.communicate(timeout=20)
                self.assertEqual(p.returncode,0,err)
            finally:
                if p.poll() is None: p.send_signal(signal.SIGTERM)
        with log.open() as f: rows=list(csv.DictReader(f,delimiter='\t'))
        self.assertEqual(len([r for r in rows if r['event']=='SAMPLE']),12)
        self.assertEqual(next(r for r in rows if r['event']=='FINAL')['log_dropped'],'0')
    def test_sigint(self):
        with subprocess.Popen([str(SCRIPT),'--plain','--compact','--refresh','0.1','-i','0.1','192.0.2.1'],env=dict(self.env,MOCK_MODE='up'),stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True) as p:
            deadline=time.monotonic()+5
            while not (self.root/'192.0.2.1').exists() and time.monotonic()<deadline: time.sleep(.03)
            self.assertTrue((self.root/'192.0.2.1').exists())
            try:
                p.send_signal(signal.SIGINT)
                out,err=p.communicate(timeout=7)
                self.assertEqual(p.returncode,130,err); self.assertIn('ИТОГОВЫЙ ОТЧЁТ',out)
            finally:
                if p.poll() is None:
                    p.terminate()
                    try: p.communicate(timeout=7)
                    except subprocess.TimeoutExpired: p.kill(); p.communicate()
    def test_terminal_render_recovery_and_resize(self):
        master,slave=pty.openpty()
        def resize(r,c): fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',r,c,0,0))
        resize(16,80)
        env=dict(self.env,MOCK_MODE='render')
        cmd=[str(SCRIPT),'--refresh','0.1','-i','0.2','-W','0.1','-n','9','192.0.2.1','192.0.2.2']
        p=subprocess.Popen(cmd,env=env,stdin=slave,stdout=slave,stderr=slave,start_new_session=True)
        data=b''; deadline=time.monotonic()+25; resized=False
        try:
            while time.monotonic()<deadline:
                if select.select([master],[],[],.1)[0]:
                    try: data+=os.read(master,65536)
                    except OSError: break
                if not resized and 'ОШИБКА'.encode() in data:
                    # Уменьшение терминала во время длинной ошибки.
                    resize(12,60); resized=True
                if p.poll() is not None:
                    while select.select([master],[],[],.05)[0]:
                        try: data+=os.read(master,65536)
                        except OSError: break
                    break
            self.assertEqual(p.wait(timeout=3),0,data[-2000:]); self.assertTrue(resized)
        finally:
            if p.poll() is None: p.kill(); p.wait()
            os.close(slave); os.close(master)
        text=data.decode('utf-8',errors='replace')
        self.assertIn('\x1b[?1049h',text); self.assertIn('\x1b[?1049l',text[-6000:])
        screen=text.split('\x1b[?1049h',1)[1].split('\x1b[?1049l',1)[0]
        frames=screen.split('\x1b[1;1H\x1b[2K')[1:]
        self.assertGreater(len(frames),4)
        error_seen=False; recovered=False
        for frame in frames:
            frame='\x1b[1;1H\x1b[2K'+frame
            lines=re.findall(r'\x1b\[(\d+);1H\x1b\[2K(.*?)(?=\x1b\[\d+;1H|$)',frame,re.S)
            self.assertTrue(lines)
            for y,line in lines:
                visible=re.sub(r'\x1b\[[0-9;?]*[A-Za-z]','',line)
                self.assertNotRegex(visible,r'[\r\n]')
                self.assertLessEqual(int(y),16)
                self.assertLessEqual(len(visible),59 if "Профиль: compact" in frame else 79)
                if "Профиль: compact" in frame: self.assertLessEqual(int(y),12)
            if 'ОШИБКА' in frame: error_seen=True
            if error_seen and 'ДОСТУПЕН' in frame and 'Ошибка 192.' not in frame and 'ОШИБКА' not in frame: recovered=True
        self.assertTrue(error_seen); self.assertTrue(recovered)
        self.assertIn("Профиль: compact",screen)
        self.assertIn("Профиль: standard",screen)

if __name__=='__main__':
    # Даже при запуске набора в фоне дочерний bash должен наследовать SIGINT по умолчанию.
    signal.signal(signal.SIGINT, signal.default_int_handler)
    unittest.main(verbosity=2)
