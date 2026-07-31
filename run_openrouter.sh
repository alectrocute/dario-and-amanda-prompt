#!/usr/bin/env bash
set -euo pipefail

API_KEY="${OPENROUTER_API_KEY:?OPENROUTER_API_KEY is required}"
URL="https://openrouter.ai/api/v1/chat/completions"
OUTPUT_FILE="${1:-outputs.jsonl}"
RUNS="${2:-500}"
MD_FILE="${OUTPUT_FILE%.jsonl}.md"

# --- Safety knobs (override via env) ---
# Hard wall-clock limits for each request
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-15}"   # seconds to establish TCP/TLS
MAX_TIME="${MAX_TIME:-90}"                 # total request budget (incl. generation)
# Cap completion length (for Opus 5 this covers thinking + visible text)
MAX_TOKENS="${MAX_TOKENS:-1024}"
# Lower thinking spend — Opus 5 reasons by default; "low" keeps it cheap
REASONING_EFFORT="${REASONING_EFFORT:-low}"  # low|medium|high; set empty to omit
# Prefer shorter visible answers when supported
VERBOSITY="${VERBOSITY:-low}"
# Client-side loop detector (abort stream early — stops billing on supporting providers)
REP_MIN_CHARS="${REP_MIN_CHARS:-16}"       # min line/phrase length to count as a loop
REP_LINE_STREAK="${REP_LINE_STREAK:-13}"    # identical consecutive lines before abort
REP_PHRASE_HITS="${REP_PHRASE_HITS:-13}"    # same phrase must appear this many times
REP_CHECK_EVERY="${REP_CHECK_EVERY:-64}"  # chars between repetition checks

BODY=$(
  MAX_TOKENS="$MAX_TOKENS" \
  VERBOSITY="$VERBOSITY" \
  REASONING_EFFORT="$REASONING_EFFORT" \
  python3 -c '
import json, os
body = {
  "model": "anthropic/claude-opus-5",
  "stream": True,
  "max_tokens": int(os.environ["MAX_TOKENS"]),
  "verbosity": os.environ["VERBOSITY"],
  "messages": [
    {
      "role": "user",
      "content": "can you put this in your own words\n\n---\n\nDario and Amanda,",
    }
  ],
}
effort = os.environ.get("REASONING_EFFORT", "").strip()
if effort:
    # Adaptive thinking depth; low cuts token spend vs default high
    body["reasoning"] = {"effort": effort}
print(json.dumps(body))
'
)

# Always append — never truncate existing outputs
touch "$OUTPUT_FILE" "$MD_FILE"
START=$(($(wc -l < "$OUTPUT_FILE" | tr -d ' ') + 1))
END=$((START + RUNS - 1))

echo "Running $RUNS requests (runs ${START}-${END}) → $OUTPUT_FILE + $MD_FILE (append)"
echo "Safety: timeout=${MAX_TIME}s connect=${CONNECT_TIMEOUT}s max_tokens=${MAX_TOKENS} reasoning=${REASONING_EFFORT:-omit} verbosity=${VERBOSITY} stream+rep-abort=on"

for i in $(seq "$START" "$END"); do
  echo -n "[$((i - START + 1))/$RUNS] run $i "

  # curl owns connect/total timeouts; python aborts the pipe on repetition
  # (closing stdin kills curl → stream cancel on providers that support it)
  # Script on fd 3 so curl's SSE still arrives on stdin.
  RESULT=$(
    set +e
    curl -sS -N \
      --connect-timeout "$CONNECT_TIMEOUT" \
      --max-time "$MAX_TIME" \
      -X POST "$URL" \
      -H "Authorization: Bearer ${API_KEY}" \
      -H "Content-Type: application/json" \
      -H "Accept: text/event-stream" \
      -d "$BODY" \
      -w "\n__CURL_HTTP_STATUS__:%{http_code}\n" \
      2>/dev/null \
    | REP_MIN_CHARS="$REP_MIN_CHARS" \
      REP_LINE_STREAK="$REP_LINE_STREAK" \
      REP_PHRASE_HITS="$REP_PHRASE_HITS" \
      REP_CHECK_EVERY="$REP_CHECK_EVERY" \
      python3 /dev/fd/3 3<<'PY'
import json, os, sys

rep_min = int(os.environ["REP_MIN_CHARS"])
rep_streak = int(os.environ["REP_LINE_STREAK"])
rep_hits = int(os.environ["REP_PHRASE_HITS"])
rep_every = int(os.environ["REP_CHECK_EVERY"])

def repetition_detected(text):
    """Return a short reason if the completion looks like a token-wasting loop."""
    lines = text.splitlines()
    streak = 1
    for i in range(1, len(lines)):
        if lines[i] and lines[i] == lines[i - 1]:
            streak += 1
            if streak >= rep_streak and len(lines[i]) >= rep_min:
                return "repeated_line_x%d" % streak
        else:
            streak = 1

    recent = text[-3000:]
    for size in (120, 80, 40):
        if len(recent) < size * rep_hits:
            continue
        blocks = [recent[-size * (k + 1) : len(recent) - size * k] for k in range(rep_hits)]
        if all(b == blocks[0] and len(b.strip()) >= rep_min for b in blocks):
            return "repeated_block_%dx%d" % (size, rep_hits)
        needle = recent[-size:]
        if len(needle.strip()) >= rep_min and recent.count(needle) >= rep_hits:
            return "repeated_phrase_%dx%d" % (size, rep_hits)
    return None

content_parts = []
content = ""
finish_reason = None
model = None
usage = None
abort_reason = None
http_status = 0
raw_error = None
chars_since_check = 0
buf = []

def handle_line(line):
    global content, finish_reason, model, usage, abort_reason, raw_error
    global chars_since_check, http_status
    line = line.strip()
    if line.startswith("__CURL_HTTP_STATUS__:"):
        try:
            code = int(line.split(":", 1)[1])
            if http_status == 0:
                http_status = code
        except ValueError:
            pass
        return False
    if not line or line.startswith(":"):
        return False
    if not line.startswith("data:"):
        buf.append(line)
        return False
    data = line[5:].strip()
    if data == "[DONE]":
        return True
    try:
        chunk = json.loads(data)
    except json.JSONDecodeError:
        return False
    if chunk.get("error"):
        raw_error = chunk["error"]
        abort_reason = "upstream_error"
        return True
    model = chunk.get("model") or model
    if chunk.get("usage"):
        usage = chunk["usage"]
    choices = chunk.get("choices") or []
    if not choices:
        return False
    choice = choices[0]
    finish_reason = choice.get("finish_reason") or finish_reason
    delta = choice.get("delta") or {}
    piece = delta.get("content") or ""
    if not piece:
        msg = choice.get("message") or {}
        piece = msg.get("content") or ""
    if piece:
        content_parts.append(piece)
        content = "".join(content_parts)
        chars_since_check += len(piece)
        if chars_since_check >= rep_every:
            chars_since_check = 0
            why = repetition_detected(content)
            if why:
                abort_reason = why
                return True
    return False

for raw in sys.stdin:
    if handle_line(raw):
        break

if not content and buf and raw_error is None:
    joined = "\n".join(
        ln for ln in buf if not ln.startswith("__CURL_HTTP_STATUS__:")
    ).strip()
    if joined:
        try:
            raw_error = json.loads(joined)
        except json.JSONDecodeError:
            raw_error = {"message": joined[:500]}

if abort_reason and str(abort_reason).startswith("repeated_"):
    try:
        sys.stdin.close()
    except Exception:
        pass

if http_status == 0 and content:
    http_status = 200
if http_status == 0 and abort_reason is None and not content:
    abort_reason = "timeout_or_empty"

response = {
    "id": None,
    "model": model,
    "choices": [
        {
            "index": 0,
            "message": {"role": "assistant", "content": content},
            "finish_reason": abort_reason or finish_reason,
        }
    ],
}
if usage:
    response["usage"] = usage
if raw_error:
    response["error"] = raw_error

print(
    json.dumps(
        {"http_status": http_status, "aborted": abort_reason, "response": response},
        separators=(",", ":"),
    ),
    flush=True,
)
PY
  )

  HTTP_CODE=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("http_status") or 0)' <<< "$RESULT" 2>/dev/null || echo 0)
  ABORTED=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("aborted") or "")' <<< "$RESULT" 2>/dev/null || echo "")
  COMPACT=$(python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    print(json.dumps(data.get("response"), separators=(",", ":")))
except Exception:
    print("null")
' <<< "$RESULT" 2>/dev/null || echo "null")

  if [[ -n "$ABORTED" ]]; then
    printf '{"run":%d,"http_status":%s,"aborted":%s,"response":%s}\n' \
      "$i" "$HTTP_CODE" "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$ABORTED")" "$COMPACT" >> "$OUTPUT_FILE"
  else
    printf '{"run":%d,"http_status":%s,"response":%s}\n' \
      "$i" "$HTTP_CODE" "$COMPACT" >> "$OUTPUT_FILE"
  fi

  # Append prettified model content to markdown
  python3 -c '
import json, sys
run, http, compact, md_path, aborted = sys.argv[1:6]
with open(md_path, "a") as f:
    tag = f"ABORTED: {aborted}" if aborted else f""
    f.write(f"## Run {run} {tag}\n\n")
    if compact == "null":
        f.write("_(no response)_\n\n---\n\n")
        raise SystemExit
    try:
        resp = json.loads(compact)
        content = resp["choices"][0]["message"]["content"]
    except Exception as e:
        f.write(f"_(failed to extract content: {e})_\n\n---\n\n")
        raise SystemExit
    if not content:
        f.write("_(empty content)_\n\n---\n\n")
        raise SystemExit
    f.write(content.rstrip() + "\n\n---\n\n")
' "$i" "$HTTP_CODE" "$COMPACT" "$MD_FILE" "$ABORTED"

  if [[ -n "$ABORTED" ]]; then
    echo "ABORT $ABORTED (HTTP $HTTP_CODE)"
  else
    echo "HTTP $HTTP_CODE"
  fi
done

echo "Done. Appended runs ${START}-${END} ($RUNS lines) to $OUTPUT_FILE and $MD_FILE"
