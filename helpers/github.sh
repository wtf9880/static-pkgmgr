# helpers/github.sh -- spm_github_find_asset (§8, §14).
#
# This file is sourced by recipes (into the recipe subprocess). It must not
# alter the caller's shell options.
# shellcheck shell=bash

# spm_github_find_asset <owner/repo> <tag_regex> <asset_regex> [requested]
# List releases for <owner/repo> via the GitHub API, select the latest tag
# matching <tag_regex> (or the one matching [requested]), select the asset
# whose name matches <asset_regex>, and print one JSON object:
#   {"version","tag","name","url","digest"}
#
#   version  tag without a leading "v"
#   tag      the git tag name
#   name     the selected asset's file name
#   url      the asset's browser_download_url
#   digest   the asset's sha256 when present, else null (the recipe then
#            provides a checksum, e.g. via spm_http_sha256)
#
# Authorization is sent only when $GITHUB_TOKEN is set, and only to
# api.github.com / github.com. Releases are fetched newest-first with
# per_page=100, so a single page is enough for these repositories. (§8, §14)
spm_github_find_asset() {
	local repo="$1" tregex="$2" aregex="$3" requested="${4-}"
	local token="${GITHUB_TOKEN:-}" resp
	if [ -n "$token" ]; then
		resp=$(curl -fsSL \
			-H "Authorization: token $token" \
			-H 'Accept: application/vnd.github+json' \
			"https://api.github.com/repos/$repo/releases?per_page=100" \
			2>/dev/null) || {
			printf 'spm_github_find_asset: API request failed for %s\n' "$repo" >&2
			return 1
		}
	else
		resp=$(curl -fsSL \
			-H 'Accept: application/vnd.github+json' \
			"https://api.github.com/repos/$repo/releases?per_page=100" \
			2>/dev/null) || {
			printf 'spm_github_find_asset: API request failed for %s\n' "$repo" >&2
			return 1
		}
	fi
	# Select the first release whose tag matches the regex (and, when
	# requested, the tag equal to it or "v"+it), then the first matching asset.
	# jq variables are declared BEFORE the filter so the program stays literal.
	printf '%s' "$resp" | jq -c \
		--arg trex "$tregex" \
		--arg aregex "$aregex" \
		--arg req "$requested" '
		( [ .[] | select(.tag_name | test($trex)) ]
		  | if ($req | length) > 0
		    then map(select(.tag_name == $req or .tag_name == ("v" + $req)))
		    else .
		    end
		  | first
		) as $r
		| ( if $r == null
		    then null
		    else ($r.assets // []) | map(select(.name | test($aregex))) | first
		    end
		) as $a
		| if $r == null
		  then error("spm_github_find_asset: no release matching tag regex /\($trex)/")
		  elif $a == null
		  then error("spm_github_find_asset: no asset matching /\($aregex)/ in \($r.tag_name)")
		  else {version: ($r.tag_name | sub("^v"; "")),
		          tag: $r.tag_name,
		          name: $a.name,
		          url: $a.browser_download_url,
		          digest: ($a.digest // null)}
		  end
	'
}
