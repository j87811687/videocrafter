#!/usr/bin/env bash
set -euo pipefail

# validator.sh
# Validates and sanitizes:
#   - setup/on_start_script
#   - setup/setup_script
#
# Produces:
#   - setup/on_start_script.fixed
#   - setup/setup_script.fixed

TARGET_FILES=(
	"setup/on_start_script"
	"setup/setup_script"
)

# -------- Utility: detect if perl / python / unexpand exist --------
have_cmd() {
	command -v "$1" >/dev/null 2>&1
}

if ! have_cmd perl; then
	echo "❌ perl is required for Unicode-safe transformations." >&2
	exit 1
fi

if ! have_cmd python3; then
	echo "❌ python3 is required for some structural fixes." >&2
	exit 1
fi

if ! have_cmd unexpand; then
	echo "❌ unexpand is required for tab-normalization." >&2
	exit 1
fi

# -------- Check + fix functions --------

check_non_ascii_spaces() {
	local file="$1"
	# NBSP, figure spaces, narrow no-break, etc.
	if LC_ALL=C grep -Pq "\xC2\xA0|\xE2\x80\x87|\xE2\x80\xAF" "$file"; then
		echo "  • non-ASCII spaces detected"
		return 0
	fi
	return 1
}

fix_non_ascii_spaces() {
	local in="$1" out="$2"
	perl -CS -pe 's/\x{00A0}/ /g; s/\x{2007}/ /g; s/\x{202F}/ /g;' "$in" > "$out"
}

check_non_ascii_punct() {
	local file="$1"
	# curly quotes, en dash, em dash, ellipsis
	if LC_ALL=C grep -Pq "\xE2\x80[\x93\x94\x98-\x9D]|\xE2\x80\xA6" "$file"; then
		echo "  • non-ASCII punctuation detected"
		return 0
	fi
	return 1
}

fix_non_ascii_punct() {
	local in="$1" out="$2"
	perl -CS -pe '
		s/\x{201C}/"/g;  # “
		s/\x{201D}/"/g;  # ”
		s/\x{2018}/'\''/g; # ‘
		s/\x{2019}/'\''/g; # ’
		s/\x{2013}/-/g;  # –
		s/\x{2014}/-/g;  # —
		s/\x{2026}/.../g; # …
	' "$in" > "$out"
}

check_invisible_controls() {
	local file="$1"
	# control chars except tab (0x09) and newline (0x0A)
	if LC_ALL=C grep -Pq "[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]" "$file"; then
		echo "  • invisible control characters detected"
		return 0
	fi
	return 1
}

fix_invisible_controls() {
	local in="$1" out="$2"
	LC_ALL=C tr -d '\000-\010\013\014\016-\037\177' < "$in" > "$out"
}

check_mixed_line_endings() {
	local file="$1"
	# detect CR characters
	if LC_ALL=C grep -q $'\r' "$file"; then
		echo "  • mixed / Windows line endings detected"
		return 0
	fi
	return 1
}

fix_mixed_line_endings() {
	local in="$1" out="$2"
	# strip trailing CR
	perl -pe 's/\r$//g' "$in" > "$out"
}

check_hidden_bash_breakers() {
	local file="$1"
	# NBSP + zero-width characters
	if LC_ALL=C grep -Pq "\xC2\xA0|\xE2\x80\x8B|\xE2\x80\x8C|\xE2\x80\x8D|\xEF\xBB\xBF" "$file"; then
		echo "  • hidden Bash-breaking characters detected (NBSP / ZWSP / BOM)"
		return 0
	fi
	return 1
}

fix_hidden_bash_breakers() {
	local in="$1" out="$2"
	perl -CS -pe '
		s/\x{00A0}/ /g;    # NBSP -> space (redundant with non-ASCII-space fix but safe)
		s/\x{200B}//g;     # ZWSP
		s/\x{200C}//g;     # ZWNJ
		s/\x{200D}//g;     # ZWJ
		s/\x{FEFF}//g;     # BOM
	' "$in" > "$out"
}

check_unicode_in_paths_vars() {
	local file="$1"
	# Any non-ASCII on lines containing / or = or $var, but ignore echo lines (emoji allowed there)
	if LC_ALL=C grep -Pn "^[[:space:]]*(?!echo\b).*[/=\$].*[\x80-\xFF]" "$file" >/dev/null 2>&1; then
		echo "  • Unicode in file paths / variables detected (excluding echo lines)"
		return 0
	fi
	return 1
}

fix_unicode_in_paths_vars() {
	local in="$1" out="$2"
	# Conservative approach: we do NOT aggressively strip here beyond punctuation/space fixes,
	# so for this category we just pass the content through, relying on other fixes.
	cat "$in" > "$out"
}

check_non_tab_indent() {
	local file="$1"
	# lines starting with spaces (but not empty)
	if LC_ALL=C grep -Pq "^[ ]+[^ ]" "$file"; then
		echo "  • non-tab indentation detected (leading spaces)"
		return 0
	fi
	return 1
}

fix_non_tab_indent() {
	local in="$1" out="$2"
	# convert leading spaces to tabs using unexpand (4-space tab stops)
	# acts only on leading spaces with --first-only
	unexpand -t 4 --first-only "$in" > "$out"
}

check_missing_newline_blocks() {
	local file="$1"
	# Major block header pattern: lines starting with "# ----"
	# Find headers not preceded by a blank line (ignoring very first line)
	if python3 - "$file" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8", errors="ignore") as f:
	lines = f.readlines()

problems = False
for i, line in enumerate(lines):
	if line.startswith("# ----"):
		if i > 0 and lines[i-1].strip() != "":
			problems = True
			break

sys.exit(0 if problems else 1)
PYEOF
	then
		echo "  • missing blank line before major block header(s)"
		return 0
	fi
	return 1
}

fix_missing_newline_blocks() {
	local in="$1" out="$2"
	python3 - "$in" > "$out" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8", errors="ignore") as f:
	lines = f.readlines()

result = []
for i, line in enumerate(lines):
	if line.startswith("# ----") and i > 0 and result and result[-1].strip() != "":
		# Insert a blank line before the header if previous line is non-empty
		result.append("\n")
	result.append(line)

sys.stdout.write("".join(result))
PYEOF
}

# -------- Orchestrator for a single file --------

process_file() {
	local file="$1"

	if [ ! -f "$file" ]; then
		echo "❌ Skipping $file — file does not exist."
		return
	fi

	echo "=== Validating: $file ==="

	# Start with original as working copy
	local work
	work="$(mktemp)"
	cp "$file" "$work"

	local changed=0

	# Each step: check → report → fix (into new temp) → move back
	run_step() {
		local name="$1" check_fn="$2" fix_fn="$3"

		if "$check_fn" "$work"; then
			echo "    Auto-fixing: $name"
			local tmp
			tmp="$(mktemp)"
			"$fix_fn" "$work" "$tmp"
			mv "$tmp" "$work"
			changed=1
		fi
	}

	run_step "non-ASCII spaces"           check_non_ascii_spaces      fix_non_ascii_spaces
	run_step "non-ASCII punctuation"      check_non_ascii_punct       fix_non_ascii_punct
	run_step "invisible control chars"    check_invisible_controls    fix_invisible_controls
	run_step "mixed line endings"         check_mixed_line_endings    fix_mixed_line_endings
	run_step "hidden Bash-breakers"       check_hidden_bash_breakers  fix_hidden_bash_breakers
	run_step "Unicode in paths/vars"      check_unicode_in_paths_vars fix_unicode_in_paths_vars
	run_step "non-tab indentation"        check_non_tab_indent        fix_non_tab_indent
	run_step "missing newline between blocks" check_missing_newline_blocks fix_missing_newline_blocks

	local out="${file}.fixed"
	if [ "$changed" -eq 1 ]; then
		mv "$work" "$out"
		echo "✅ Wrote sanitized file: $out"
	else
		rm -f "$work"
		echo "✅ No issues found — no .fixed file created."
	fi
	echo
}

# -------- Main --------

for f in "${TARGET_FILES[@]}"; do
	process_file "$f"
done
