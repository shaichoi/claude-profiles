#!/bin/sh
# dist/install-standalone.sh 를 만듭니다.
#
# 라이브러리와 제거 스크립트를 install.sh 안에 품은 자립형 단일 파일입니다.
# 파일 하나만 있으면 설치가 끝나므로 curl 한 줄 설치나 scp 복사에 씁니다.
#
# 생성 결과는 결정적입니다. 같은 입력이면 항상 같은 바이트가 나옵니다
# (날짜나 커밋 해시를 박지 않습니다). 테스트가 최신 여부를 검사합니다.

set -eu

cd "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

OUT=dist/install-standalone.sh
RAW_URL="${RAW_URL:-https://raw.githubusercontent.com/shaichoi/claude-profiles/main/dist/install-standalone.sh}"
LIB_EOF=__CLAUDE_PROFILES_LIB_EOF__
UNI_EOF=__CLAUDE_PROFILES_UNINSTALL_EOF__

# 구분자가 본문에 들어 있으면 heredoc 이 중간에 끊깁니다.
for pair in "claude-profiles.sh $LIB_EOF" "uninstall.sh $UNI_EOF"; do
  f=${pair% *}; d=${pair#* }
  if grep -q "^$d\$" "$f"; then
    printf '구분자 %s 가 %s 안에 있습니다. bundle.sh 의 구분자를 바꾸세요.\n' "$d" "$f" >&2
    exit 1
  fi
done

mkdir -p dist

{
  printf '%s\n' '#!/bin/sh'
  printf '%s\n' '# claude-profiles 자립형 설치 스크립트'
  printf '%s\n' '#'
  printf '%s\n' '# 이 파일은 bundle.sh 가 자동으로 만듭니다. 직접 고치지 마세요.'
  printf '%s\n' '# 원본: https://github.com/shaichoi/claude-profiles'
  printf '%s\n' '#'
  printf '%s\n' '# 사용법:'
  printf '%s\n' '#   sh install-standalone.sh'
  printf '%s\n' '#   curl -fsSL <URL> | sh'
  printf '%s\n' '#   curl -fsSL <URL> | sh -s -- --default-name work-main'
  printf '%s\n' ''
  printf '%s\n' 'set -eu'
  printf '%s\n' ''
  printf '%s\n' '_cp_bundle_tmp=$(mktemp -d "${TMPDIR:-/tmp}/claude-profiles-bundle.XXXXXX")'
  printf '%s\n' 'trap '"'"'rm -rf "$_cp_bundle_tmp"'"'"' EXIT INT TERM'
  printf '%s\n' ''
  printf '%s\n' "cat > \"\$_cp_bundle_tmp/claude-profiles.sh\" <<'$LIB_EOF'"
  cat claude-profiles.sh
  printf '%s\n' "$LIB_EOF"
  printf '%s\n' ''
  printf '%s\n' "cat > \"\$_cp_bundle_tmp/uninstall.sh\" <<'$UNI_EOF'"
  cat uninstall.sh
  printf '%s\n' "$UNI_EOF"
  printf '%s\n' ''
  printf '%s\n' 'chmod 755 "$_cp_bundle_tmp/uninstall.sh"'
  printf '%s\n' 'CLAUDE_PROFILES_SRC="$_cp_bundle_tmp"'
  printf '%s\n' 'export CLAUDE_PROFILES_SRC'
  printf '%s\n' "CLAUDE_PROFILES_SOURCE_SPEC=\"\${CLAUDE_PROFILES_SOURCE_SPEC:-url:$RAW_URL}\""
  printf '%s\n' 'export CLAUDE_PROFILES_SOURCE_SPEC'
  printf '%s\n' ''
  printf '%s\n' '# ---------------------------------------------------------------- install.sh'
  tail -n +2 install.sh
} > "$OUT.tmp"

sh -n "$OUT.tmp" || { printf '생성된 스크립트의 문법이 잘못됐습니다.\n' >&2; rm -f "$OUT.tmp"; exit 1; }
chmod 755 "$OUT.tmp"
mv "$OUT.tmp" "$OUT"

printf '%s (%s줄, %s바이트)\n' "$OUT" "$(wc -l < "$OUT" | tr -d ' ')" "$(wc -c < "$OUT" | tr -d ' ')"
