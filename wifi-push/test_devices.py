import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import devices
import setup_device as setup


class DeviceListTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.data = Path(self.temp.name)
        self.patches = [patch.object(devices.kp, 'DATA', self.data),
                        patch.object(devices.kp, 'CONFIG', self.data / 'config.json')]
        for p in self.patches:
            p.start()

    def tearDown(self):
        for p in self.patches:
            p.stop()
        self.temp.cleanup()

    def test_single_pairing_from_earlier_versions_is_adopted(self):
        (self.data / 'known_hosts').write_text('kindle-push ssh-ed25519 key-a\n')
        (self.data / 'config.json').write_text('{"host": "192.168.31.30"}\n')
        listed, chosen = devices.load()
        self.assertEqual(listed, [{'id': 'k1', 'name': '我的 Kindle', 'alias': 'kindle-push', 'key': 'key-a', 'host': '192.168.31.30'}])
        self.assertEqual(chosen, 'k1')
        # Adding a second Kindle keeps the first pairing byte for byte.
        devices.add('key-b', '192.168.31.40', '卧室')
        self.assertEqual((self.data / 'known_hosts').read_text(),
                         'kindle-push ssh-ed25519 key-a\nkindle-push-2 ssh-ed25519 key-b\n')
        config = json.loads((self.data / 'config.json').read_text())
        self.assertEqual(config['current'], 'k1')
        self.assertEqual(config['host'], '192.168.31.30')
        self.assertEqual([d['name'] for d in config['devices']], ['我的 Kindle', '卧室'])

    def test_several_kindles_can_be_selected(self):
        a = devices.add('key-a', '192.168.1.2')['id']
        b = devices.add('key-b', '192.168.1.3')['id']
        c = devices.add('key-c', '192.168.1.4')['id']
        # Upgrading: only the current one is selected, so nothing changes.
        self.assertEqual(devices.selected(), [a])
        self.assertEqual(devices.set_selected([c, a]), [a, c])
        self.assertEqual(devices.current()['id'], a)
        # The current one follows when it is unticked.
        devices.set_selected([c])
        self.assertEqual(devices.current()['id'], c)
        with self.assertRaises(ValueError):
            devices.set_selected([])
        with self.assertRaises(ValueError):
            devices.set_selected(['gone'])
        self.assertEqual(devices.selected(), [c])
        # Selecting while one is chosen moves the selection, as before multi-select.
        devices.update(b, select=True)
        self.assertEqual(devices.selected(), [b])
        # While several are chosen the set survives, and a host update never disturbs it.
        devices.set_selected([a, b])
        devices.update(c, host='192.168.1.9')
        self.assertEqual(devices.selected(), [a, b])
        devices.update(a, select=True)
        self.assertEqual(devices.selected(), [a, b])
        self.assertEqual(devices.current()['id'], a)
        # Forgetting a chosen Kindle leaves the rest.
        devices.forget(a)
        self.assertEqual(devices.selected(), [b])
        self.assertEqual(devices.current()['id'], b)
        self.assertTrue(devices.public(devices.find(b), b, True, [b])['selected'])

    def test_repairing_a_known_kindle_updates_it_instead_of_adding(self):
        devices.add('key-a', '192.168.1.2')
        devices.add('key-a', '192.168.1.9')
        listed, _ = devices.load()
        self.assertEqual(len(listed), 1)
        self.assertEqual(listed[0]['host'], '192.168.1.9')

    def test_select_rename_and_forget(self):
        a = devices.add('key-a', '192.168.1.2')
        b = devices.add('key-b', '192.168.1.3')
        devices.update(b['id'], select=True)
        self.assertEqual(devices.current()['id'], b['id'])
        self.assertEqual(json.loads((self.data / 'config.json').read_text())['host'], '192.168.1.3')
        devices.update(b['id'], name='  卧室   Paperwhite ')
        self.assertEqual(devices.find(b['id'])['name'], '卧室 Paperwhite')
        with self.assertRaises(ValueError):
            devices.update(b['id'], name='  ')
        devices.forget(b['id'])
        self.assertEqual(devices.current()['id'], a['id'])
        self.assertEqual((self.data / 'known_hosts').read_text(), 'kindle-push ssh-ed25519 key-a\n')
        # A new pairing reuses the freed alias, never a live one.
        c = devices.add('key-c', '192.168.1.4')
        self.assertEqual(c['alias'], 'kindle-push-2')
        devices.forget(a['id'])
        devices.forget(c['id'])
        self.assertFalse((self.data / 'known_hosts').exists())
        self.assertIsNone(devices.current())

    def test_pair_host_adds_a_second_kindle_and_saves_nothing_on_failure(self):
        (self.data / 'id_ed25519').write_text('fixture')
        devices.add('key-a', '192.168.1.2')
        scan = type('R', (), {'stdout': '192.168.1.3 ssh-ed25519 a2V5LWI=\n'})()
        with patch.object(setup.subprocess, 'run', return_value=scan), \
             patch('builtins.input', return_value='yes'), patch('builtins.print'), \
             patch.object(setup.kp, 'ssh', side_effect=OSError('no answer')):
            with self.assertRaises(OSError):
                setup.pair_host('192.168.1.3', '卧室')
        self.assertEqual([d['key'] for d in devices.load()[0]], ['key-a'])
        with patch.object(setup.subprocess, 'run', return_value=scan), \
             patch('builtins.input', return_value='yes'), patch('builtins.print'), \
             patch.object(setup.kp, 'ssh', return_value=b'kindle-push-v2\n') as ssh:
            setup.pair_host('192.168.1.3', '卧室')
        self.assertEqual(ssh.call_args.args[0]['alias'], 'kindle-push-new')
        self.assertEqual(devices.find(devices.current()['id'])['alias'], 'kindle-push-2')
        listed, chosen = devices.load()
        self.assertEqual([d['name'] for d in listed], ['我的 Kindle', '卧室'])
        self.assertEqual(chosen, listed[1]['id'])

    def test_pairing_refuses_a_key_the_user_was_not_shown(self):
        (self.data / 'id_ed25519').write_text('fixture')
        scan = type('R', (), {'stdout': '192.168.1.3 ssh-ed25519 b3RoZXI=\n'})()
        with patch.object(setup.subprocess, 'run', return_value=scan), patch.object(setup.kp, 'ssh') as ssh:
            with self.assertRaisesRegex(ValueError, '身份变了'):
                setup.pair('192.168.1.3', 'a2V5LWI=')
            ssh.assert_not_called()
        self.assertEqual(devices.load()[0], [])

    def test_kindle_volumes_reports_receiver_state(self):
        volumes = self.data / 'Volumes'
        kindle = volumes / 'Kindle'
        (kindle / 'koreader/settings/SSH').mkdir(parents=True)
        (kindle / 'documents').mkdir()
        (kindle / 'koreader/settings.reader.lua').write_text('return {\n}\n')
        (kindle / 'koreader/dropbear').write_text('x')
        (volumes / 'Other').mkdir()
        (self.data / 'id_ed25519.pub').write_text('ssh-ed25519 KEYBLOB kindle-push-macos\n')
        real = setup.Path
        with patch.object(setup, 'Path', side_effect=lambda p, *a: volumes if p == '/Volumes' else real(p, *a)):
            self.assertEqual(setup.kindle_volumes(), [{'path': str(kindle), 'name': 'Kindle', 'ready': True, 'installed': False}])
            (kindle / 'koreader/settings/SSH/kindle-receive.sh').write_text('#!/bin/sh')
            (kindle / 'koreader/settings/SSH/authorized_keys').write_text('command="x" ssh-ed25519 KEYBLOB kindle-push-macos\n')
            self.assertTrue(setup.kindle_volumes()[0]['installed'])


if __name__ == '__main__':
    unittest.main()
