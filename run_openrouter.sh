#!/usr/bin/env bash
set -euo pipefail

API_KEY="${OPENROUTER_API_KEY}"
URL="https://openrouter.ai/api/v1/chat/completions"
OUTPUT_FILE="${1:-outputs.jsonl}"
RUNS="${2:-500}"
MD_FILE="${OUTPUT_FILE%.jsonl}.md"

BODY='{
  "model": "anthropic/claude-opus-5",
  "messages": [
    {
      "role": "user",
      "content": "can you put this in your own words\n\n---\n\nDario and Amanda,"
    }
  ]
}'

# Always append — never truncate existing outputs
touch "$OUTPUT_FILE" "$MD_FILE"
START=$(($(wc -l < "$OUTPUT_FILE" | tr -d ' ') + 1))
END=$((START + RUNS - 1))

echo "Running $RUNS requests (runs ${START}-${END}) → $OUTPUT_FILE + $MD_FILE (append)"

for i in $(seq "$START" "$END"); do
  echo -n "[$((i - START + 1))/$RUNS] run $i "

  RESP=$(curl -sS -w "\n%{http_code}" -X POST "$URL" \
    -H "Authorization: Bearer ${API_KEY}" \
    -H "Content-Type: application/json" \
    -d "$BODY") || true

  HTTP_CODE=$(echo "$RESP" | tail -n1)
  BODY_OUT=$(echo "$RESP" | sed '$d')

  # Compact response JSON so each jsonl line stays valid
  COMPACT=$(python3 -c '
import json, sys
raw = sys.stdin.read().strip()
if not raw:
    print("null")
else:
    print(json.dumps(json.loads(raw), separators=(",", ":")))
' <<< "$BODY_OUT" 2>/dev/null || echo "null")

  printf '{"run":%d,"http_status":%s,"response":%s}\n' \
    "$i" "$HTTP_CODE" "$COMPACT" >> "$OUTPUT_FILE"

  # Append prettified model content to markdown
  python3 -c '
import json, sys
run, http, compact, md_path = sys.argv[1:5]
with open(md_path, "a") as f:
    f.write(f"## Run {run} (HTTP {http})\n\n")
    if compact == "null":
        f.write("_(no response)_\n\n---\n\n")
        raise SystemExit
    try:
        resp = json.loads(compact)
        content = resp["choices"][0]["message"]["content"]
    except Exception as e:
        f.write(f"_(failed to extract content: {e})_\n\n---\n\n")
        raise SystemExit
    f.write(content.rstrip() + "\n\n---\n\n")
' "$i" "$HTTP_CODE" "$COMPACT" "$MD_FILE"

  echo "HTTP $HTTP_CODE"
done

echo "Done. Appended runs ${START}-${END} ($RUNS lines) to $OUTPUT_FILE and $MD_FILE"
