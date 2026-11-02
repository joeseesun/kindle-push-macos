import unittest
from unittest.mock import patch
from types import SimpleNamespace
import app_bridge as bridge


class DiscoveryTests(unittest.TestCase):
    def test_both_receiver_versions_are_accepted(self):
        for version in [b'kindle-push-v1\n', b'kindle-push-v2\n']:
            with patch.object(bridge, 'reachable', return_value=True), \
                 patch.object(bridge, 'trusted_key', return_value='paired-key'), \
                 patch.object(bridge, 'matches_device', return_value=True), \
                 patch.object(bridge.kp, 'ssh', return_value=version), \
                 patch.object(bridge.kp, 'get_config'):
                self.assertEqual(bridge.verify('192.168.1.42'), '192.168.1.42')
        with patch.object(bridge, 'reachable', return_value=True), \
             patch.object(bridge, 'trusted_key', return_value='paired-key'), \
             patch.object(bridge, 'matches_device', return_value=True), \
             patch.object(bridge.kp, 'ssh', return_value=b'something-else\n'):
            with self.assertRaisesRegex(ValueError, '没有正常响应'):
                bridge.verify('192.168.1.42')

    def test_cached_address_failure_falls_back_to_identified_device(self):
        with patch.object(bridge, 'trusted_key', return_value='paired-key'), \
             patch.object(bridge, 'config', return_value={'host': '192.168.1.10'}), \
             patch.object(bridge, 'local_candidates', return_value=['192.168.8.12', '192.168.8.24']), \
             patch.object(bridge, 'reachable', return_value=True), \
             patch.object(bridge, 'matches_device', side_effect=lambda host, key: host == '192.168.8.24'), \
             patch.object(bridge, 'verify', side_effect=[ValueError('old network'), '192.168.8.24']) as verify:
            self.assertEqual(bridge.discover(), '192.168.8.24')
            self.assertEqual(verify.call_args.args, ('192.168.8.24',))

    def test_unrelated_ssh_service_is_never_authenticated(self):
        with patch.object(bridge, 'trusted_key', return_value='paired-key'), \
             patch.object(bridge, 'config', return_value={}), \
             patch.object(bridge, 'local_candidates', return_value=['192.168.8.12']), \
             patch.object(bridge, 'reachable', return_value=True), \
             patch.object(bridge, 'matches_device', return_value=False), \
             patch.object(bridge, 'verify') as verify:
            with self.assertRaisesRegex(ValueError, '未找到'):
                bridge.discover()
            verify.assert_not_called()

    def test_identity_mismatch_prevents_authenticated_connection(self):
        with patch.object(bridge, 'reachable', return_value=True), \
             patch.object(bridge, 'trusted_key', return_value='paired-key'), \
             patch.object(bridge, 'matches_device', return_value=False), \
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
