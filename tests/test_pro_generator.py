"""Pro regression tests, first initialization only."""
import ast
import base64
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'init-seafile13pro-fixed-v2.sh'
SERVICES = ('db', 'redis', 'seafile', 'seasearch', 'onlyoffice', 'seadoc', 'caddy', 'seafile-md-server', 'notification-server')

class ProGeneratorTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='seafile-pro-')
        self.target = Path(self.tmp.name) / 'deployment'
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(('SEAFILE_', 'CADDY_', 'INIT_', 'DOCKER_', 'COMPOSE_', 'ONLYOFFICE_', 'MD_', 'REDIS_', 'JWT_', 'CONTAINER_', 'IMAGE_', 'EXTERNAL_', 'DEPLOY_', 'GENERATE_', 'SEASEARCH_', 'SEADOC_'))}
        self.env.update(GENERATE_ONLY='1', SEAFILE_SERVER_HOSTNAME='files.example.test', DOCKER_COMMAND='docker', DOCKER_COMPOSE_COMMAND='docker compose', DOCKER_SOCKET='/var/run/docker.sock')

    def tearDown(self):
        self.tmp.cleanup()

    def generate(self, ok=True, **changes):
        r = subprocess.run(['bash', str(SCRIPT), str(self.target)], env=dict(self.env, **changes), capture_output=True, text=True)
        self.assertEqual(r.returncode == 0, ok, r.stderr + r.stdout)
        return r

    def values(self):
        return dict(l.split('=', 1) for l in (self.target / '.env').read_text().splitlines() if l and not l.startswith('#'))

    def edit(self, **values):
        env = self.values()
        env.update(values)
        (self.target / '.env').write_text(''.join(f'{k}={v}\n' for k, v in env.items()))

    def compose(self, **changes):
        if not shutil.which('docker'):
            self.skipTest('Docker CLI required for Compose render')
        r = subprocess.run(['bash', str(self.target / 'compose.sh'), 'config', '--format', 'json'], env=dict(self.env, **changes), capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        return json.loads(r.stdout)

    def test_new_pro_stack(self):
        self.generate()
        data = self.compose()['services']
        self.assertEqual(set(data), set(SERVICES))
        self.assertIn('seafile-pro-mc', data['seafile']['image'])
        self.assertEqual(data['seasearch']['environment']['SS_FIRST_ADMIN_PASSWORD'], self.values()['INIT_SS_ADMIN_PASSWORD'])
        self.assertEqual(base64.b64decode(self.values()['SEASEARCH_TOKEN']).decode(), self.values()['INIT_SS_ADMIN_USER'] + ':' + self.values()['INIT_SS_ADMIN_PASSWORD'])
        self.assertIn('--appendonly yes', data['redis']['command'][-1])
        self.assertTrue(data['redis']['volumes'])
        pg = next(v for v in data['onlyoffice']['volumes'] if v['target'] == '/var/lib/postgresql')
        self.assertEqual(pg['type'], 'bind')
        self.assertTrue(pg['source'].endswith('/data/onlyoffice/postgresql'))
        self.assertIn('healthcheck', data['onlyoffice'])
        for path in self.target.glob('*.sh'):
            subprocess.run(['bash', '-n', str(path)], check=True)
        for path in self.target.glob('*.py'):
            ast.parse(path.read_text())
        self.assertFalse(list(self.target.glob('.generated.*')))

    def test_saved_env_wins_over_shell_and_rerun(self):
        self.generate()
        before = (self.target / '.env').read_bytes()
        self.generate(ok=False, SEAFILE_SERVER_HOSTNAME='wrong.example', INIT_SEAFILE_ADMIN_PASSWORD='wrong')
        self.assertEqual(before, (self.target / '.env').read_bytes())
        data = self.compose(SEAFILE_MYSQL_DB_HOST='wrong-db', REDIS_HOST='wrong-redis', ONLYOFFICE_JWT_SECRET='wrong')['services']
        self.assertEqual(data['seafile-md-server']['environment']['SEAFILE_MYSQL_DB_HOST'], 'db')
        self.assertEqual(data['onlyoffice']['environment']['JWT_SECRET'], self.values()['ONLYOFFICE_JWT_SECRET'])

    def test_https_proxy_headers_and_namespace(self):
        self.generate(EXTERNAL_REVERSE_PROXY='1', SEAFILE_SERVER_PROTOCOL='https', CONTAINER_PREFIX='pro-second')
        services = self.compose()['services']
        labels = services['onlyoffice']['labels']
        self.assertEqual(labels['seafile-pro-second.handle_path.0_reverse_proxy.header_up_2'], 'X-Forwarded-Proto https')
        self.assertFalse(any('X-Forwarded-For' in v for v in labels.values()))
        self.assertEqual(services['caddy']['environment']['CADDY_DOCKER_LABEL_PREFIX'], 'seafile-pro-second')

    def test_configure_idempotence(self):
        self.generate()
        conf = Path(self.tmp.name) / 'conf'
        conf.mkdir()
        (conf / 'seahub_settings.py').write_text('CUSTOM = 42\n')
        (conf / 'seafevents.conf').write_text('[OTHER]\nkeep=true\n')
        cmd = ['python3', str(self.target / 'configure.py'), str(conf)]
        for _ in range(2):
            subprocess.run(cmd, env=dict(self.env, **self.values()), check=True, capture_output=True)
        text = (conf / 'seahub_settings.py').read_text()
        self.assertIn('CUSTOM = 42', text)
        self.assertEqual(text.count('# BEGIN SEAFILE13_PRO MANAGED'), 1)
        self.assertEqual(len(list(conf.glob('seahub_settings.py.before-deploy-*'))), 1)
        self.assertIn('[SEASEARCH]', (conf / 'seafevents.conf').read_text())

    def test_existing_data_refused(self):
        (self.target / 'data').mkdir(parents=True)
        sentinel = self.target / 'data' / 'keep'
        sentinel.write_text('keep')
        self.generate(ok=False)
        self.assertEqual(sentinel.read_text(), 'keep')
        self.assertFalse((self.target / '.env').exists())

    def test_deployer_refuses_existing_data_before_docker(self):
        self.generate()
        (self.target / 'data').mkdir()
        r = subprocess.run(['bash', str(self.target / 'deploy.sh')], env=self.env, capture_output=True, text=True)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('仅支持首次初始化', r.stderr)
        self.assertFalse((self.target / '.operation-lock').exists())

    def test_nonempty_directory_refused(self):
        self.target.mkdir()
        keep = self.target / 'common.sh'
        keep.write_text('user content')
        self.generate(ok=False)
        self.assertEqual(keep.read_text(), 'user content')

    def test_all_persistent_mounts_under_deployment(self):
        self.generate()
        config = self.compose()
        self.assertFalse(config.get('volumes'))
        for service in config['services'].values():
            for mount in service.get('volumes', []):
                self.assertEqual(mount['type'], 'bind')
                if mount['target'] != '/var/run/docker.sock':
                    self.assertTrue(mount['source'].startswith(str(self.target / 'data') + '/'))
        self.assertFalse((self.target / 'migrate-office.sh').exists())

if __name__ == '__main__':
    unittest.main(verbosity=2)
