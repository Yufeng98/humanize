#!/usr/bin/env bash
# Tests for bitlesson-select.sh Codex-only routing
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

BITLESSON_SELECT="$PROJECT_ROOT/scripts/bitlesson-select.sh"
SAFE_BASE_PATH="/usr/bin:/bin:/usr/sbin:/sbin"

echo "=========================================="
echo "Bitlesson Select Routing Tests"
echo "=========================================="
echo ""

create_placeholder_bitlesson() {
    local dir="$1"
    mkdir -p "$dir/.humanize"
    cat > "$dir/.humanize/bitlesson.md" <<'EOF'
# BitLesson Knowledge Base
## Entries
<!-- placeholder -->
EOF
}

create_real_bitlesson() {
    local path="$1"
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<'EOF'
# BitLesson Knowledge Base
## Entries

## Lesson: Avoid tracker drift
Lesson ID: BL-20260315-tracker-drift
Scope: goal-tracker.md
Problem Description: Tracker diverges from actual task status.
Root Cause: Status rows are not updated after verification.
Solution: Update tracker rows immediately after each verification step.
Constraints: Keep tracker edits minimal.
Validation Evidence: Verified in test fixture.
Source Rounds: 0
EOF
}

create_mock_codex() {
    local bin_dir="$1"
    mkdir -p "$bin_dir"
    cat > "$bin_dir/codex" <<'EOF'
#!/usr/bin/env bash
if [[ "${*: -1}" != "-" ]]; then
    echo "mock codex expected trailing '-'" >&2
    exit 9
fi
cat > /dev/null
cat <<'OUT'
LESSON_IDS: NONE
RATIONALE: No matching lessons found (mock codex).
OUT
EOF
    chmod +x "$bin_dir/codex"
}

create_recording_mock_codex() {
    local bin_dir="$1"
    local stdin_file="$2"
    mkdir -p "$bin_dir"
    cat > "$bin_dir/codex" <<EOF
#!/usr/bin/env bash
for arg in "\$@"; do
    if [[ "\$arg" == "--help" ]]; then
        echo "  --disable <feature>   Disable a feature"
        echo "  --skip-git-repo-check Skip git repo check"
        echo "  --ephemeral           Ephemeral mode"
        exit 0
    fi
done
if [[ "\${*: -1}" != "-" ]]; then
    echo "mock codex expected trailing '-'" >&2
    exit 9
fi
printf '%s\n' "\$@" > "${stdin_file}.args"
cat > "$stdin_file"
cat <<'OUT'
LESSON_IDS: BL-20260315-tracker-drift
RATIONALE: The tracker lesson directly matches the task.
OUT
EOF
    chmod +x "$bin_dir/codex"
}

run_selector() {
    local project_dir="$1"
    local bitlesson_file="$2"
    local task="$3"
    local paths="$4"
    shift 4
    env CLAUDE_PROJECT_DIR="$project_dir" XDG_CONFIG_HOME="$project_dir/no-user" "$@" \
        bash "$BITLESSON_SELECT" --task "$task" --paths "$paths" --bitlesson-file "$bitlesson_file"
}

# ========================================
# Test 1: Codex model routes directly to codex
# ========================================

setup_test_dir
create_real_bitlesson "$TEST_DIR/.humanize/bitlesson.md"
mkdir -p "$TEST_DIR/.humanize"
printf '{"bitlesson_model": "gpt-4o"}' > "$TEST_DIR/.humanize/config.json"
BIN_DIR="$TEST_DIR/bin"
create_mock_codex "$BIN_DIR"

EXIT_CODE=0
OUTPUT=$(run_selector "$TEST_DIR" "$TEST_DIR/.humanize/bitlesson.md" "Fix a bug" "scripts/bitlesson-select.sh" PATH="$BIN_DIR:$PATH" 2>/dev/null) || EXIT_CODE=$?

if [[ $EXIT_CODE -eq 0 ]] && echo "$OUTPUT" | grep -q "LESSON_IDS:"; then
    pass "Codex model routes directly to codex"
else
    fail "Codex model routes directly to codex" "exit 0 + LESSON_IDS output" "exit=$EXIT_CODE output=$OUTPUT"
fi

# ========================================
# Test 2: Legacy Claude-flavored aliases fall back to codex
# ========================================

for legacy_model in haiku claude-3-5-sonnet-20241022 claude-3-OPUS-20240229; do
    setup_test_dir
    create_real_bitlesson "$TEST_DIR/.humanize/bitlesson.md"
    mkdir -p "$TEST_DIR/.humanize"
    printf '{"bitlesson_model": "%s", "codex_model": "gpt-5.4"}' "$legacy_model" > "$TEST_DIR/.humanize/config.json"
    BIN_DIR="$TEST_DIR/bin"
    create_mock_codex "$BIN_DIR"

    EXIT_CODE=0
    OUTPUT=$(run_selector "$TEST_DIR" "$TEST_DIR/.humanize/bitlesson.md" "Fix a bug" "scripts/bitlesson-select.sh" PATH="$BIN_DIR:$PATH" 2>/dev/null) || EXIT_CODE=$?

    if [[ $EXIT_CODE -eq 0 ]] && echo "$OUTPUT" | grep -q "mock codex"; then
        pass "Legacy BitLesson model '$legacy_model' falls back to codex"
    else
        fail "Legacy BitLesson model '$legacy_model' falls back to codex" \
            "exit 0 + mock codex rationale" "exit=$EXIT_CODE output=$OUTPUT"
    fi
done

# ========================================
# Test 3: Unknown model is rejected
# ========================================

setup_test_dir
create_real_bitlesson "$TEST_DIR/.humanize/bitlesson.md"
mkdir -p "$TEST_DIR/.humanize"
printf '{"bitlesson_model": "unknown-xyz-model"}' > "$TEST_DIR/.humanize/config.json"

EXIT_CODE=0
STDERR_OUT=$(run_selector "$TEST_DIR" "$TEST_DIR/.humanize/bitlesson.md" "Fix a bug" "scripts/bitlesson-select.sh" PATH="$SAFE_BASE_PATH" 2>&1 >/dev/null) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]] && echo "$STDERR_OUT" | grep -qi "unknown"; then
    pass "Unknown BitLesson model is rejected"
else
    fail "Unknown BitLesson model is rejected" "non-zero exit + unknown model error" "exit=$EXIT_CODE stderr=$STDERR_OUT"
fi

# ========================================
# Test 4: Missing codex binary fails clearly
# ========================================

setup_test_dir
create_real_bitlesson "$TEST_DIR/.humanize/bitlesson.md"
mkdir -p "$TEST_DIR/.humanize"
printf '{"bitlesson_model": "gpt-4o"}' > "$TEST_DIR/.humanize/config.json"

EXIT_CODE=0
STDERR_OUT=$(run_selector "$TEST_DIR" "$TEST_DIR/.humanize/bitlesson.md" "Fix a bug" "scripts/bitlesson-select.sh" PATH="$SAFE_BASE_PATH" 2>&1 >/dev/null) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]] && echo "$STDERR_OUT" | grep -qi "codex"; then
    pass "Missing codex binary fails clearly"
else
    fail "Missing codex binary fails clearly" "non-zero exit + codex error" "exit=$EXIT_CODE stderr=$STDERR_OUT"
fi

# ========================================
# Test 5: Placeholder knowledge base short-circuits without codex
# ========================================

setup_test_dir
create_placeholder_bitlesson "$TEST_DIR"
mkdir -p "$TEST_DIR/.humanize"
printf '{"bitlesson_model": "gpt-5.4"}' > "$TEST_DIR/.humanize/config.json"

EXIT_CODE=0
OUTPUT=$(run_selector "$TEST_DIR" "$TEST_DIR/.humanize/bitlesson.md" "Any task" "README.md" PATH="$SAFE_BASE_PATH" 2>/dev/null) || EXIT_CODE=$?

if [[ $EXIT_CODE -eq 0 ]] && echo "$OUTPUT" | grep -q "LESSON_IDS: NONE" && echo "$OUTPUT" | grep -q "no recorded lessons"; then
    pass "Placeholder knowledge base short-circuits without codex"
else
    fail "Placeholder knowledge base short-circuits without codex" \
        "exit 0 + NONE rationale" "exit=$EXIT_CODE output=$OUTPUT"
fi

# ========================================
# Test 6: Codex helper invocation disables hooks and reads prompt from stdin
# ========================================

setup_test_dir
create_real_bitlesson "$TEST_DIR/bitlesson.md"
mkdir -p "$TEST_DIR/.humanize"
printf '{"bitlesson_model": "gpt-5.4"}' > "$TEST_DIR/.humanize/config.json"
BIN_DIR="$TEST_DIR/bin"
STDIN_FILE="$TEST_DIR/codex-stdin.txt"
create_recording_mock_codex "$BIN_DIR" "$STDIN_FILE"

EXIT_CODE=0
OUTPUT=$(run_selector "$TEST_DIR" "$TEST_DIR/bitlesson.md" "Update the goal tracker after verification" "goal-tracker.md" PATH="$BIN_DIR:$SAFE_BASE_PATH" 2>/dev/null) || EXIT_CODE=$?
ARGS="$(cat "$STDIN_FILE.args" 2>/dev/null || true)"
STDIN_CONTENT="$(cat "$STDIN_FILE" 2>/dev/null || true)"

if [[ $EXIT_CODE -eq 0 ]] \
    && echo "$OUTPUT" | grep -q "BL-20260315-tracker-drift" \
    && echo "$ARGS" | grep -q -- '--disable' \
    && echo "$ARGS" | grep -q -- 'codex_hooks' \
    && echo "$ARGS" | grep -q -- '--skip-git-repo-check' \
    && echo "$ARGS" | grep -q -- '--ephemeral' \
    && echo "$ARGS" | grep -q -- 'read-only' \
    && echo "$STDIN_CONTENT" | grep -q "Sub-task description:"; then
    pass "Codex helper invocation disables hooks and reads prompt from stdin"
else
    fail "Codex helper invocation disables hooks and reads prompt from stdin" \
        "exit 0 + direct helper args + stdin prompt" \
        "exit=$EXIT_CODE output=$OUTPUT args=$ARGS stdin=$STDIN_CONTENT"
fi

print_test_summary "Bitlesson Select Routing Test Summary"
