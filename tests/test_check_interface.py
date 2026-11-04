# Copyright (c) 2026 TheMizeGuy. All rights reserved.
import contextlib
import io
from pathlib import Path
import runpy
import unittest

SCRIPTS = Path(__file__).resolve().parents[1] / 'scripts'
check_interface = runpy.run_path(str(SCRIPTS / 'check-interface.py'))
HEADER = ('Region!STRING:0|BuildConfig!HEX:16|CDNConfig!HEX:16|KeyRing!HEX:16|BuildId!DEC:4|'
          'VersionsName!String:0|ProductConfig!HEX:16\n## seqn = 4115537\n')
LIVE = {'wow': '12.1.5.70783', 'wow_classic': '5.5.4.70631', 'wow_anniversary': '2.5.6.70577',
        'wow_classic_era': '1.15.9.70576', 'wowf': '1.60.1.70755'}


def response(us, eu=None):
    rows = [('eu', eu or us), ('us', us)]
    return HEADER + ''.join(f'{region}|bc49|483b||{version.split(".")[-1]}|{version}|5302\n' for region, version in rows)


class CheckInterfaceTest(unittest.TestCase):
    def setUp(self):
        self.urls = []
        self.tocs = check_interface['flavor_tocs']()

    def fetcher(self, versions):
        def fetch(url):
            self.urls.append(url)
            product = url.split('/')[-2]
            value = versions[product]
            if isinstance(value, Exception):
                raise value
            return value
        return fetch

    def test_current_live_builds_are_declared_by_every_manifest(self):
        results = check_interface['check'](self.fetcher({p: response(v) for p, v in LIVE.items()}), self.tocs)
        self.assertEqual([ok for ok, _ in results], [True] * 5)
        self.assertEqual(self.urls, [f'https://us.version.battle.net/{p}/versions' for p in LIVE])
        self.assertIn('wow 12.1.5.70783: interface 120105 OK in TwitchEmotes_Mainline.toc, TwitchEmotes.toc', results[0][1])
        self.assertIn('wowf 1.60.1.70755: interface 16001 OK', results[4][1])
        self.assertIn('TwitchEmotes_Camelot.toc', results[4][1])

    def test_a_client_patch_names_every_stale_manifest(self):
        versions = {p: response(v) for p, v in LIVE.items()}
        versions['wow'] = response('12.2.0.71000')
        results = check_interface['check'](self.fetcher(versions), self.tocs)
        self.assertEqual([ok for ok, _ in results], [False, True, True, True, True])
        self.assertEqual(results[0][1],
                         'wow 12.2.0.71000: interface 120200 MISSING from TwitchEmotes_Mainline.toc, TwitchEmotes.toc')

    def test_only_the_us_row_counts_whatever_the_column_order(self):
        text = ('VersionsName!String:0|Region!STRING:0|BuildId!DEC:4\n'
                '1.15.10.71000|eu|71000\n1.15.9.70576|us|70576\n')
        self.assertEqual(check_interface['live_version'](text), '1.15.9.70576')
        self.assertEqual(check_interface['interface_number']('1.15.9.70576'), 11509)
        self.assertEqual(check_interface['interface_number']('5.5.4.70631'), 50504)

    def test_an_unreadable_product_fails_without_hiding_the_others(self):
        versions = {p: response(v) for p, v in LIVE.items()}
        versions['wow_classic'] = OSError('connection refused')
        versions['wow_anniversary'] = HEADER + 'eu|bc49|483b||70577|2.5.6.70577|5302\n'
        versions['wow_classic_era'] = HEADER + 'us|bc49|483b||70576|1.15|5302\n'
        results = check_interface['check'](self.fetcher(versions), self.tocs)
        self.assertEqual([ok for ok, _ in results], [True, False, False, False, True])
        self.assertIn('connection refused', results[1][1])
        self.assertIn('no us version', results[2][1])

    def test_manifests_come_from_package_flavor_tocs(self):
        self.assertEqual(self.tocs['TwitchEmotes_Mists.toc'], '50504')
        for manifests in check_interface['PRODUCTS'].values():
            for name in manifests + (check_interface['FALLBACK'],):
                self.assertIn(name, self.tocs)

    def test_main_prints_one_line_per_product_and_sets_the_exit_code(self):
        versions = {p: response(v) for p, v in LIVE.items()}
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertEqual(check_interface['main'](self.fetcher(versions)), 0)
        self.assertEqual(len(output.getvalue().splitlines()), 5)
        versions['wowf'] = response('1.61.0.71000')
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(check_interface['main'](self.fetcher(versions)), 1)


if __name__ == '__main__':
    unittest.main()
