import importlib.machinery
import importlib.util
import unittest
from datetime import datetime, timezone
from pathlib import Path

PATH = Path(__file__).resolve().parent.parent / "collectors" / "agent-usage-agy"
loader = importlib.machinery.SourceFileLoader("agent_usage_agy", str(PATH))
spec = importlib.util.spec_from_loader("agent_usage_agy", loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)

REAL = (
  "Quota:\r\n"
  "Gemini Models          Weekly Limit Remaining     83%  2026-12-03 15:14 GMT\r\n"
  "Gemini Models          Five Hour Limit Remaining  33%  2026-11-26 20:14 GMT\r\n"
  "Claude and GPT models  Weekly Limit Remaining     88%  2026-12-02 21:51 GMT\r\n"
  "Claude and GPT models  Five Hour Limit Remaining  82%  2026-11-26 22:54 GMT\r\n"
)
ISO = (
  "Gemini Models  Weekly 83% remaining resets 2026-12-03T15:14:26Z\n"
  "Gemini Models  Five Hour 33% remaining resets 2026-11-26T20:14:26Z\n"
)


class ParserTests(unittest.TestCase):
  def test_real_table(self):
    out = mod.parse_agy_quota_output(REAL)
    self.assertEqual([l["title"] for l in out], ["Session", "Weekly"])
    self.assertEqual(out[0], {"label": "Session (5-hour)", "title": "Session", "percent": 0.67, "resetsAt": "2026-11-26T20:14:00Z"})
    self.assertEqual(out[1], {"label": "Weekly (7-day)", "title": "Weekly", "percent": 0.17, "resetsAt": "2026-12-03T15:14:00Z"})

  def test_iso_variant_with_refinement(self):
    out = mod.parse_agy_quota_output(ISO, [{"percent": 0.6703, "resetsAt": "2026-11-26T20:14:26Z"}])
    self.assertEqual(out[0], {"label": "Session (5-hour)", "title": "Session", "percent": 0.6703, "resetsAt": "2026-11-26T20:14:26Z"})
    self.assertEqual(out[1], {"label": "Weekly (7-day)", "title": "Weekly", "percent": 0.17, "resetsAt": "2026-12-03T15:14:26Z"})

  def test_claude_gpt_ignored(self):
    text = (
      "Claude and GPT models  Weekly Limit Remaining  90%  1970-01-01 00:00 GMT\n"
      "Claude and GPT models  Five Hour Limit Remaining  90%  2026-11-26 22:54 GMT\n"
      "Claude Weekly 50% remaining resets 2026-12-02T21:51:00Z\n"
    )
    self.assertEqual(mod.parse_agy_quota_output(text), [])
    self.assertEqual(len(mod.parse_agy_quota_output(REAL + text)), 2)

  def test_empty(self):
    self.assertEqual(mod.parse_agy_quota_output(""), [])
    self.assertEqual(mod.parse_agy_quota_output(None), [])


class ModelLimitsTests(unittest.TestCase):
  def test_horizon_classification(self):
    now = datetime(2026, 11, 26, 18, 0, 0, tzinfo=timezone.utc)
    data = {"models": {
      "gemini-a": {"quotaInfo": {"remainingFraction": 0.33, "resetTime": "2026-11-26T20:14:26Z"}},
      "gemini-b": {"quotaInfo": {"remainingFraction": 0.83, "resetTime": "2026-12-03T15:14:26Z"}},
      "claude-x": {"quotaInfo": {"remainingFraction": 0.1, "resetTime": "2026-11-26T20:14:26Z"}},
    }}
    out = mod.gemini_model_limits(data, now=now)
    self.assertEqual([l["title"] for l in out], ["Session", "Weekly"])
    self.assertEqual(out[0]["label"], "Session (5-hour)")
    self.assertEqual(out[0]["percent"], 0.67)
    self.assertEqual(out[1]["label"], "Weekly (7-day)")
    self.assertEqual(out[1]["percent"], 0.17)

  def test_only_short_reset_is_session(self):
    now = datetime(2026, 11, 26, 18, 0, 0, tzinfo=timezone.utc)
    data = {"models": {"gemini-a": {"quotaInfo": {"remainingFraction": 0.33, "resetTime": "2026-11-26T20:14:26Z"}}}}
    out = mod.gemini_model_limits(data, now=now)
    self.assertEqual([l["title"] for l in out], ["Session"])


if __name__ == "__main__":
  unittest.main()
