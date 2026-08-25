import importlib.util
import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "ci/aggregate_ci.py"
MODULE = None
if SCRIPT.is_file():
    SPEC = importlib.util.spec_from_file_location("aggregate_ci", SCRIPT)
    assert SPEC is not None and SPEC.loader is not None
    MODULE = importlib.util.module_from_spec(SPEC)
    sys.modules[SPEC.name] = MODULE
    SPEC.loader.exec_module(MODULE)


def environment(*, lane="product", image_required=True, image="success", draft=False):
    target_required = lane == "product"
    classification = {
        "schema": 1,
        "lane": lane,
        "image_required": image_required,
        "target_required": target_required,
        "reasons": ["test classification"],
    }
    return {
        "EVENT_NAME": "pull_request",
        "PR_DRAFT": str(draft).lower(),
        "SCOPE_RESULT": "success",
        "LANE": lane,
        "IMAGE_REQUIRED": str(image_required).lower(),
        "TARGET_REQUIRED": str(target_required).lower(),
        "CLASSIFICATION": json.dumps(classification),
        "ROOT_RESULT": "success",
        "SHELL_RESULT": "success",
        "IMAGE_RESULT": image,
    }


@unittest.skipUnless(
    MODULE is not None,
    "the Python CI aggregate has migrated to Flash",
)
class AggregateTests(unittest.TestCase):
    def test_product_lane_requires_successful_image_work(self):
        result = MODULE.parse(environment())
        MODULE.enforce(result)
        for image in ("skipped", "failure", "cancelled"):
            with self.subTest(image=image):
                with self.assertRaises(MODULE.AggregateError):
                    MODULE.enforce(MODULE.parse(environment(image=image)))

    def test_fast_lane_requires_a_controlled_image_skip(self):
        MODULE.enforce(
            MODULE.parse(
                environment(lane="fast", image_required=False, image="skipped")
            )
        )
        with self.assertRaisesRegex(MODULE.AggregateError, "contrary"):
            MODULE.enforce(
                MODULE.parse(
                    environment(lane="fast", image_required=False, image="success")
                )
            )

    def test_draft_product_pr_may_defer_the_image(self):
        MODULE.enforce(MODULE.parse(environment(image="skipped", draft=True)))

    def test_manual_product_run_cannot_skip_the_image(self):
        values = environment(image="skipped", draft=True)
        values["EVENT_NAME"] = "workflow_dispatch"
        with self.assertRaisesRegex(MODULE.AggregateError, "requires successful"):
            MODULE.enforce(MODULE.parse(values))

    def test_failed_source_or_classifier_gate_is_rejected(self):
        for key in ("SCOPE_RESULT", "ROOT_RESULT", "SHELL_RESULT"):
            with self.subTest(key=key):
                values = environment()
                values[key] = "failure"
                with self.assertRaises(MODULE.AggregateError):
                    MODULE.enforce(MODULE.parse(values))

    def test_payload_and_job_outputs_must_agree(self):
        values = environment()
        values["LANE"] = "fast"
        with self.assertRaisesRegex(MODULE.AggregateError, "disagree"):
            MODULE.parse(values)


if __name__ == "__main__":
    unittest.main()
