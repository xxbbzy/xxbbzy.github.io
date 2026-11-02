#!/usr/bin/env bash
set -euo pipefail

if (( $# > 1 )); then
  printf 'Usage: %s [build-directory]\n' "$0" >&2
  exit 2
fi

output_dir=${1:-./public}
site_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
base_url='https://xxbbzy.github.io'
failures=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; failures=$((failures + 1)); }

for name in index.html sitemap.xml index.xml index.json llms.txt llms-full.txt; do
  if [[ -f "$output_dir/$name" && -s "$output_dir/$name" ]]; then
    pass "$name exists and is nonempty"
  else
    fail "$name is missing, empty, or not a regular file"
  fi
done

# Only inspect the YAML frontmatter, not draft examples in article bodies.
is_published() {
  local line published=false
  local draft_pattern='^draft:[[:space:]]*false[[:space:]]*(#.*)?$'
  IFS= read -r line || return 1
  [[ ${line%$'\r'} == '---' ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    line=${line%$'\r'}
    [[ "$line" == '---' || "$line" == '...' ]] && break
    if [[ "$line" =~ $draft_pattern ]]; then
      published=true
    fi
  done
  [[ "$published" == true ]]
}

if [[ -d "$site_dir/content/posts" ]]; then
  while IFS= read -r -d '' article; do
    if ! is_published < "$article"; then
      continue
    fi
    relative=${article#"$site_dir/content/"}
    relative=${relative%.*}
    # Leaf bundles use the containing directory as their URL.
    case "$relative" in
      */_index) continue ;;
      */index) relative=${relative%/index} ;;
    esac
    url="$base_url/$relative/"
    if [[ -f "$output_dir/llms.txt" ]] && grep -Fq -- "$url" "$output_dir/llms.txt"; then
      pass "llms.txt includes $url"
    else
      fail "llms.txt does not include $url"
    fi
  done < <(find "$site_dir/content/posts" -type f \( -name '*.md' -o -name '*.markdown' \) -print0)
else
  fail 'content/posts directory is missing'
fi

# Match complete IPv4 addresses and skip binary files with grep -I.
octet='(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])'
private_address="(^|[^[:alnum:]_])(192[.]168[.]$octet[.]$octet|10[.]$octet[.]$octet[.]$octet)([^[:alnum:]_]|$)"
if [[ ! -d "$output_dir" ]]; then
  fail 'text scan: build directory is missing'
elif grep -rIlE -- "$private_address|password=|token=" "$output_dir"; then
  fail 'text scan: forbidden patterns found in the files listed above'
else
  scan_status=$?
  if (( scan_status == 1 )); then
    pass 'text scan: no forbidden patterns'
  else
    fail 'text scan: could not read all build files'
  fi
fi

welcome_url="$base_url/posts/welcome/"
if [[ -f "$output_dir/sitemap.xml" ]] && grep -Fq -- "$welcome_url" "$output_dir/sitemap.xml"; then
  pass "sitemap.xml includes $welcome_url"
else
  fail "sitemap.xml does not include $welcome_url"
fi

if (( failures > 0 )); then
  exit 1
fi
