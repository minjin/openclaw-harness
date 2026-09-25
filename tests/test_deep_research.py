"""Unit test for the Deep Research path with the HTTP layer stubbed out."""
import importlib.util
import json
import os
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
tmp = tempfile.mkdtemp()
os.environ["CONDUCTOR_HOME"] = tmp
os.environ["GEMINI_API_KEY"] = "test-key"
spec = importlib.util.spec_from_file_location("conductor", os.path.join(ROOT, "scripts/conductor.py"))
c = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)
c.time.sleep = lambda s: None

calls = []
polls = iter([
    {"id": "int-1", "status": "in_progress"},
    {"id": "int-1", "status": "completed", "steps": [
        {"type": "user_input", "content": [{"type": "text", "text": "q"}]},
        {"type": "thought", "summary": []},
        {"type": "model_output", "content": [{"type": "text", "text": "# Report\n\nfinding"}]},
    ]},
])


def fake_http(method, url, key, body=None, timeout=60):
    calls.append((method, url, body))
    if method == "POST":
        return {"id": "int-1", "status": "in_progress"}
    return next(polls)


c.dr_http = fake_http
d = os.path.join(tmp, "jobs", "j1")
os.makedirs(d)
job = {"id": "j1", "pipeline": "research_only", "slots": {}, "steps": {"research": {"state": "running"}}}
c.save_job(d, job)
step = {"id": "research", "agent": "research", "output": "report.md",
        "task": "研究问题：{question}"}
cfg = c.config()

text = c.run_research(d, job, step, {"question": "TPU", "depth": "max", "research_engine": "deep_research"}, cfg, 60)
assert text == "# Report\n\nfinding", text
post = calls[0]
assert post[0] == "POST" and post[1] == c.DR_API
assert post[2]["background"] is True and post[2]["agent"] == cfg["research"]["max_agent"]
assert post[2]["input"] == "研究问题：TPU"
assert job["steps"]["research"]["interaction_id"] == "int-1"
assert json.load(open(os.path.join(d, "research_raw.json")))["status"] == "completed"

# Resume must keep polling the existing interaction instead of creating (and paying for) a new one.
calls.clear()
polls = iter([{"id": "int-1", "status": "completed", "output_text": "again"}])
assert c.run_research(d, job, step, {"question": "TPU", "research_engine": "deep_research"}, cfg, 60) == "again"
assert [m for m, _, _ in calls] == ["GET"], calls

# Terminal failure states raise.
job["steps"]["research"] = {"state": "running"}
polls = iter([{"id": "int-2", "status": "failed", "error": {"message": "boom"}}])
try:
    c.run_research(d, job, step, {"question": "x", "research_engine": "deep_research"}, cfg, 60)
    raise SystemExit("expected failure")
except c.StepError as e:
    assert "failed" in str(e)

# Without a key, choosing deep_research fails clearly instead of silently downgrading.
del os.environ["GEMINI_API_KEY"]
try:
    c.run_research(d, job, step, {"question": "x", "research_engine": "deep_research"}, cfg, 60)
    raise SystemExit("expected missing-key failure")
except c.StepError as e:
    assert "GEMINI_API_KEY" in str(e)

print("ok - deep research: create/poll/extract, resume without re-create, failure")
