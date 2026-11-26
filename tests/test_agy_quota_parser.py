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
    self.assertEqual([l["title"] for l in out], ["Session", "Weekly", "Session", "Weekly"])
    self.assertEqual([bool(l.get("group")) for l in out], [False, False, True, True])
    self.assertEqual(out[0], {"label": "Session (5-hour)", "title": "Session", "percent": 0.67, "resetsAt": "2026-11-26T20:14:00Z"})
    self.assertEqual(out[1], {"label": "Weekly (7-day)", "title": "Weekly", "percent": 0.17, "resetsAt": "2026-12-03T15:14:00Z"})

  def test_iso_variant_with_refinement(self):
    out = mod.parse_agy_quota_output(ISO, [{"percent": 0.6703, "resetsAt": "2026-11-26T20:14:26Z"}])
    self.assertEqual(out[0], {"label": "Session (5-hour)", "title": "Session", "percent": 0.6703, "resetsAt": "2026-11-26T20:14:26Z"})
    self.assertEqual(out[1], {"label": "Weekly (7-day)", "title": "Weekly", "percent": 0.17, "resetsAt": "2026-12-03T15:14:26Z"})

  def test_claude_gpt_grouped(self):
    text = (
      "Gemini Models\tWeekly Limit Remaining\t75%\t2026-12-03T15:14:26Z\n"
      "Gemini Models\tFive Hour Limit Remaining\t0%\t2026-11-26T20:14:26Z\n"
      "Claude and GPT models\tWeekly Limit Remaining\t62%\t2026-12-02T21:51:43Z\n"
      "Claude and GPT models\tFive Hour Limit Remaining\t30%\t2026-11-26T22:54:05Z\n"
    )
    out = mod.parse_agy_quota_output(text)
    self.assertEqual([(l["title"], l.get("group")) for l in out], [
      ("Session", None), ("Weekly", None),
      ("Session", "Claude & GPT models"), ("Weekly", "Claude & GPT models")])
    self.assertEqual(out[0]["percent"], 1.0)
    self.assertEqual(out[2], {"title": "Session", "label": "Session (5-hour)", "group": "Claude & GPT models", "percent": 0.7, "resetsAt": "2026-11-26T22:54:05Z"})
    self.assertEqual(out[3], {"title": "Weekly", "label": "Weekly (7-day)", "group": "Claude & GPT models", "percent": 0.38, "resetsAt": "2026-12-02T21:51:43Z"})

  def test_untouched_pools_1970(self):
    text = (
      "Gemini Models\tWeekly Limit Remaining\t100%\t1970-01-01T00:00:00Z\n"
      "Gemini Models\tFive Hour Limit Remaining\t75%\t2026-11-26T20:14:26Z\n"
      "Claude and GPT models\tWeekly Limit Remaining\t100%\t1970-01-01T00:00:00Z\n"
      "Claude and GPT models\tFive Hour Limit Remaining\t100%\t1970-01-01T00:00:00Z\n"
    )
    out = mod.parse_agy_quota_output(text)
    self.assertEqual([(l["title"], l.get("group")) for l in out], [
      ("Session", None), ("Session", "Claude & GPT models"), ("Weekly", "Claude & GPT models")])
    self.assertEqual(out[1]["percent"], 0.0)
    self.assertEqual(out[1]["resetsAt"], "")
    self.assertEqual(out[2]["resetsAt"], "")

  def test_extract_limits_groups(self):
    data = {"groups": [
      {"displayName": "Gemini models", "buckets": [
        {"window": "5h", "remainingFraction": 0.8, "resetTime": "2026-11-26T20:14:26Z"},
        {"window": "weekly", "remainingFraction": 0.5, "resetTime": "2026-12-03T15:14:26Z"}]},
      {"displayName": "Claude and GPT models", "buckets": [
        {"window": "5h", "remainingFraction": 1.0, "resetTime": "1970-01-01T00:00:00Z"},
        {"window": "weekly", "remainingFraction": 0.62, "resetTime": "2026-12-02T21:51:43Z"}]},
    ]}
    out = mod.extract_limits(data)
    self.assertEqual([(l["title"], l.get("group")) for l in out], [
      ("Session", None), ("Weekly", None),
      ("Session", "Claude & GPT models"), ("Weekly", "Claude & GPT models")])
    self.assertEqual(out[2], {"title": "Session", "label": "Session (5-hour)", "group": "Claude & GPT models", "percent": 0.0, "resetsAt": ""})
    self.assertEqual(out[3]["percent"], 0.38)
    self.assertNotIn("group", out[0])

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
