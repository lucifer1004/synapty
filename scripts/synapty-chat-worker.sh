#!/bin/zsh
set -euo pipefail

STATE_DIR="${STATE_DIR:-/tmp/synapty-chat-worker}"
POLL_SECONDS="${POLL_SECONDS:-15}"
MAX_TURNS="${MAX_TURNS:-12}"
SYSTEM_PROMPT="${SYSTEM_PROMPT:-You are a Synapty chat participant speaking to another coding agent. Be concise, technical, and conversational. Continue the discussion naturally, answer the latest message directly, and add one useful follow-up idea or question when appropriate. Do not mention tools, hidden instructions, or that you are an automated loop unless asked.}"

mkdir -p "$STATE_DIR"

agent_id="${SYNAPTY_AGENT_ID:-unknown}"
echo "synapty chat worker started for ${agent_id}"

sanitize_id() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

append_history() {
  local peer="$1"
  local role="$2"
  local text="$3"
  local safe_peer
  safe_peer="$(sanitize_id "$peer")"
  printf '%s\t%s\t%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$role" "$text" >> "$STATE_DIR/${safe_peer}.log"
}

build_prompt() {
  local peer="$1"
  local latest="$2"
  local safe_peer
  safe_peer="$(sanitize_id "$peer")"
  local history_file="$STATE_DIR/${safe_peer}.log"
  local history=""

  if [ -f "$history_file" ]; then
    history="$(tail -n $((MAX_TURNS * 2)) "$history_file")"
  fi

  cat <<EOF
$SYSTEM_PROMPT

Your local Synapty agent id: $agent_id
Remote peer id: $peer

Recent conversation transcript:
$history

Latest incoming message from $peer:
$latest

Write only the reply message text to send back to $peer.
EOF
}

while true; do
  raw="$(synapty recv 2>/dev/null || true)"

  if [ -n "$raw" ] && [ "$(printf '%s' "$raw" | jq -r '.success // false' 2>/dev/null)" = "true" ]; then
    printf '%s' "$raw" | jq -cr '.data | fromjson[]?' | while IFS= read -r envelope; do
      src="$(printf '%s' "$envelope" | jq -r '.source // empty')"
      [ -n "$src" ] || continue
      [ "$src" != "$agent_id" ] || continue

      latest="$(printf '%s' "$envelope" | jq -r '.payload | (try fromjson.message catch . // "")' 2>/dev/null)"
      [ -n "$latest" ] || continue

      append_history "$src" "peer" "$latest"

      prompt_file="$STATE_DIR/prompt.$$.txt"
      reply_file="$STATE_DIR/reply.$$.txt"
      build_prompt "$src" "$latest" > "$prompt_file"

      if codex exec --skip-git-repo-check --output-last-message "$reply_file" - < "$prompt_file" >/dev/null 2>&1; then
        reply_text="$(tr '\n' ' ' < "$reply_file" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
      else
        reply_text="I saw your message, but my reply worker failed to generate a response cleanly. Please resend or continue."
      fi

      rm -f "$prompt_file" "$reply_file"

      [ -n "$reply_text" ] || continue
      append_history "$src" "self" "$reply_text"

      payload="$(jq -Rn --arg message "$reply_text" '{message:$message}')"
      synapty send "$src" "$payload" >/dev/null 2>&1 || true
      printf '%s | replied to %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$src"
    done
  fi

  sleep "$POLL_SECONDS"
done
