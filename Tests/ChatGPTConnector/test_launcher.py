import importlib.util
from pathlib import Path
import shlex
import unittest

spec = importlib.util.spec_from_file_location('connector', Path(__file__).resolve().parents[2] / 'scripts/connect-chatgpt.py')
connector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(connector)

class ConnectorTests(unittest.TestCase):
    def test_command_path_with_spaces_and_metacharacters_is_one_argument(self):
        bridge = '/tmp/App CAD/$do-not-expand/ftk-mcp'
        cmd = connector.command('configure', 'tunnel-client', bridge, 'tunnel_0123456789abcdef')
        self.assertEqual(shlex.split(cmd[-1]), [bridge])
        self.assertNotIn('CONTROL_PLANE_API_KEY', ' '.join(cmd))
    def test_invalid_tunnel_rejected(self):
        for value in [None, '', 'http://host', 'tunnel_1; echo fail']:
            with self.assertRaises(ValueError):
                connector.command('configure', 'tunnel-client', '/bridge', value)
    def test_diagnostic_and_runtime_use_same_profile(self):
        self.assertEqual(connector.command('doctor', 'tc', '/bridge'), ['tc','doctor','--profile','fusion-takeoff','--explain'])
        self.assertEqual(connector.command('run', 'tc', '/bridge'), ['tc','run','--profile','fusion-takeoff'])

if __name__ == '__main__':
    unittest.main()
