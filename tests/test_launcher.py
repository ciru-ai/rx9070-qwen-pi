import hashlib, importlib.util, json, os, pathlib, subprocess, tempfile, threading, unittest, types, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest.mock import patch

ROOT=pathlib.Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('launch', ROOT/'RX9070-Qwen/launch.py')
L=importlib.util.module_from_spec(spec);spec.loader.exec_module(L)
DATA=b'gguf-download-test'*10000
SHA=hashlib.sha256(DATA).hexdigest()

class Handler(BaseHTTPRequestHandler):
    def log_message(self,*a):pass
    def do_GET(self):
        offset=int(self.headers.get('Range','bytes=0-')[6:-1])
        if self.path=='/ignore':offset=0
        content=DATA[offset:]
        self.send_response(206 if offset else 200)
        if offset:self.send_header('Content-Range',f'bytes {offset}-{len(DATA)-1}/{len(DATA)}')
        self.send_header('Content-Length',str(len(content)));self.end_headers();self.wfile.write(content)

class Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.http=ThreadingHTTPServer(('127.0.0.1',0),Handler)
        cls.thread=threading.Thread(target=cls.http.serve_forever,daemon=True);cls.thread.start()
        cls.url=f'http://127.0.0.1:{cls.http.server_port}'
    @classmethod
    def tearDownClass(cls):cls.http.shutdown();cls.http.server_close();cls.thread.join()
    def test_resume_and_range_ignored(self):
        for route in ['/resume','/ignore']:
            with tempfile.TemporaryDirectory() as d:
                p=pathlib.Path(d)/'model.gguf';p.with_suffix('.gguf.part').write_bytes(DATA[:200])
                L.download(self.url+route,p,SHA,len(DATA));self.assertEqual(p.read_bytes(),DATA)
                with patch.object(L.urllib.request,'urlopen',side_effect=AssertionError('should be offline')):
                    L.download(self.url+route,p,SHA,len(DATA))
    def test_completed_partial(self):
        with tempfile.TemporaryDirectory() as d:
            p=pathlib.Path(d)/'model.gguf';p.with_suffix('.gguf.part').write_bytes(DATA)
            with patch.object(L.urllib.request,'urlopen',side_effect=AssertionError('should be offline')):
                L.download(self.url,p,SHA,len(DATA))
            self.assertEqual(p.read_bytes(),DATA)
    def test_wrong_hash_never_promoted(self):
        with tempfile.TemporaryDirectory() as d:
            p=pathlib.Path(d)/'bad.gguf'
            with self.assertRaisesRegex(RuntimeError,'Checksum mismatch'):
                L.download(self.url,p,'0'*64,len(DATA))
            self.assertFalse(p.exists())
    def test_existing_bad_model_preserved(self):
        with tempfile.TemporaryDirectory() as d:
            p=pathlib.Path(d)/'bad.gguf';p.write_bytes(b'keep')
            with self.assertRaisesRegex(RuntimeError,'Checksum mismatch'):L.download(self.url,p,SHA)
            self.assertEqual(p.read_bytes(),b'keep')
    def test_probe_selects_9070_over_integrated(self):
        def run(args,**kw):
            text='draft-mtp --spec-draft-n-max --spec-draft-type-k --spec-draft-type-v --fit --cache-ram --flash-attn --jinja' if '--help' in args else 'Available devices:\n  ROCm0: AMD Radeon Graphics (1000 MiB, 500 MiB free)\n  ROCm1: AMD Radeon RX 9070 (16304 MiB, 14000 MiB free)'
            return subprocess.CompletedProcess(args,0,text,'')
        with patch.object(L.subprocess,'run',side_effect=run):self.assertEqual(L.probe(pathlib.Path('/test/llama-server'),{}),'ROCm1')
    def test_probe_rejects_wrong_gpu(self):
        def run(args,**kw):
            text='draft-mtp --spec-draft-n-max --spec-draft-type-k --spec-draft-type-v --fit --cache-ram --flash-attn --jinja' if '--help' in args else 'ROCm0: AMD Radeon Graphics (1000 MiB, 500 MiB free)'
            return subprocess.CompletedProcess(args,0,text,'')
        with patch.object(L.subprocess,'run',side_effect=run):
            with self.assertRaisesRegex(RuntimeError,'No RX 9070'):L.probe(pathlib.Path('/test/llama-server'),{})
    @unittest.skipUnless(os.environ.get('LLAMA_TEST_BIN'), 'Set LLAMA_TEST_BIN for engine integration')
    def test_actual_engine_accepts_arguments(self):
        exe=pathlib.Path(os.environ['LLAMA_TEST_BIN']).resolve()
        for no_mtp in [False,True]:
            args=L.arguments(exe,pathlib.Path('/not-downloaded.gguf'),'ROCm0',4096,2,8080,no_mtp)
            p=subprocess.run(args+['--help'],env=L.engine_environment(exe),capture_output=True,text=True)
            self.assertEqual(p.returncode,0,p.stderr)
    def test_allocation_error_is_retryable(self):
        with tempfile.TemporaryDirectory() as d:
            p=pathlib.Path(d)/'fake';p.write_text('#!/usr/bin/env python3\nprint("hipErrorOutOfMemory",flush=True)\nraise SystemExit(1)\n');p.chmod(0o755)
            self.assertEqual(L.serve([str(p)],os.environ.copy(),pathlib.Path(d)/'test.log',L.choose_port(19100),False),(1,True))
    def test_interrupt_stops_child(self):
        with tempfile.TemporaryDirectory() as d:
            p=pathlib.Path(d)/'fake'
            p.write_text('#!/usr/bin/env python3\nimport time\ntime.sleep(60)\n');p.chmod(0o755)
            real_popen=subprocess.Popen
            children=[]
            def start(*a,**kw):
                child=real_popen(*a,**kw);children.append(child);return child
            with patch.object(L.subprocess,'Popen',side_effect=start), patch.object(L,'time',types.SimpleNamespace(monotonic=time.monotonic, sleep=lambda _: (_ for _ in ()).throw(KeyboardInterrupt))):
                with self.assertRaises(KeyboardInterrupt):
                    L.serve([str(p)],os.environ.copy(),pathlib.Path(d)/'test.log',L.choose_port(19100),False)
            self.assertIsNotNone(children[0].poll())
    def test_healthy_process_and_clean_exit(self):
        with tempfile.TemporaryDirectory() as d:
            port=L.choose_port(19100)
            p=pathlib.Path(d)/'fake';p.write_text('''#!/usr/bin/env python3
import threading,time
from http.server import HTTPServer,BaseHTTPRequestHandler
class H(BaseHTTPRequestHandler):
 def log_message(self,*a):pass
 def do_GET(self):
  self.send_response(200);self.end_headers();self.wfile.write(b'{"status":"ok"}')
s=HTTPServer(('127.0.0.1',PORT),H)
threading.Thread(target=s.serve_forever,daemon=True).start()
time.sleep(3)
s.shutdown()
'''.replace('PORT',str(port)));p.chmod(0o755)
            self.assertEqual(L.serve([str(p)],os.environ.copy(),pathlib.Path(d)/'test.log',port,False),(0,False))

if __name__=='__main__':unittest.main(verbosity=2)
