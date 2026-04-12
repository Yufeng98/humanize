#!/usr/bin/env bash
# Tests for retired --agent-teams behavior in the Codex-only runtime
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

SETUP_SCRIPT="$PROJECT_ROOT/scripts/setup-rlcr-loop.sh"

echo "=========================================="
echo "Agent Teams Retirement Tests"
echo "=========================================="
echo ""

setup_repo_with_plan() {
    local repo_dir="$1"
    mkdir -p "$repo_dir/temp"
    init_test_git_repo "$repo_dir"
    cat > "$repo_dir/temp/plan.md" <<'EOF'
# Test Plan

## Goal
Migrate the runtime.

## Acceptance Criteria
- AC-1: Runtime starts.
- AC-2: Runtime stays Codex-only.

## Dependencies and Sequence
1. Validate setup.
2. Validate stop hook.
EOF
    (
        cd "$repo_dir"
        git add temp/plan.md
        git commit -q -m "Add test plan"
    )
}

run_setup() {
    local repo_dir="$1"
    local bin_dir="$2"
    shift
    shift
    (
        cd "$repo_dir"
        PATH="$bin_dir:$PATH" CLAUDE_PROJECT_DIR="$repo_dir" bash "$SETUP_SCRIPT" "$@"
    )
}

# ========================================
# Test 1: CLI flag is explicitly unsupported
# ========================================

setup_test_dir
REPO_DIR="$TEST_DIR/repo-cli"
setup_repo_with_plan "$REPO_DIR"
BIN_DIR="$TEST_DIR/bin-cli"
mkdir -p "$BIN_DIR"
cat > "$BIN_DIR/codex" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$BIN_DIR/codex"

EXIT_CODE=0
OUTPUT=$(run_setup "$REPO_DIR" "$BIN_DIR" --agent-teams temp/plan.md 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]] && echo "$OUTPUT" | grep -qi "no longer supported"; then
    pass "--agent-teams flag fails fast with unsupported message"
else
    fail "--agent-teams flag fails fast with unsupported message" \
        "non-zero exit + unsupported message" "exit=$EXIT_CODE output=$OUTPUT"
fi

# ========================================
# Test 2: Project config cannot silently enable retired feature
# ========================================

setup_test_dir
REPO_DIR="$TEST_DIR/repo-config"
setup_repo_with_plan "$REPO_DIR"
BIN_DIR="$TEST_DIR/bin-config"
mkdir -p "$BIN_DIR"
cat > "$BIN_DIR/codex" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$BIN_DIR/codex"
mkdir -p "$REPO_DIR/.humanize"
printf '{"agent_teams": true}' > "$REPO_DIR/.humanize/config.json"

EXIT_CODE=0
OUTPUT=$(run_setup "$REPO_DIR" "$BIN_DIR" temp/plan.md 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]] && echo "$OUTPUT" | grep -qi "no longer supported"; then
    pass "agent_teams project config fails fast with unsupported message"
else
    fail "agent_teams project config fails fast with unsupported message" \
        "non-zero exit + unsupported message" "exit=$EXIT_CODE output=$OUTPUT"
fi

# ========================================
# Test 3: Normal setup still records agent_teams: false
# ========================================

setup_test_dir
REPO_DIR="$TEST_DIR/repo-normal"
setup_repo_with_plan "$REPO_DIR"
BIN_DIR="$TEST_DIR/bin-normal"
mkdir -p "$BIN_DIR"
cat > "$BIN_DIR/codex" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$BIN_DIR/codex"

EXIT_CODE=0
run_setup "$REPO_DIR" "$BIN_DIR" --track-plan-file temp/plan.md >/dev/null 2>&1 || EXIT_CODE=$?

STATE_FILE="$(find "$REPO_DIR/.humanize/rlcr" -name state.md -type f | head -n1)"

if [[ $EXIT_CODE -eq 0 ]] && [[ -f "$STATE_FILE" ]] && grep -q '^agent_teams: false$' "$STATE_FILE"; then
    pass "normal setup records agent_teams: false"
else
    fail "normal setup records agent_teams: false" \
        "successful setup with agent_teams: false in state" \
        "exit=$EXIT_CODE state=$(grep '^agent_teams:' "$STATE_FILE" 2>/dev/null || echo missing)"
fi

# ========================================
# Test 4: Normal prompt has no team-leader instructions
# ========================================

PROMPT_FILE="$(find "$REPO_DIR/.humanize/rlcr" -name 'round-0-prompt.md' -type f | head -n1)"

if [[ -f "$PROMPT_FILE" ]] && ! grep -q "Team Leader" "$PROMPT_FILE"; then
    pass "normal setup prompt excludes team-leader instructions"
else
    fail "normal setup prompt excludes team-leader instructions" \
        "prompt without team-leader text" "$(cat "$PROMPT_FILE" 2>/dev/null || echo missing)"
fi

print_test_summary "Agent Teams Retirement Tests"
