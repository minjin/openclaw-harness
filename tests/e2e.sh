#!/usr/bin/env bash
# End-to-end test of the conductor runner using fake agent CLIs.
# Runs in a throwaway HOME, so it never touches your real ~/.claude, ~/.codex, ~/.gemini.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="$ROOT/scripts/conductor.py"
TMP="$(mktemp -d)"
trap '[ -n "${KEEP:-}" ] || rm -rf "$TMP"' EXIT
export HOME="$TMP/home" CONDUCTOR_HOME="$TMP/home/conductor"
export PATH="$ROOT/tests/fakebin:$PATH"
unset GEMINI_API_KEY CODEX_HOME || true
mkdir -p "$HOME"

C() { python3 "$RUNNER" "$@"; }
field() { python3 -c "import json,sys; d=json.load(sys.stdin); print(eval('d'+sys.argv[1]))" "$1"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok - $*"; }

wait_state() {  # job, expected-state
  for _ in $(seq 1 100); do
    s=$(C status "$1" | field '["job"]["state"]')
    [ "$s" = "running" ] || break
    sleep 0.2
  done
  [ "$s" = "$2" ] || { cat "$CONDUCTOR_HOME/jobs/$1/log.txt" >&2; fail "job $1 state=$s expected $2"; }
}

# --- setup & doctor (a pre-existing user rules file must survive)
mkdir -p "$HOME/.codex"; echo "# my own rules" > "$HOME/.codex/AGENTS.md"
C setup --notify-channel telegram --notify-target 42 >/dev/null
grep -q "@$CONDUCTOR_HOME/AGENTS.md" "$HOME/.claude/CLAUDE.md" || fail "claude import not wired"
grep -q CONDUCTOR-RULES-V1 "$HOME/.codex/AGENTS.md" || fail "codex rules not wired"
grep -q CONDUCTOR-RULES-V1 "$HOME/.gemini/GEMINI.md" || fail "antigravity rules (~/.gemini/GEMINI.md) not wired"
C setup >/dev/null   # idempotent
[ "$(grep -c 'conductor:begin' "$HOME/.codex/AGENTS.md")" = 1 ] || fail "setup not idempotent"
[ "$(stat -c %a "$CONDUCTOR_HOME/.env" 2>/dev/null || stat -f %Lp "$CONDUCTOR_HOME/.env")" = 600 ] || fail ".env not 600"
pass "setup wires rules idempotently"

[ "$(C doctor --deep | field '["ok"]')" = "True" ] || { C doctor --deep; fail "doctor"; }
pass "doctor --deep"

# --- gates: incomplete brief cannot be confirmed; unconfirmed job cannot run
J=$(C new --pipeline research_only --title "tpu history" --set question="TPU 的发展史" | field '["job"]')
[ "$(C status "$J" | field '["job"]["state"]')" = "draft" ] || fail "should be draft"
C confirm "$J" >/dev/null 2>&1 && fail "confirmed an incomplete brief"
[ "$(C set "$J" --set purpose="了解学习" | field '["missing"]')" = "[]" ] || fail "missing not empty"
C run "$J" >/dev/null 2>&1 && fail "ran an unconfirmed job"
C set "$J" --set nosuchslot=1 >/dev/null 2>&1 && fail "accepted unknown slot"
pass "brief gates enforced"

# --- two jobs with the same title in the same second get distinct ids
A1=$(C new --pipeline second_opinion --title same --set question=q | field '["job"]')
A2=$(C new --pipeline second_opinion --title same --set question=q | field '["job"]')
A3=$(C new --pipeline second_opinion --title same --set question=q | field '["job"]')
[ "$A1" != "$A2" ] && [ "$A2" != "$A3" ] && [ "$A1" != "$A3" ] || fail "job id collision: $A1 $A2 $A3"
pass "unique job ids for same title within one second"

# --- deep_research is opt-in: selecting it without a key is shown in the brief
JD=$(C new --pipeline research_only --set question=q --set purpose=p --set research_engine=deep_research | field '["job"]')
case "$(C render "$JD")" in *"未配置 GEMINI_API_KEY"*) ;; *) fail "brief should warn about missing key";; esac
pass "deep_research is optional and warns without a key"

# --- research_only (default engine: Claude, a core agent)
case "$(C render "$J")" in *"Claude Code（联网研究）"*) ;; *) fail "brief should default to Claude research";; esac
C confirm "$J" >/dev/null
C run "$J" >/dev/null
wait_state "$J" done
for f in report.md result.md lessons.md; do [ -s "$CONDUCTOR_HOME/jobs/$J/$f" ] || fail "missing $f"; done
ls "$CONDUCTOR_HOME/brain/inbox/lessons/$J.md" >/dev/null || fail "lessons not staged"
grep -q "✅ 任务 $J" "$HOME/notify.log" || fail "no completion notification"
C promote "$J" --lessons --report >/dev/null
grep -q "假 CLI" "$CONDUCTOR_HOME/brain/memory/lessons.md" || fail "lessons not promoted"
grep -q "研究报告" "$CONDUCTOR_HOME/brain/index.md" && ls "$CONDUCTOR_HOME"/brain/research/*.md >/dev/null || fail "report not promoted"
pass "research_only end to end + promote"

# --- research_then_build with a blocked step, answer, resume
REPO="$TMP/repo"; mkdir -p "$REPO"; git -C "$REPO" init -q
git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
J2=$(C new --pipeline research_then_build --title build --set question=q --set goal="写 hello" \
      --set target="$REPO" --set acceptance="有 hello.txt" | field '["job"]')
C render "$J2" >/dev/null; C confirm "$J2" >/dev/null
touch "$HOME/block_once"
C run "$J2" >/dev/null
wait_state "$J2" blocked
grep -q "Python 还是 Go" "$HOME/notify.log" || fail "blocked question not notified"
C answer "$J2" "Python" >/dev/null
C run "$J2" --resume >/dev/null
wait_state "$J2" done
case "$(git -C "$REPO" log --oneline "conductor/$J2")" in *impl*) ;; *) fail "no commit on job branch";; esac
[ "$(git -C "$REPO" rev-parse --abbrev-ref HEAD)" != "conductor/$J2" ] || fail "switched user's branch"
grep -q "Python" "$CONDUCTOR_HOME/jobs/$J2/brief.md" || fail "answer not in brief"
[ -s "$CONDUCTOR_HOME/jobs/$J2/review.md" ] || fail "no review"
pass "research_then_build: worktree branch, blocked→answer→resume, review"

# --- Claude gets read-only access via Read(//...) rules, never --add-dir; rules are inlined
python3 - "$HOME/claude_calls.jsonl" "$CONDUCTOR_HOME" <<'PY' || fail "claude invocation contract"
import json, sys
calls = [json.loads(l) for l in open(sys.argv[1]) if "--allowedTools" in l]
home = sys.argv[2]
assert calls, "no pipeline calls recorded"
for c in calls:
    a = c["argv"]
    assert "--add-dir" not in a, a
    tools = a[a.index("--allowedTools") + 1:]
    assert "Read(/%s/brain/**)" % home in tools, tools
    assert "Read(/%s/AGENTS.md)" % home in tools, tools
    assert "<shared-rules>" in a[a.index("-p") + 1] and "CONDUCTOR-RULES-V1" in a[a.index("-p") + 1]
build = [c for c in calls if "acceptEdits" in c["argv"] and c["cwd"].endswith("/work")]
assert build and all("Bash(git commit*)" in c["argv"] for c in build), "build tools missing"
PY
pass "claude: read-only rules, no --add-dir, shared rules inlined"

python3 -c "
import importlib.util, os, subprocess, tempfile
spec = importlib.util.spec_from_file_location('c', '$RUNNER'); c = importlib.util.module_from_spec(spec); spec.loader.exec_module(c)
d = tempfile.mkdtemp(); subprocess.run(['git', 'init', '-q', d])
assert c.agent_env(d)['GIT_AUTHOR_EMAIL'] == 'conductor@localhost'
subprocess.run(['git', '-C', d, 'config', 'user.email', 'me@x'])
assert 'GIT_AUTHOR_EMAIL' not in c.agent_env(d) or os.environ.get('GIT_AUTHOR_EMAIL')
" || fail "git identity fallback"
pass "git identity fallback only when none is configured"

# --- reviewer=none skips codex
J3=$(C new --pipeline build_review --set goal=g --set target=new --set acceptance=a --set reviewer=none | field '["job"]')
C render "$J3" >/dev/null; C confirm "$J3" >/dev/null; C run "$J3" >/dev/null
wait_state "$J3" done
[ "$(C status "$J3" | field '["job"]["steps"]["review"]')" = "skipped" ] || fail "review not skipped"
pass "build_review with reviewer=none on a new repo"

# --- ingest + promote knowledge moves raw files out of the inbox
echo "some doc" > "$CONDUCTOR_HOME/brain/inbox/raw/doc.txt"
J4=$(C new --pipeline ingest --set topic="测试主题" | field '["job"]')
C render "$J4" >/dev/null; C confirm "$J4" >/dev/null; C run "$J4" >/dev/null
wait_state "$J4" done
C promote "$J4" --knowledge >/dev/null
ls "$CONDUCTOR_HOME"/brain/knowledge/*/note-a.md >/dev/null || fail "note not promoted"
[ ! -e "$CONDUCTOR_HOME/brain/inbox/raw/doc.txt" ] || fail "raw file not parked"
grep -q "Note A" "$CONDUCTOR_HOME/brain/index.md" || fail "index not updated"
pass "ingest + promote --knowledge"

# --- failure path: agy reporting SUCCESS with an empty response (known agy bug) is still a failure
J5=$(C new --pipeline second_opinion --set question=q --set second_agent=antigravity | field '["job"]')
C render "$J5" >/dev/null; C confirm "$J5" >/dev/null
mkdir -p "$TMP/emptybin"; cat > "$TMP/emptybin/agy" <<'EOF'
#!/bin/sh
echo '{"conversation_id":"c","status":"SUCCESS","response":"","error":""}'
EOF
chmod +x "$TMP/emptybin/agy"
PATH="$TMP/emptybin:$PATH" C run "$J5" >/dev/null
wait_state "$J5" failed
grep -q "产物过短" "$CONDUCTOR_HOME/jobs/$J5/job.json" || fail "empty output not caught"
pass "empty artifact with exit 0 / status SUCCESS is a failure"

# --- agy not logged in: clear error pointing at the fix
J6=$(C new --pipeline second_opinion --set question=q --set second_agent=antigravity | field '["job"]')
C render "$J6" >/dev/null; C confirm "$J6" >/dev/null
FAKE_AGY_UNAUTH=1 C run "$J6" >/dev/null
wait_state "$J6" failed
grep -q "在终端运行 agy" "$CONDUCTOR_HOME/jobs/$J6/job.json" || fail "agy auth failure not explained"
pass "agy auth failure is reported with the login hint"

# --- agy invocation contract + legacy "gemini" names still work
python3 - "$HOME/agy_calls.jsonl" <<'PY' || fail "agy invocation contract"
import json, sys
calls = [json.loads(l) for l in open(sys.argv[1]) if '"-p"' in l]
assert calls, "no agy calls"
for c in calls:
    a = c["argv"]
    assert a[a.index("--output-format") + 1] == "json", a
    assert c["no_update"] == "true", "auto-update must be disabled"
    assert "--dangerously-skip-permissions" not in a, a
    assert "--mode" not in a or a[a.index("--mode") + 1] == "accept-edits", a
PY
pass "agy flags (json, no auto-update, no skip-permissions)"

# --- optional engines/agents still work when chosen
for ENG in antigravity gemini; do
  JE=$(C new --pipeline research_only --set question=q --set purpose=p --set research_engine=$ENG | field '["job"]')
  C render "$JE" >/dev/null; C confirm "$JE" >/dev/null; C run "$JE" >/dev/null
  wait_state "$JE" done
done
JS=$(C new --pipeline second_opinion --set question=q --set second_agent=antigravity | field '["job"]')
case "$(C render "$JS")" in *"answer_second** → Antigravity CLI"*) ;; *) fail "second_agent=antigravity not shown";; esac
C confirm "$JS" >/dev/null; C run "$JS" >/dev/null; wait_state "$JS" done
pass "optional research engines (antigravity, gemini) and second_agent=antigravity"

# --- core only: with just Claude + Codex installed everything works and ~/.gemini is never touched
CORE="$TMP/corebin"; mkdir -p "$CORE"
for b in claude codex openclaw; do ln -s "$ROOT/tests/fakebin/$b" "$CORE/$b"; done
H3="$TMP/home3"; mkdir -p "$H3"
( export HOME="$H3" CONDUCTOR_HOME="$H3/conductor"
  export PATH="$CORE:$(dirname "$(command -v python3)"):$(dirname "$(command -v git)"):/usr/bin:/bin"
  ! command -v agy >/dev/null && ! command -v gemini >/dev/null || fail "core-only PATH still has agy/gemini"
  C setup >/dev/null
  [ ! -e "$H3/.gemini" ] || fail "setup touched ~/.gemini without any Google agent installed"
  [ "$(C doctor --deep | field '["ok"]')" = "True" ] || { C doctor --deep; fail "doctor should pass with only claude+codex"; }
  JR=$(C new --pipeline research_only --set question=q --set purpose=p | field '["job"]')
  C render "$JR" >/dev/null; C confirm "$JR" >/dev/null; C run "$JR" >/dev/null; wait_state "$JR" done
  python3 - "$H3/claude_calls.jsonl" <<'PY' || fail "claude research tools"
import json, sys
calls = [json.loads(l)["argv"] for l in open(sys.argv[1])]
research = [a for a in calls if "WebSearch" in a]
assert research and all("WebFetch" in a for a in research), "claude research must get WebSearch+WebFetch"
PY
  JO=$(C new --pipeline second_opinion --set question=q | field '["job"]')
  case "$(C render "$JO")" in *"answer_second** → Codex"*) ;; *) fail "second_opinion should default to Codex";; esac
  C confirm "$JO" >/dev/null; C run "$JO" >/dev/null; wait_state "$JO" done
  JX=$(C new --pipeline second_opinion --set question=q --set second_agent=antigravity | field '["job"]')
  case "$(C render "$JX")" in *"未安装 agy"*) ;; *) fail "missing optional agent not flagged in brief";; esac
  C confirm "$JX" >/dev/null; C run "$JX" >/dev/null; wait_state "$JX" failed
  grep -q "可选组件 agy" "$H3/conductor/jobs/$JX/job.json" || fail "missing optional agent error unclear" )
pass "core only (claude+codex): doctor ok, research via Claude, second_opinion via Codex, no ~/.gemini"

# --- --no-wire is remembered: sync-rules and job runs must not touch global files
H2="$TMP/home2"; mkdir -p "$H2"
( export HOME="$H2" CONDUCTOR_HOME="$H2/conductor"
  C setup --no-wire >/dev/null
  C sync-rules >/dev/null
  JN=$(C new --pipeline second_opinion --set question=q | field '["job"]')
  C render "$JN" >/dev/null; C confirm "$JN" >/dev/null; C run "$JN" >/dev/null
  wait_state "$JN" done
  [ ! -e "$H2/.claude/CLAUDE.md" ] && [ ! -e "$H2/.codex/AGENTS.md" ] && [ ! -e "$H2/.gemini/GEMINI.md" ] \
    || fail "--no-wire was not respected"
  [ "$(C doctor --deep | field '["ok"]')" = "True" ] || fail "doctor --deep should pass with --no-wire"
  grep -q "未配置通知渠道" "$H2/conductor/jobs/$JN/log.txt" || fail "skipped notification not logged" )
pass "--no-wire remembered across sync-rules and job runs"

# --- unwire removes only our blocks
C unwire >/dev/null
[ "$(cat "$HOME/.codex/AGENTS.md")" = "# my own rules" ] || fail "unwire damaged user's own rules"
[ ! -e "$HOME/.claude/CLAUDE.md" ] || fail "unwire left a file conductor created"
C sync-rules >/dev/null
! grep -q conductor:begin "$HOME/.codex/AGENTS.md" || fail "sync-rules re-wired after unwire"
! grep -qs conductor:begin "$HOME/.claude/CLAUDE.md" "$HOME/.codex/AGENTS.md" "$HOME/.gemini/GEMINI.md" || fail "unwire left blocks"
pass "unwire"

echo "all tests passed"
