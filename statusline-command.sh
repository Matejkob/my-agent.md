#!/bin/bash

# Read JSON input
input=$(cat)

# Extract data from JSON
current_dir=$(echo "$input" | jq -r '.workspace.current_dir')
context_window=$(echo "$input" | jq '.context_window')
cost_total=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')
duration_ms=$(echo "$input" | jq -r '.cost.total_duration_ms // 0')

# Color definitions
WHITE='\033[38;5;255m'
GRAY='\033[38;5;246m'
RESET='\033[0m'

# Function to abbreviate numbers
abbreviate_number() {
    local num=$1
    if [ "$num" -ge 1000 ]; then
        local k=$(awk "BEGIN {printf \"%.1f\", $num/1000}")
        echo "${k}k"
    else
        echo "$num"
    fi
}

# Get directory name
dir_name=$(basename "$current_dir")

# Get git info if in a git repo
if [ -d "$current_dir/.git" ] || git -C "$current_dir" rev-parse --git-dir > /dev/null 2>&1; then
    branch=$(git -C "$current_dir" rev-parse --abbrev-ref HEAD 2>/dev/null)

    # Get diff stats (unstaged + staged)
    diff_stats=$(git -C "$current_dir" -c core.fileMode=false diff --numstat 2>/dev/null | awk '{added+=$1; removed+=$2} END {print added+0, removed+0}')
    diff_stats_staged=$(git -C "$current_dir" -c core.fileMode=false diff --cached --numstat 2>/dev/null | awk '{added+=$1; removed+=$2} END {print added+0, removed+0}')

    read -r added removed <<< "$diff_stats"
    read -r added_staged removed_staged <<< "$diff_stats_staged"

    added=$((${added:-0} + ${added_staged:-0}))
    removed=$((${removed:-0} + ${removed_staged:-0}))
else
    branch=""
    added=0
    removed=0
fi

# Calculate context window usage
usage=$(echo "$context_window" | jq '.current_usage')
if [ "$usage" != "null" ]; then
    current=$(echo "$usage" | jq '.input_tokens + .cache_creation_input_tokens + .cache_read_input_tokens')
    size=$(echo "$context_window" | jq '.context_window_size')
    pct=$((current * 100 / size))

    # Build progress bar with orange filled blocks
    filled=$((pct / 10))
    empty=$((10 - filled))

    bar="${GRAY}["
    for ((i=0; i<filled; i++)); do
        bar="${bar}${WHITE}█${GRAY}"
    done
    for ((i=0; i<empty; i++)); do
        bar="${bar}░"
    done
    bar="${bar}]${RESET}"

    context_display="${bar} ${WHITE}${pct}%${RESET}"
else
    context_display="${GRAY}[░░░░░░░░░░]${RESET} ${WHITE}0%${RESET}"
fi

# Build output
output="${WHITE}${dir_name}${RESET}"

# Add branch if available
if [ -n "$branch" ]; then
    output="${output} ${GRAY}|${RESET} ${WHITE}${branch}${RESET}"
fi

# Add diff stats with abbreviation
if [ "$added" -gt 0 ] || [ "$removed" -gt 0 ]; then
    output="${output} ${GRAY}|${RESET}"

    if [ "$added" -gt 0 ]; then
        added_abbr=$(abbreviate_number "$added")
        output="${output} ${GRAY}+${RESET}${WHITE}${added_abbr}${RESET}"
    fi

    if [ "$removed" -gt 0 ]; then
        removed_abbr=$(abbreviate_number "$removed")
        output="${output} ${GRAY}-${RESET}${WHITE}${removed_abbr}${RESET}"
    fi
fi

# Add context window
output="${output} ${GRAY}|${RESET} ${context_display}"

# Add cost
cost_formatted=$(printf "%.2f" "$cost_total")
output="${output} ${GRAY}|${RESET} ${GRAY}\$${RESET}${WHITE}${cost_formatted}${RESET}"

# Add duration
duration_sec=$((duration_ms / 1000))
minutes=$((duration_sec / 60))
seconds=$((duration_sec % 60))
output="${output} ${GRAY}|${RESET} ${WHITE}${minutes}${RESET}${GRAY}m${RESET} ${WHITE}${seconds}${RESET}${GRAY}s${RESET}"

printf "%b\n" "$output"
