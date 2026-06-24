import json
import unittest
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from tests.test_runtime import _test_config
from par_runtime import Runtime


class TestSkillRegistration(unittest.TestCase):
    def test_register_and_list_skill(self):
        with Runtime(_test_config()) as rt:
            rt.register_skill(json.dumps({
                "schema_version": 1,
                "id": "unit-test-skill",
                "name": "Unit Test",
                "description": "A skill for unit testing."
            }))
            skills = rt.list_skills()
            ids = [s["id"] for s in skills]
            self.assertIn("unit-test-skill", ids)

    def test_list_empty_initially(self):
        with Runtime(_test_config()) as rt:
            skills = rt.list_skills()
            self.assertIsInstance(skills, list)

    def test_register_multiple_skills(self):
        with Runtime(_test_config()) as rt:
            for i in range(3):
                rt.register_skill(json.dumps({
                    "schema_version": 1,
                    "id": f"skill-{i}",
                    "name": f"Skill {i}",
                    "description": f"Test skill number {i}."
                }))
            skills = rt.list_skills()
            ids = {s["id"] for s in skills}
            self.assertIn("skill-0", ids)
            self.assertIn("skill-1", ids)
            self.assertIn("skill-2", ids)

    def test_skill_descriptor_fields(self):
        with Runtime(_test_config()) as rt:
            rt.register_skill(json.dumps({
                "schema_version": 1,
                "id": "field-test",
                "name": "Field Test",
                "description": "Testing descriptor fields."
            }))
            skills = rt.list_skills()
            match = [s for s in skills if s["id"] == "field-test"]
            self.assertEqual(len(match), 1)
            s = match[0]
            self.assertEqual(s["id"], "field-test")
            self.assertEqual(s["name"], "Field Test")
            self.assertIn("description", s)


if __name__ == "__main__":
    unittest.main()
