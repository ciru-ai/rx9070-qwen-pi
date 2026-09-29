import importlib.util,json,os,pathlib,subprocess,tempfile,threading,unittest
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
from unittest.mock import patch
ROOT=pathlib.Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('launch',ROOT/'RX9070-Qwen/launch.py')
L=importlib.util.module_from_spec(spec);spec.loader.exec_module(L)
class Handler(BaseHTTPRequestHandler):
    requests=[]
    def log_message(self,*a):pass
    def do_POST(self):
        body=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        self.requests.append(body)
        self.send_response(200);self.send_header('Content-Type','text/event-stream');self.end_headers()
        if len(self.requests)==1:
            delta={'role':'assistant','tool_calls':[{'index':0,'id':'call_test','type':'function','function':{'name':'bash','arguments':'{"command":"printf Pi-local-test"}'}}]}
            finish='tool_calls'
        else:
            delta={'role':'assistant','content':'Local Pi integration passed.'};finish='stop'
        for chunk in [
            {'id':'test','object':'chat.completion.chunk','created':1,'model':'qwen3.8-27b','choices':[{'index':0,'delta':delta,'finish_reason':None}]},
            {'id':'test','object':'chat.completion.chunk','created':1,'model':'qwen3.8-27b','choices':[{'index':0,'delta':{},'finish_reason':finish}],'usage':{'prompt_tokens':600,'completion_tokens':20,'total_tokens':620}},
        ]:self.wfile.write(('data: '+json.dumps(chunk)+'\n\n').encode())
        self.wfile.write(b'data: [DONE]\n\n');self.wfile.flush()
class Tests(unittest.TestCase):
    @unittest.skipUnless(os.environ.get('PI_TEST_BIN'), 'Set PI_TEST_BIN for Pi integration')
    def test_real_pi_uses_local_default_and_completes_tool_loop(self):
        server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
        thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
        try:
            with tempfile.TemporaryDirectory() as temp:
                root=pathlib.Path(temp)
                with patch.object(L,'ROOT',root):L.configure_pi(server.server_port,4096)
                env=os.environ.copy();env.update(PI_CODING_AGENT_DIR=str(root/'pi-agent'),PI_OFFLINE='1')
                # No --provider or --model: confirms saved defaults are used too.
                p=subprocess.run([os.environ['PI_TEST_BIN'],'--offline','--no-skills','--no-extensions','--no-approve','--no-session','--print','Use bash to print Pi-local-test, then confirm success.'],cwd=root,env=env,capture_output=True,text=True,timeout=60)
                print('Pi stdout:',p.stdout);print('Pi stderr:',p.stderr)
                self.assertEqual(p.returncode,0,p.stderr)
                self.assertIn('Local Pi integration passed',p.stdout)
                self.assertEqual(len(Handler.requests),2)
                for req in Handler.requests:
                    self.assertEqual(req['model'],'qwen3.8-27b')
                    self.assertLessEqual(req['max_tokens'],1024)
                self.assertTrue(any(m['role']=='tool' and 'Pi-local-test' in str(m) for m in Handler.requests[1]['messages']))
                initial=Handler.requests[0]
                print('Initial request characters:',len(json.dumps(initial)))
                print('Tools:',[t['function']['name'] for t in initial['tools']])
                self.assertEqual({t['function']['name'] for t in initial['tools']},{'read','write','edit','bash'})
        finally:server.shutdown();server.server_close();thread.join()
    def test_low_memory_profile_and_preservation(self):
        with tempfile.TemporaryDirectory() as temp,patch.object(L,'ROOT',pathlib.Path(temp)):
            L.configure_pi(8080,4096)
            p=L.ROOT/'pi-agent/settings.json';data=json.loads(p.read_text());data['theme']='dark';p.write_text(json.dumps(data))
            L.configure_pi(8091,2048)
            provider=json.loads((L.ROOT/'pi-agent/models.json').read_text())['providers'][L.PI_PROVIDER]
            self.assertEqual(provider['baseUrl'],'http://127.0.0.1:8091/v1')
            self.assertEqual(provider['models'][0]['contextWindow'],2048)
            self.assertEqual(provider['models'][0]['maxTokens'],512)
            self.assertEqual(json.loads(p.read_text())['theme'],'dark')
if __name__=='__main__':unittest.main(verbosity=2)
