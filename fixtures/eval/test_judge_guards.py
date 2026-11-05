"""Conservative aggregation and exact preservation must not depend on model opinion."""

import unittest

from evaluation.judge_guards import conservative
from evaluation.records import ROOT, read_json
from evaluation.tasks import code_judgment, task_for
from test_pipeline import case, judgment


class JudgeGuardTests(unittest.TestCase):
    def setUp(self):
        self.rubric = read_json(ROOT / "rubric.json")

    def test_grouped_spelling_fix_cannot_hide_added_final_blank_lines(self):
        task = task_for(
            case(input="end of the mounth", expected="end of the month"), "end of the month\n\n", self.rubric
        )
        original = judgment(task)
        guarded, changes = conservative(original, task)
        self.assertEqual(guarded["edits"][0]["verdict"], "harmful")
        self.assertEqual(guarded["fully_correct"], "no")
        self.assertEqual(guarded["faithful"], "no")
        self.assertEqual(original["fully_correct"], "yes")
        self.assertTrue(changes)

    def test_uncertain_edit_cannot_receive_an_unqualified_whole_answer_pass(self):
        task = task_for(case(), "the feline is here", self.rubric)
        guarded, _ = conservative(judgment(task, "uncertain"), task)
        self.assertEqual(guarded["fully_correct"], "uncertain")

    def test_unchanged_draft_cannot_have_a_required_reference_edit_satisfied(self):
        c = case()
        task = task_for(c, c["input"], self.rubric)
        guarded, _ = conservative(judgment(task), task)
        self.assertEqual(guarded["misses"][0]["verdict"], "missed")
        self.assertEqual(guarded["fully_correct"], "no")
        self.assertEqual(guarded["faithful"], "yes")

    def test_reference_acceptance_does_not_establish_necessity(self):
        c = case(input="avc toi", expected="avec toi", lang="fr")
        self.assertIsNone(code_judgment(task_for(c, c["expected"], self.rubric)))
        self.assertIsNone(code_judgment(task_for(c, c["input"], self.rubric)))


if __name__ == "__main__":
    unittest.main()
