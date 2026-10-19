#!/usr/bin/env python3
"""Keep manually extracted Run UI keys and Japanese/English resources aligned."""
import json
from pathlib import Path
import re
import unittest
ROOT = Path(__file__).resolve().parents[1]

class RunLocalizationTests(unittest.TestCase):
    def test_catalog_and_all_literal_ui_keys(self):
        catalog = json.loads((ROOT / 'CotEditor/Localizables/Document Window/Run.xcstrings').read_text())
        keys = set(catalog['strings'])
        source = '\n'.join(p.read_text() for p in (ROOT / 'CotEditor/Sources/Run').glob('*.swift'))
        references = set(re.findall(r'(?:runText|fail)\("([A-Za-z]+)"\)', source))
        # Keys selected by ternaries/menu records are deliberately manual.
        references |= {'Run','Stop','ShowResults','Stdin','Stdout','Stderr','ChoosePython','ChooseJDK','InputOpen','InputClosed'}
        self.assertFalse(references - keys)
        for key in keys:
            for language in ('ja', 'en'):
                unit = catalog['strings'][key]['localizations'][language]['stringUnit']
                self.assertEqual(unit['state'], 'translated')
                self.assertTrue(unit['value'].strip(), (key, language))
        for key, japanese in {'Run':'実行','Stop':'停止','Stdin':'標準入力','Stdout':'標準出力','Stderr':'標準エラー'}.items():
            self.assertEqual(catalog['strings'][key]['localizations']['ja']['stringUnit']['value'], japanese)
    def test_no_semantic_or_telemetry_dependency(self):
        source = '\n'.join(p.read_text() for p in (ROOT / 'CotEditor/Sources/Run').glob('*.swift'))
        self.assertNotIn('ForkUsageMetrics', source)
        self.assertNotIn('SemanticCompletionController', source)
        self.assertNotIn('CopilotCompletionController', source)
        self.assertNotIn('Process.terminate', source)

if __name__ == '__main__': unittest.main(verbosity=2)
