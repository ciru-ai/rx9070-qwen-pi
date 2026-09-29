import importlib.util,json,pathlib,sys,tempfile,threading,unittest
from unittest.mock import patch
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
ROOT=pathlib.Path(__file__).resolve().parents[1]/'RX9070-Qwen'
sys.path.insert(0,str(ROOT))
import tune as T

class Tests(unittest.TestCase):
    def test_device_selection_does_not_guess(self):
        with tempfile.TemporaryDirectory() as d:
            root=pathlib.Path(d)
            def gpu(n,total):
                p=root/f'card{n}'/'device';p.mkdir(parents=True)
                (p/'vendor').write_text('0x1002');(p/'mem_info_vram_total').write_text(str(total))
                (p/'mem_info_vram_used').write_text(str(2048*T.MIB));return p
            gpu(0,512*T.MIB);wanted=gpu(1,16384*T.MIB)
            self.assertEqual(T.find_gpu(root),wanted.resolve())
            self.assertEqual(T.memory(wanted)['free_mib'],14336)
            gpu(2,16384*T.MIB)
            with self.assertRaises(RuntimeError):T.find_gpu(root)
    def test_rejects_cpu_offload_and_insufficient_headroom(self):
        row={'completed':True,'layers':(66,66),'minimum_free_mib':600}
        self.assertTrue(T.acceptable(row,512))
        self.assertFalse(T.acceptable(dict(row,layers=(38,66)),512))
        self.assertFalse(T.acceptable(dict(row,minimum_free_mib=511),512))
        self.assertFalse(T.acceptable(dict(row,completed=False),512))
        self.assertEqual(T.placement('load_tensors: offloaded 66/66 layers to GPU'),(66,66))
    def test_probe_samples_memory_checks_context_and_cleans_process(self):
        class Handler(BaseHTTPRequestHandler):
            def log_message(self,*a):pass
            def do_GET(self):
                body={'status':'ok'} if self.path=='/health' else {'default_generation_settings':{'n_ctx':32768}}
                self.send_response(200);self.end_headers();self.wfile.write(json.dumps(body).encode())
            def do_POST(self):
                body=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                result={'tokens':list(range(len(body['content'])//5))} if self.path=='/tokenize' else {'content':'fixture output','timings':{'predicted_n':128}}
                self.send_response(200);self.end_headers();self.wfile.write(json.dumps(result).encode())
        server=ThreadingHTTPServer(('127.0.0.1',0),Handler);thread=threading.Thread(target=server.serve_forever);thread.start()
        try:
            with tempfile.TemporaryDirectory() as d:
                root=pathlib.Path(d);exe=root/'engine';exe.touch()
                with patch.object(T.L,'choose_port',return_value=server.server_port),patch.object(T,'memory',return_value={'total_mib':16384,'used_mib':12000,'free_mib':4384}),patch.object(T.subprocess,'Popen') as popen:
                    proc=popen.return_value;proc.poll.return_value=None;proc.returncode=0
                    def start(*a,**kw):
                        kw['stdout'].write('load_tensors: offloaded 66/66 layers to GPU\n');kw['stdout'].flush();return proc
                    popen.side_effect=start
                    row=T.probe(exe,root/'model', 'ROCm0',root,32768,'q8_0',512,root,full=True)
                    self.assertGreaterEqual(row['input_tokens'],32768-1280)
                    self.assertLessEqual(row['input_tokens'],32768-1024)
                    self.assertTrue(row['qualified']);self.assertEqual(row['peak_total_vram_mib'],12000)
                    proc.terminate.assert_called_once();proc.wait.assert_called_once()
        finally:server.shutdown();server.server_close();thread.join()
if __name__=='__main__':unittest.main()
