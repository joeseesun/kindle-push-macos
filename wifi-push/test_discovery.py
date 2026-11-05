import unittest
from unittest.mock import patch
from types import SimpleNamespace
import app_bridge as bridge


class DiscoveryTests(unittest.TestCase):
    def device(self, id, host=''):
        return {'id': id, 'name': id.upper(), 'alias': 'kindle-push', 'key': 'key-' + id, 'host': host}

    def test_reach_never_changes_the_selection_and_finds_a_moved_kindle(self):
        device = self.device('k2', '192.168.1.3')
        def verify(host, expected, select=True):
            self.assertFalse(select)
            if host == '192.168.1.9':
                return host, device
            raise ValueError('gone')
        with patch.object(bridge, 'verify', side_effect=verify), \
             patch.object(bridge, 'scan', return_value={'k2': '192.168.1.9'}):
            self.assertEqual(bridge.reach(device)[0], '192.168.1.9')

    def test_away_kindle_is_reported_so_the_others_can_go_ahead(self):
        device = self.device('k2', '192.168.1.3')
        with patch.object(bridge, 'verify', side_effect=ValueError('gone')), \
             patch.object(bridge, 'scan', return_value={}), \
             patch.object(bridge.dv, 'find', return_value=device):
            result = bridge.handle(['send', '', '/tmp/book.epub', 'k2'])
        self.assertEqual((result['ok'], result['state']), (False, 'away'))
        self.assertIn('K2', result['message'])

    def test_discover_stays_within_the_kindles_ticked(self):
        known = [self.device('k1'), self.device('k2'), self.device('k3')]
        seen = {}
        def scan(devices):
            seen['ids'] = [d['id'] for d in devices]
            return {'k3': '192.168.1.4'}
        with patch.object(bridge, 'paired', return_value=known), \
             patch.object(bridge.dv, 'current', return_value=known[0]), \
             patch.object(bridge.dv, 'selected', return_value=['k1', 'k2']), \
             patch.object(bridge.dv, 'update'), \
             patch.object(bridge, 'scan', side_effect=scan):
            with self.assertRaises(ValueError):
                bridge.discover()
        self.assertEqual(seen['ids'], ['k1', 'k2'])

    def test_status_reads_saved_host(self):
        # Regression: a local named `config` in handle() shadowed config() and broke every status call.
        with patch.object(bridge, 'config', return_value={'host': '192.168.1.42'}), \
             patch.object(bridge.dv, 'current', return_value=None), \
             patch.object(bridge.Path, 'exists', return_value=True):
            self.assertEqual(bridge.handle(['status'])['host'], '192.168.1.42')

    def test_handle_has_no_local_shadowing_module_functions(self):
        local_names = bridge.handle.__code__.co_varnames
        for name in ['config', 'valid_host', 'paired', 'reachable', 'verify', 'discover', 'scan', 'select', 'connected', 'identify']:
            self.assertNotIn(name, local_names)

    A = {'id': 'k1', 'name': '我的 Kindle', 'alias': 'kindle-push', 'key': 'key-a', 'host': '192.168.1.10'}
    B = {'id': 'k2', 'name': '卧室', 'alias': 'kindle-push-2', 'key': 'key-b', 'host': '192.168.1.20'}

    def test_both_receiver_versions_are_accepted(self):
        for version in [b'kindle-push-v1\n', b'kindle-push-v2\n']:
            with patch.object(bridge, 'reachable', return_value=True), \
                 patch.object(bridge, 'paired', return_value=[self.A]), \
                 patch.object(bridge, 'host_key', return_value='key-a'), \
                 patch.object(bridge.kp, 'ssh', return_value=version), \
                 patch.object(bridge.dv, 'update'):
                self.assertEqual(bridge.verify('192.168.1.42'), ('192.168.1.42', self.A))
        with patch.object(bridge, 'reachable', return_value=True), \
             patch.object(bridge, 'paired', return_value=[self.A]), \
             patch.object(bridge, 'host_key', return_value='key-a'), \
             patch.object(bridge.kp, 'ssh', return_value=b'something-else\n'):
            with self.assertRaisesRegex(ValueError, '没有正常响应'):
                bridge.verify('192.168.1.42')

    def test_verify_uses_the_matching_devices_host_key_alias(self):
        with patch.object(bridge, 'reachable', return_value=True), \
             patch.object(bridge, 'paired', return_value=[self.A, self.B]), \
             patch.object(bridge, 'host_key', return_value='key-b'), \
             patch.object(bridge.kp, 'ssh', return_value=b'kindle-push-v2\n') as ssh, \
             patch.object(bridge.dv, 'update') as update:
            host, device = bridge.verify('192.168.1.77')
        self.assertEqual(device['id'], 'k2')
        self.assertEqual(ssh.call_args.args[0], {'host': '192.168.1.77', 'alias': 'kindle-push-2'})
        update.assert_called_once_with('k2', host='192.168.1.77', select=True)

    def test_send_to_one_kindle_never_reaches_another(self):
        refused = bridge.subprocess.CalledProcessError(255, 'ssh', stderr=b'Host key verification failed.\r\n')
        with patch.object(bridge, 'reachable', return_value=True), \
             patch.object(bridge, 'paired', return_value=[self.A, self.B]), \
             patch.object(bridge, 'host_key') as scan, \
             patch.object(bridge.kp, 'ssh', side_effect=refused) as ssh, \
             patch.object(bridge.dv, 'update') as update:
            with self.assertRaisesRegex(ValueError, '不一致'):
                bridge.verify('192.168.1.20', 'k2')
        # Pinned by SSH itself: no separate scan, and the handshake used k2's alias.
        scan.assert_not_called()
        self.assertEqual(ssh.call_args.args[0]['alias'], 'kindle-push-2')
        update.assert_not_called()

    def test_a_slow_kindle_is_retried_not_reported_as_another_device(self):
        with patch.object(bridge, 'reachable', return_value=True), \
             patch.object(bridge, 'paired', return_value=[self.A]), \
             patch.object(bridge.kp, 'ssh', side_effect=[bridge.subprocess.CalledProcessError(255, 'ssh', stderr=b'Connection timed out'),
                                                         b'kindle-push-v2\n']), \
             patch.object(bridge.dv, 'update'):
            self.assertEqual(bridge.verify('192.168.1.10', 'k1')[1]['id'], 'k1')
        with patch.object(bridge, 'reachable', return_value=True), \
             patch.object(bridge, 'paired', return_value=[self.A]), \
             patch.object(bridge.kp, 'ssh', side_effect=bridge.subprocess.CalledProcessError(255, 'ssh', stderr=b'timed out')):
            with self.assertRaisesRegex(ValueError, '暂时没有响应'):
                bridge.verify('192.168.1.10', 'k1')
        with patch.object(bridge, 'reachable', return_value=True), \
             patch.object(bridge, 'paired', return_value=[self.A]), \
             patch.object(bridge, 'host_key', return_value=None), \
             patch.object(bridge.kp, 'ssh') as ssh:
            with self.assertRaisesRegex(ValueError, '暂时没有响应'):
                bridge.verify('192.168.1.10')
            ssh.assert_not_called()

    def test_cached_address_failure_falls_back_to_identified_device(self):
        with patch.object(bridge, 'paired', return_value=[self.A]), \
             patch.object(bridge.dv, 'current', return_value=self.A), \
             patch.object(bridge.dv, 'update'), \
             patch.object(bridge, 'local_candidates', return_value=['192.168.8.12', '192.168.8.24']), \
             patch.object(bridge, 'reachable', return_value=True), \
             patch.object(bridge, 'host_key', side_effect=lambda host: 'key-a' if host == '192.168.8.24' else 'other'), \
             patch.object(bridge, 'verify', side_effect=[ValueError('old network'), ('192.168.8.24', self.A)]) as verify:
            self.assertEqual(bridge.discover(), ('192.168.8.24', self.A))
            self.assertEqual(verify.call_args.args, ('192.168.8.24', 'k1'))

    def test_discover_prefers_the_chosen_kindle_then_falls_back_to_another(self):
        hosts = {'192.168.8.5': 'key-a', '192.168.8.6': 'key-b'}
        with patch.object(bridge, 'paired', return_value=[self.A, self.B]), \
             patch.object(bridge.dv, 'current', return_value=dict(self.B, host='')), \
             patch.object(bridge.dv, 'update'), \
             patch.object(bridge, 'local_candidates', return_value=list(hosts)), \
             patch.object(bridge, 'reachable', return_value=True), \
             patch.object(bridge, 'host_key', side_effect=hosts.get), \
             patch.object(bridge, 'verify', side_effect=lambda host, i: (host, i)) as verify:
            self.assertEqual(bridge.discover(), ('192.168.8.6', 'k2'))
        with patch.object(bridge, 'paired', return_value=[self.A, self.B]), \
             patch.object(bridge.dv, 'current', return_value=dict(self.B, host='')), \
             patch.object(bridge.dv, 'update'), \
             patch.object(bridge, 'local_candidates', return_value=['192.168.8.5']), \
             patch.object(bridge, 'reachable', return_value=True), \
             patch.object(bridge, 'host_key', side_effect=hosts.get), \
             patch.object(bridge, 'verify', side_effect=lambda host, i: (host, i)):
            self.assertEqual(bridge.discover(), ('192.168.8.5', 'k1'))

    def test_fallback_to_another_kindle_is_announced(self):
        with patch.object(bridge.dv, 'current', return_value=self.B), \
             patch.object(bridge, 'discover', return_value=('192.168.1.10', self.A)):
            result = bridge.handle(['discover'])
        self.assertEqual(result['deviceId'], 'k1')
        self.assertIn('「卧室」不在这个 Wi-Fi 里，已改为发到「我的 Kindle」', result['message'])
        with patch.object(bridge.dv, 'current', return_value=self.A), \
             patch.object(bridge, 'discover', return_value=('192.168.1.10', self.A)):
            self.assertEqual(bridge.handle(['discover'])['message'], 'Kindle 已连接')

    def test_unrelated_ssh_service_is_never_authenticated(self):
        with patch.object(bridge, 'paired', return_value=[self.A]), \
             patch.object(bridge.dv, 'current', return_value=dict(self.A, host='')), \
             patch.object(bridge, 'local_candidates', return_value=['192.168.8.12']), \
             patch.object(bridge, 'reachable', return_value=True), \
             patch.object(bridge, 'host_key', return_value='unrelated'), \
             patch.object(bridge, 'verify') as verify:
            with self.assertRaisesRegex(ValueError, '未找到'):
                bridge.discover()
            verify.assert_not_called()

    def test_identity_mismatch_prevents_authenticated_connection(self):
        with patch.object(bridge, 'reachable', return_value=True), \
             patch.object(bridge, 'paired', return_value=[self.A]), \
             patch.object(bridge, 'host_key', return_value='unrelated'), \
             patch.object(bridge.kp, 'ssh') as ssh:
            with self.assertRaisesRegex(ValueError, '不一致'):
                bridge.verify('192.168.8.12')
            ssh.assert_not_called()

    def test_large_network_scan_is_bounded_and_excludes_vpn(self):
        interfaces = '''en0: flags=1
 inet 192.168.8.31 netmask 0xffff0000 broadcast 192.168.255.255
 status: active
utun4: flags=1
 inet 10.9.0.1 netmask 0xffffff00
 status: active
en1: flags=1
 inet 172.16.1.2 netmask 0xffffff00
 status: inactive
'''
        arp = '? (192.168.12.5) at 00:11:22:33:44:55 on en0\n? (10.9.0.2) at xx on utun4\n'
        with patch.object(bridge.subprocess, 'run', side_effect=[SimpleNamespace(stdout=interfaces), SimpleNamespace(stdout=arp)]):
            hosts = bridge.local_candidates()
        self.assertEqual(len(hosts), 254)
        self.assertIn('192.168.12.5', hosts)
        self.assertNotIn('192.168.8.31', hosts)
        self.assertNotIn('10.9.0.2', hosts)
        self.assertNotIn('172.16.1.3', hosts)

    def test_invalid_and_public_addresses_are_rejected(self):
        for host in ['8.8.8.8', '127.0.0.1', '0.0.0.0', '::1', '-oProxyCommand=bad', '192.168.1.1;echo bad']:
            with self.subTest(host=host), self.assertRaises(ValueError):
                bridge.valid_host(host)


if __name__ == '__main__':
    unittest.main()
