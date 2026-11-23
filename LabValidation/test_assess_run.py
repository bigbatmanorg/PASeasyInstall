import json
import tempfile
import unittest
from pathlib import Path
from assess_run import assess


class RunAssessmentTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.config = {
            'security': {'profile': 'Lab'},
            'activeDirectory': {'mode': 'None', 'join': []},
            'components': [
                {'id': 'vault', 'type': 'Vault'},
                {'id': 'dr', 'type': 'DRVault'},
                {'id': 'pvwa01', 'type': 'PVWA'},
                {'id': 'gw01', 'type': 'HTML5GW'},
                {'id': 'pta01', 'type': 'PTA'},
            ],
        }
        self.write('config.json', self.config)
        self.write('run.json', {'id': 'a' * 32, 'status': 'Succeeded', 'message': 'PRIVATE SHOULD NOT COPY'})

    def write(self, path, content):
        file = self.root / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(json.dumps(content), encoding='utf-8')

    def complete(self):
        for name in ('primary', 'primary_final', 'dr', 'dr_final', 'pvwa01', 'gw01', 'register-gw01', 'pta01', 'trust-pta01'):
            self.write(name + '/state.json', {'status': 'Succeeded'})

    def test_requires_dr_final_and_integration_targets(self):
        self.complete()
        result = assess(self.root)
        self.assertTrue(result['workflowComplete'])
        self.assertEqual(result['functionalAcceptance'], 'NOT_ASSESSED')
        self.assertEqual(result['scenarioResult'], 'NOT_ASSESSED')
        self.assertNotIn('PRIVATE SHOULD NOT COPY', json.dumps(result))
        self.write('dr_final/state.json', {'status': 'Running'})
        result = assess(self.root)
        self.assertFalse(result['workflowComplete'])
        self.assertIn('Not succeeded: dr_final [Running]', result['issues'])
        self.write('dr_final/state.json', {'status': 'Succeeded'})
        (self.root / 'register-gw01/state.json').unlink()
        self.assertFalse(assess(self.root)['workflowComplete'])

    def test_does_not_trust_component_success_after_controller_abandon(self):
        self.complete()
        self.write('run.json', {'id': 'a' * 32, 'status': 'Abandoned'})
        self.assertFalse(assess(self.root)['workflowComplete'])


if __name__ == '__main__':
    unittest.main()
