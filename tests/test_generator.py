"""Offline regressions: no image pulls, daemon access or third-party Python packages."""
import ast
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'init-seafile13ce.sh'
KEYS = ('SEAFILE_', 'CADDY_', 'INIT_', 'DOCKER_', 'COMPOSE_', 'ONLYOFFICE_', 'MD_', 'THUMBNAIL_', 'REDIS_', 'JWT_', 'CONTAINER_', 'IMAGE_', 'EXTERNAL_', 'DEPLOY_', 'GENERATE_')

class GeneratorTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='seafile-ce-test-')
        self.target = Path(self.tmp.name) / 'deployment with spaces'
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(KEYS)}
        self.env.update(GENERATE_ONLY='1', SEAFILE_SERVER_HOSTNAME='files.example.test', DOCKER_COMMAND='docker', DOCKER_COMPOSE_COMMAND='docker compose', DOCKER_SOCKET='/var/run/docker.sock')

    def tearDown(self):
        self.tmp.cleanup()

    def generate(self, good=True, **env):
        r = subprocess.run(['bash', str(SCRIPT), str(self.target)], env=dict(self.env, **env), capture_output=True, text=True)
        self.assertEqual(r.returncode == 0, good, r.stderr + r.stdout)
        return r

    def values(self):
        return dict(line.split('=', 1) for line in (self.target / '.env').read_text().splitlines())

    def edit(self, **changes):
        data = self.values()
        data.update(changes)
        (self.target / '.env').write_text(''.join(f'{k}={v}\n' for k, v in data.items()))

    def compose(self):
        if not shutil.which('docker'):
            self.skipTest('Docker CLI required for Compose rendering (no daemon needed)')
        r = subprocess.run(['bash', str(self.target / 'compose.sh'), 'config', '--format', 'json'], env=self.env, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        return json.loads(r.stdout)

    def test_complete_stack_and_routes(self):
        self.generate()
        data = self.compose()
        services = data['services']
        self.assertEqual(set(services), {'db', 'redis', 'seafile', 'caddy', 'onlyoffice', 'seadoc', 'seafile-md-server', 'notification-server', 'thumbnail-server'})
        self.assertNotIn('seasearch', json.dumps(data).lower())
        self.assertIn('seafile-mc:', services['seafile']['image'])
        self.assertEqual(services['seafile']['labels']['seafile-seafile13ce.6_handle.0_reverse_proxy'], '{{upstreams 8080}}')
        self.assertEqual(services['thumbnail-server']['labels']['seafile-seafile13ce.4_handle'], '/thumbnail/*')
        self.assertEqual(services['thumbnail-server']['environment']['INNER_SEAHUB_SERVICE_URL'], 'http://seafile')
        self.assertEqual(services['seafile']['environment']['REDIS_PASSWORD'], services['redis']['environment']['REDIS_PASSWORD'])
        for name in services:
            self.assertEqual(services[name]['container_name'], 'seafile13ce-' + name)
        self.assertEqual([n for n, v in services.items() if v.get('ports')], ['caddy'])
        self.assertEqual((self.target / '.env').stat().st_mode & 0o777, 0o600)
        for path in self.target.glob('*.sh'):
            subprocess.run(['bash', '-n', str(path)], check=True)
        for path in self.target.glob('*.py'):
            ast.parse(path.read_text())

    def test_rerun_preserves_env_data_and_ignores_ambient(self):
        self.generate()
        before = (self.target / '.env').read_bytes()
        (self.target / 'data').mkdir()
        sentinel = self.target / 'data' / 'keep.txt'
        sentinel.write_text('untouched')
        self.generate(SEAFILE_SERVER_HOSTNAME='evil.example.test', CADDY_HOST_PORT='2222', INIT_SEAFILE_ADMIN_PASSWORD='changed', IMAGE_PREFIX='changed.example')
        self.assertEqual(before, (self.target / '.env').read_bytes())
        self.assertEqual(sentinel.read_text(), 'untouched')
        self.assertTrue(list((self.target / 'config-backups').glob('*/.env')))

    def test_ambient_settings_cannot_redirect_internal_services(self):
        self.generate()
        self.env.update(SEAFILE_MYSQL_DB_HOST='unrelated-db', CACHE_PROVIDER='memcached', REDIS_HOST='unrelated-cache', MD_PORT='9999', SEADOC_VOLUME='/unrelated/data', COMPOSE_FILE='/unrelated.yml')
        services = self.compose()['services']
        self.assertEqual(services['seafile-md-server']['environment']['SEAFILE_MYSQL_DB_HOST'], 'db')
        self.assertEqual(services['seafile-md-server']['environment']['REDIS_HOST'], 'redis')
        self.assertEqual(services['seafile-md-server']['environment']['MD_PORT'], '8084')
        self.assertTrue(services['seadoc']['volumes'][0]['source'].endswith('/data/seadoc'))

    def test_external_proxy_multiple_sites(self):
        self.generate(SEAFILE_SERVER_PROTOCOL='https', EXTERNAL_REVERSE_PROXY='1', CADDY_SITE='http://files.example.test,http://192.168.1.22', CADDY_HOST_PORT='28080')
        self.assertEqual(self.values()['CADDY_SITE'], 'http://files.example.test, http://192.168.1.22')
        self.assertEqual(self.values()['SEAFILE_SERVER_HOSTNAME'], 'files.example.test')
        data = self.compose()['services']
        self.assertEqual(data['caddy']['ports'][0]['target'], 80)
        self.assertEqual(data['onlyoffice']['labels']['seafile-seafile13ce.handle_path.0_reverse_proxy.header_up_2'], 'X-Forwarded-Proto https')

    def test_https_and_mirror(self):
        self.generate(SEAFILE_SERVER_PROTOCOL='https', IMAGE_PREFIX='mirror.example:5000', CONTAINER_PREFIX='ce-second')
        data = self.compose()['services']
        self.assertEqual({p['target'] for p in data['caddy']['ports']}, {80, 443})
        self.assertTrue(all(s['image'].startswith('mirror.example:5000/') for s in data.values()))
        self.assertTrue(all(s['container_name'].startswith('ce-second-') for s in data.values()))
        self.assertEqual(data['caddy']['environment']['CADDY_DOCKER_LABEL_PREFIX'], 'seafile-ce-second')
        self.assertTrue(all(k.startswith('seafile-ce-second') for v in data.values() for k in v.get('labels', {})))

    def test_invalid_inputs(self):
        for key, value in [('CADDY_HOST_PORT', '65536'), ('CADDY_HOST_PORT', '080'), ('SEAFILE_SERVER_HOSTNAME', 'https://bad'), ('DOCKER_COMPOSE_COMMAND', 'docker compose; touch /tmp/bad'), ('SEAFILE_SERVER_PROTOCOL', 'ftp'), ('CONTAINER_PREFIX', '../bad'), ('EXTERNAL_REVERSE_PROXY', '2')]:
            with self.subTest(key=key, value=value):
                self.generate(good=False, **{key: value})
                self.assertFalse((self.target / '.env').exists())
                shutil.rmtree(self.target)

    def test_missing_env_with_existing_data_rejected(self):
        (self.target / 'data').mkdir(parents=True)
        self.generate(good=False)
        self.assertFalse((self.target / '.env').exists())

    def test_lock_refuses_concurrent_operation(self):
        (self.target / '.operation-lock').mkdir(parents=True)
        self.generate(good=False)

    def test_untrusted_env_never_executes(self):
        self.generate()
        marker = Path(self.tmp.name) / 'should-not-exist'
        self.edit(TIME_ZONE=f'$(touch {marker})')
        self.generate(good=False)
        self.assertFalse(marker.exists())

    def test_pro_directory_is_rejected(self):
        self.generate()
        self.edit(DEPLOYMENT_KIND='seafile-pro', SEAFILE_IMAGE='seafileltd/seafile-pro-mc:13.0-latest')
        self.generate(good=False)

    def test_missing_and_duplicate_keys_rejected(self):
        self.generate()
        env = self.target / '.env'
        original = env.read_text()
        env.write_text(original + 'TIME_ZONE=UTC\n')
        self.generate(good=False)
        env.write_text('\n'.join(l for l in original.splitlines() if not l.startswith('REDIS_PASSWORD=')) + '\n')
        self.generate(good=False)

    def test_configuration_is_idempotent_and_preserves_custom_settings(self):
        self.generate()
        conf = Path(self.tmp.name) / 'conf'
        conf.mkdir()
        settings = conf / 'seahub_settings.py'
        settings.write_text('CUSTOM_SETTING = "keep"\n')
        (conf / 'seafdav.conf').write_text('[WEBDAV]\nenabled = false\ncustom_option = keep\n')
        env = dict(self.env, **self.values())
        cmd = [shutil.which('python3'), str(self.target / 'configure.py'), str(conf)]
        subprocess.run(cmd, env=env, check=True, capture_output=True)
        before = {p.name: p.read_bytes() for p in conf.iterdir()}
        subprocess.run(cmd, env=env, check=True, capture_output=True)
        self.assertEqual(before, {p.name: p.read_bytes() for p in conf.iterdir()})
        self.assertIn('CUSTOM_SETTING = "keep"', settings.read_text())
        self.assertIn('enabled = true', (conf / 'seafdav.conf').read_text())
        self.assertIn('custom_option = keep', (conf / 'seafdav.conf').read_text())
        namespace = {}
        exec(compile(settings.read_text(), str(settings), 'exec'), namespace)
        self.assertTrue(namespace['ENABLE_VIDEO_THUMBNAIL'])
        self.assertTrue(namespace['ENABLE_METADATA_MANAGEMENT'])
        self.assertEqual(namespace['SERVICE_URL'], 'http://files.example.test:28080')

if __name__ == '__main__':
    unittest.main(verbosity=2)
