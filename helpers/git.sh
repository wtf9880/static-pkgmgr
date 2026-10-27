# helpers/git.sh -- spm_git_latest_tag (§8).
#
# This file is sourced by recipes (into the recipe subprocess). It must not
# alter the caller's shell options.
# shellcheck shell=bash

# spm_git_latest_tag <repo_url> <tag_regex> [requested]
# Print the latest tag in <repo_url> whose name matches <tag_regex>. Tags are
# listed with `git ls-remote --tags --refs --sort=-v:refname` (sorted newest
# first by version), so the first match is the latest. This never clones the
# repository: `git ls-remote` only reads refs.
#
# Arguments:
#   <repo_url>    a remote URL (e.g. https://github.com/owner/repo) or a local
#                 repository path.
#   <tag_regex>   an extended regex the tag name must match (e.g. "v[0-9.]+").
#   [requested]   when set, only the tag equal to it (or "v"+it) is considered.
# Returns non-zero when no matching tag is found or the remote is unreachable. (§8)
spm_git_latest_tag() {
	local repo="$1" tregex="$2" requested="${3-}" tag ref
	local out
	if ! out=$(git ls-remote --tags --refs --sort=-v:refname "$repo" 2>/dev/null); then
		printf 'spm_git_latest_tag: ls-remote failed: %s\n' "$repo" >&2
		return 1
	fi
	# Rows are "<sha>\trefs/tags/<tag>". Annotated tags produce two rows each:
	# "refs/tags/<tag>" and "refs/tags/<tag>^{}"; skip the deref ("^{}") row.
	while IFS=$'\t' read -r _ ref; do
		[ -n "$ref" ] || continue
		case "$ref" in refs/tags/*) ;; *) continue ;; esac
		tag=${ref#refs/tags/}
		case "$tag" in *'^{}') continue ;; esac
		# $tregex is a variable, so it is intentionally unquoted here.
		[[ "$tag" =~ $tregex ]] || continue
		if [ -n "$requested" ]; then
			if [ "$tag" != "$requested" ] && [ "$tag" != "v$requested" ]; then
				continue
			fi
		fi
		printf '%s\n' "$tag"
		return 0
	done <<< "$out"
	printf 'spm_git_latest_tag: no tag matching %s in %s\n' "$tregex" "$repo" >&2
	return 1
}
