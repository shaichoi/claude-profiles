#!/bin/sh
# claude-profiles 자립형 설치 스크립트
#
# 이 파일은 bundle.sh 가 자동으로 만듭니다. 직접 고치지 마세요.
# 원본: https://github.com/shaichoi/claude-profiles
#
# 사용법:
#   sh install-standalone.sh
#   curl -fsSL <URL> | sh
#   curl -fsSL <URL> | sh -s -- --default-name work-main

set -eu

_cp_bundle_tmp=$(mktemp -d "${TMPDIR:-/tmp}/claude-profiles-bundle.XXXXXX")
trap 'rm -rf "$_cp_bundle_tmp"' EXIT INT TERM

cat > "$_cp_bundle_tmp/claude-profiles.sh" <<'__CLAUDE_PROFILES_LIB_EOF__'
# Claude Code 계정 프로필 전환 (bash / zsh 공용)
#
# 이 파일은 대화형 셸에서 source 됩니다.
# 따라서 절대로 set -e / set -u / exit 를 쓰지 않습니다. 사용자의 셸이 죽습니다.
#
# 동작 원리
#   Claude Code 는 CLAUDE_CONFIG_DIR 로 설정 디렉터리를 정하고,
#   자격 증명(.credentials.json)도 그 디렉터리에 둡니다.
#   따라서 디렉터리를 나누면 계정이 완전히 분리됩니다.
#
#   기본 프로필 default = ~/.claude (변수를 해제한 상태)
#   추가 프로필        = $CLAUDE_PROFILE_ROOT/<이름>
#
#   계정과 무관한 항목(설정, 대화 기록, 기억, 플러그인 등)은 ~/.claude 로
#   심볼릭 링크하므로 계정을 바꿔도 --continue 와 기억이 유지됩니다.

CLAUDE_PROFILES_VERSION="1.1.0"

CLAUDE_PROFILE_ROOT="${CLAUDE_PROFILE_ROOT:-$HOME/.claude-profiles}"
export CLAUDE_PROFILE_ROOT

# 이 패키지가 설치된 위치. install.sh 가 rc 블록에 넣어 줍니다.
CLAUDE_PROFILES_HOME="${CLAUDE_PROFILES_HOME:-$HOME/.local/share/claude-profiles}"
export CLAUDE_PROFILES_HOME

# 기본 프로필(~/.claude)에 붙일 이름. 계정 이름으로 부르고 싶을 때 씁니다.
#   export CLAUDE_PROFILE_DEFAULT_NAME=work-main
# 설정해도 default 라는 이름은 계속 통합니다.
CLAUDE_PROFILE_DEFAULT_NAME="${CLAUDE_PROFILE_DEFAULT_NAME:-default}"
export CLAUDE_PROFILE_DEFAULT_NAME

# 프로필 사이에 공유할 항목 (공백으로 구분, 공백이 든 이름은 지원하지 않습니다)
CLAUDE_PROFILE_SHARED="${CLAUDE_PROFILE_SHARED:-settings.json projects plugins hooks commands agents skills CLAUDE.md}"

# ---------------------------------------------------------------- 내부 유틸

# JSON 문자열 값의 이스케이프를 되돌립니다. \uXXXX 는 그대로 둡니다.
_claude_profile_unescape() {
  awk '
    {
      s = $0; out = ""; i = 1; n = length(s)
      while (i <= n) {
        c = substr(s, i, 1)
        if (c == "\\" && i < n) {
          d = substr(s, i + 1, 1)
          if (d == "n")      { out = out "\n";              i += 2 }
          else if (d == "t") { out = out "\t";              i += 2 }
          else if (d == "r") { out = out "\r";              i += 2 }
          else if (d == "u") { out = out substr(s, i, 6);   i += 6 }
          else               { out = out d;                 i += 2 }
        } else { out = out c; i++ }
      }
      print out
    }
  '
}

# JSON(표준 입력)에서 문자열 값을 꺼냅니다. 없거나 null 이면 빈 문자열.
# python3 나 jq 없이 동작해야 하므로 sed + awk 만 씁니다.
_claude_profile_json_str() {
  local key="$1"
  tr '\n' ' ' \
    | sed -n -E 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*"((\\.|[^"\\])*)".*/\1/p' \
    | _claude_profile_unescape
}

# JSON(표준 입력)에서 true/false 를 꺼냅니다.
_claude_profile_json_bool() {
  local key="$1"
  tr '\n' ' ' \
    | sed -n -E 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*(true|false).*/\1/p'
}

# 프로필 이름 검증. 경로 탈출(../)과 숨김 이름을 막습니다.
_claude_profile_valid_name() {
  case "$1" in
    '' | . | ..)        return 1 ;;
    .*)                 return 1 ;;
    *[!A-Za-z0-9._-]*)  return 1 ;;
  esac
  return 0
}

# 실제로 쓸 기본 프로필 이름.
# 이름이 잘못됐거나 같은 이름의 프로필 디렉터리가 있으면 default 로 되돌립니다.
# (별칭이 이기면 같은 이름의 프로필 계정에 접근할 수 없게 됩니다.)
_claude_profile_default_name() {
  local n="$CLAUDE_PROFILE_DEFAULT_NAME"
  if [ "$n" = default ] || ! _claude_profile_valid_name "$n"; then
    printf '%s\n' default
  elif [ -d "$CLAUDE_PROFILE_ROOT/$n" ]; then
    printf '%s\n' default
  else
    printf '%s\n' "$n"
  fi
}

# 이름 -> 설정 디렉터리 경로
_claude_profile_dir() {
  if [ -z "$1" ] || [ "$1" = default ] || [ "$1" = "$(_claude_profile_default_name)" ]; then
    printf '%s\n' "$HOME/.claude"
  else
    printf '%s\n' "$CLAUDE_PROFILE_ROOT/$1"
  fi
}

# 현재 셸이 쓰는 프로필 이름
_claude_profile_name() {
  local dir
  dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  dir="${dir%/}"
  if [ "$dir" = "$HOME/.claude" ]; then
    _claude_profile_default_name
  else
    printf '%s\n' "${dir##*/}"
  fi
}

# 프로필 디렉터리 목록 (한 줄에 하나).
# zsh 는 글롭이 안 맞으면 에러를 내므로 find 로 열거합니다.
_claude_profile_dirs() {
  [ -d "$CLAUDE_PROFILE_ROOT" ] || return 0
  find "$CLAUDE_PROFILE_ROOT" -mindepth 1 -maxdepth 1 2>/dev/null | LC_ALL=C sort | while IFS= read -r d; do
    [ -d "$d" ] || continue
    printf '%s\n' "$d"
  done
}

# 자동 완성용 이름 목록
_claude_profile_names() {
  local dn
  dn="$(_claude_profile_default_name)"
  printf '%s\n' "$dn"
  [ "$dn" = default ] || printf '%s\n' default
  _claude_profile_dirs | while IFS= read -r d; do
    printf '%s\n' "${d##*/}"
  done
}

# 프로필 디렉터리를 만들고 공유 항목을 ~/.claude 로 링크합니다.
# 이미 있는 항목은 건드리지 않고, 빠진 링크만 추가합니다.
_claude_profile_init() {
  local dir="$1" item
  mkdir -p "$dir" || return 1
  chmod 700 "$dir" 2>/dev/null
  # zsh 는 따옴표 없는 변수를 단어 분리하지 않으므로 파이프로 순회합니다.
  printf '%s\n' "$CLAUDE_PROFILE_SHARED" | tr ' ' '\n' | while IFS= read -r item; do
    [ -n "$item" ] || continue
    [ -e "$HOME/.claude/$item" ] || continue
    if [ -e "$dir/$item" ] || [ -L "$dir/$item" ]; then
      continue
    fi
    ln -s "$HOME/.claude/$item" "$dir/$item"
  done
  return 0
}

# claude auth status 의 JSON 을 그대로 돌려줍니다.
# 기본 프로필은 반드시 변수를 해제하고 조회합니다.
# 같은 경로라도 CLAUDE_CONFIG_DIR 을 명시하면 email/orgName 이 null 로 나옵니다.
_claude_profile_status_json() {
  local dir="${1%/}"
  command -v claude >/dev/null 2>&1 || return 1
  if [ "$dir" = "$HOME/.claude" ]; then
    ( unset CLAUDE_CONFIG_DIR; claude auth status 2>/dev/null )
  else
    ( CLAUDE_CONFIG_DIR="$dir"; export CLAUDE_CONFIG_DIR; claude auth status 2>/dev/null )
  fi
}

# 설정 디렉터리의 로그인 계정을 한 줄로 출력합니다. 로그인 상태면 0 을 반환합니다.
# claude auth status 는 미로그인 시 종료 코드 1 이므로 코드가 아니라 JSON 을 봅니다.
_claude_profile_account() {
  local dir="${1%/}" json logged email org plan out
  if ! command -v claude >/dev/null 2>&1; then
    printf '%s\n' "claude CLI 를 찾을 수 없음"
    return 1
  fi
  json="$(_claude_profile_status_json "$dir")"
  if [ -z "$json" ]; then
    printf '%s\n' "상태 확인 실패"
    return 1
  fi
  logged="$(printf '%s' "$json" | _claude_profile_json_bool loggedIn)"
  if [ "$logged" != "true" ]; then
    printf '%s\n' "로그인 안 됨"
    return 1
  fi
  email="$(printf '%s' "$json" | _claude_profile_json_str email)"
  org="$(printf '%s' "$json" | _claude_profile_json_str orgName)"
  plan="$(printf '%s' "$json" | _claude_profile_json_str subscriptionType)"
  if [ -z "$email" ]; then
    email="$(printf '%s' "$json" | _claude_profile_json_str authMethod)"
  fi
  [ -n "$email" ] || email="?"
  out="$email"
  [ -n "$org" ] && out="$out / $org"
  [ -n "$plan" ] && out="$out / $plan"
  # 값에 줄바꿈이나 탭이 들어와도 한 줄로 표시합니다.
  printf '%s' "$out" | tr '\n\r\t' '   '
  printf '\n'
  return 0
}

# ---------------------------------------------------------------- 사용자 명령

# 현재 셸의 프로필을 바꿉니다.  예) claude-use personal
claude-use() {
  local name="$1" dir account ok
  if [ -z "$name" ]; then
    printf '%s\n' "사용법: claude-use <프로필 이름>   (기본 계정은 default)" >&2
    claude-profiles -q
    return 1
  fi
  if ! _claude_profile_valid_name "$name"; then
    printf '%s\n' "프로필 이름은 영문/숫자/. _ - 만 쓸 수 있습니다: $name" >&2
    return 1
  fi
  dir="$(_claude_profile_dir "$name")"
  if [ "$dir" = "$HOME/.claude" ]; then
    unset CLAUDE_CONFIG_DIR
  else
    _claude_profile_init "$dir" || return 1
    CLAUDE_CONFIG_DIR="$dir"
    export CLAUDE_CONFIG_DIR
  fi
  account="$(_claude_profile_account "$dir")"
  ok=$?
  printf '%s\n' "프로필 전환: $(_claude_profile_name)  ($dir)"
  printf '%s\n' "  계정: $account"
  [ "$ok" -ne 0 ] && printf '%s\n' "  이 셸에서 claude auth login 으로 로그인하세요."
  return 0
}

# 현재 셸이 쓰는 프로필과 계정을 표시합니다.
claude-who() {
  local dir
  dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  printf '%s\n' "프로필 $(_claude_profile_name)  (${dir%/})"
  printf '%s\n' "  계정: $(_claude_profile_account "$dir")"
  return 0
}

# 프로필 목록과 각 계정을 표시합니다.
#   -q  계정 조회를 건너뜁니다 (프로필 하나당 1초쯤 걸립니다)
claude-profiles() {
  local quick=0 active dir name mark
  case "$1" in
    -q | --quick) quick=1 ;;
    -h | --help)
      printf '%s\n' "사용법: claude-profiles [-q|-v]   (-q 계정 조회 생략, -v 버전)"
      return 0 ;;
    -v | --version)
      printf 'claude-profiles %s\n' "$CLAUDE_PROFILES_VERSION"
      printf '  스크립트   : %s\n' "$CLAUDE_PROFILES_HOME/claude-profiles.sh"
      printf '  프로필 데이터: %s\n' "$CLAUDE_PROFILE_ROOT"
      if [ -f "$CLAUDE_PROFILES_HOME/install-info" ]; then
        sed -n 's/^source=/  설치 출처   : /p; s/^installed=/  설치 시각   : /p' \
          "$CLAUDE_PROFILES_HOME/install-info"
      fi
      return 0 ;;
  esac
  active="$(_claude_profile_name)"
  {
    printf '%s\n' "$HOME/.claude"
    _claude_profile_dirs
  } | while IFS= read -r dir; do
    name="$(_claude_profile_default_name)"
    [ "$dir" != "$HOME/.claude" ] && name="${dir##*/}"
    mark="  "
    [ "$name" = "$active" ] && mark="* "
    if [ "$quick" -eq 1 ]; then
      printf '%s\n' "$mark$name"
    else
      printf '%s\n' "$mark$name  —  $(_claude_profile_account "$dir")"
    fi
  done
  return 0
}

# 셸 프로필은 그대로 두고 한 번만 다른 계정으로 실행합니다.
#   claude-with personal -p "안녕"
claude-with() {
  local name="$1" dir
  if [ -z "$name" ]; then
    printf '%s\n' "사용법: claude-with <프로필 이름> [claude 인자...]" >&2
    return 1
  fi
  if ! _claude_profile_valid_name "$name"; then
    printf '%s\n' "프로필 이름은 영문/숫자/. _ - 만 쓸 수 있습니다: $name" >&2
    return 1
  fi
  shift
  dir="$(_claude_profile_dir "$name")"
  if [ "$dir" = "$HOME/.claude" ]; then
    ( unset CLAUDE_CONFIG_DIR; claude "$@" )
  else
    _claude_profile_init "$dir" || return 1
    ( CLAUDE_CONFIG_DIR="$dir"; export CLAUDE_CONFIG_DIR; claude "$@" )
  fi
}

# 별칭을 쓸 수 없는 상황이면 셸을 열 때 한 번만 알려 줍니다.
if [ "$CLAUDE_PROFILE_DEFAULT_NAME" != "$(_claude_profile_default_name)" ]; then
  printf '%s\n' "claude-profiles: CLAUDE_PROFILE_DEFAULT_NAME='$CLAUDE_PROFILE_DEFAULT_NAME' 을 쓸 수 없어 default 를 씁니다." >&2
  printf '%s\n' "  (이름 규칙에 어긋나거나 $CLAUDE_PROFILE_ROOT 에 같은 이름의 프로필이 있습니다.)" >&2
fi

# 설치 출처에서 다시 받아 재설치합니다. 설치는 멱등이라 여러 번 해도 안전합니다.
claude-profiles-update() {
  local info src url path
  info="$CLAUDE_PROFILES_HOME/install-info"
  if [ ! -f "$info" ]; then
    printf '%s\n' "설치 정보를 찾을 수 없습니다: $info" >&2
    printf '%s\n' "저장소에서 ./install.sh 를 다시 실행하세요." >&2
    return 1
  fi
  src="$(sed -n 's/^source=//p' "$info" | head -1)"
  case "$src" in
    url:*)
      url="${src#url:}"
      printf '%s\n' "내려받는 중: $url"
      # 캐시된 예전 파일을 받지 않도록 쿼리를 붙입니다.
      if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url?t=$(date +%s)" | sh -s -- --no-prompt --prefix "$CLAUDE_PROFILES_HOME" || return 1
      elif command -v wget >/dev/null 2>&1; then
        wget -qO- "$url?t=$(date +%s)" | sh -s -- --no-prompt --prefix "$CLAUDE_PROFILES_HOME" || return 1
      else
        printf '%s\n' "curl 또는 wget 이 필요합니다." >&2
        return 1
      fi
      ;;
    git:*)
      path="${src#git:}"
      if [ ! -d "$path" ]; then
        printf '%s\n' "저장소를 찾을 수 없습니다: $path" >&2
        return 1
      fi
      printf '%s\n' "저장소 갱신: $path"
      git -C "$path" pull --ff-only || {
        printf '%s\n' "git pull 실패. 저장소에서 직접 정리한 뒤 다시 시도하세요." >&2
        return 1
      }
      "$path/install.sh" --no-prompt --prefix "$CLAUDE_PROFILES_HOME" || return 1
      ;;
    dir:*)
      path="${src#dir:}"
      if [ ! -x "$path/install.sh" ]; then
        printf '%s\n' "설치 스크립트를 찾을 수 없습니다: $path/install.sh" >&2
        return 1
      fi
      "$path/install.sh" --no-prompt --prefix "$CLAUDE_PROFILES_HOME" || return 1
      ;;
    *)
      printf '%s\n' "알 수 없는 설치 출처: $src" >&2
      return 1 ;;
  esac
  printf '%s\n' "업데이트 완료. 새 셸을 열거나 rc 를 다시 읽으세요."
  return 0
}

# ---------------------------------------------------------------- 자동 완성
# 셸 전용 문법은 eval 안에 둡니다. 반대쪽 셸은 파싱조차 하지 않습니다.

if [ -n "${BASH_VERSION:-}" ]; then
  eval '
  _claude_profile_bash_complete() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    COMPREPLY=( $(compgen -W "$(_claude_profile_names)" -- "$cur") )
  }
  complete -F _claude_profile_bash_complete claude-use claude-with
  '
fi

if [ -n "${ZSH_VERSION:-}" ]; then
  eval '
  _claude_profile_zsh_complete() {
    local -a names
    names=(${(f)"$(_claude_profile_names)"})
    compadd -a names
  }
  if command -v compdef >/dev/null 2>&1; then
    compdef _claude_profile_zsh_complete claude-use claude-with
  fi
  '
fi
__CLAUDE_PROFILES_LIB_EOF__

cat > "$_cp_bundle_tmp/uninstall.sh" <<'__CLAUDE_PROFILES_UNINSTALL_EOF__'
#!/bin/sh
# Claude Code 계정 프로필 전환 도구 제거
#
# 기본 동작은 "스크립트와 rc 등록만 제거"입니다.
# 프로필 디렉터리(자격 증명 포함)는 지우지 않습니다. 지우면 그 계정 로그인이 날아갑니다.
# 기존 ~/.claude 는 어떤 경우에도 건드리지 않습니다.

set -eu

BEGIN_MARK='# >>> claude-profiles >>>'
END_MARK='# <<< claude-profiles <<<'
LIB_NAME='claude-profiles.sh'

PREFIX="${CLAUDE_PROFILES_PREFIX:-$HOME/.local/share/claude-profiles}"
PROFILE_ROOT="${CLAUDE_PROFILE_ROOT:-$HOME/.claude-profiles}"
PURGE=0
ASSUME_YES=0
DRY_RUN=0

usage() {
  cat <<'USAGE'
사용법: ./uninstall.sh [옵션]

  --prefix DIR        스크립트 설치 위치 (기본: ~/.local/share/claude-profiles)
  --purge-profiles    프로필 디렉터리까지 삭제 (그 계정의 로그인이 사라집니다)
  --yes               --purge-profiles 확인 질문을 건너뜀
  --dry-run           무엇을 지울지 보여주기만 함
  -h, --help          이 도움말

기본값은 프로필 데이터를 남깁니다. 나중에 다시 설치하면 그대로 다시 쓸 수 있습니다.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix)          PREFIX="${2:?--prefix 에 경로가 필요합니다}"; shift 2 ;;
    --prefix=*)        PREFIX="${1#--prefix=}"; shift ;;
    --purge-profiles)  PURGE=1; shift ;;
    --yes|-y)          ASSUME_YES=1; shift ;;
    --dry-run)         DRY_RUN=1; shift ;;
    -h|--help)         usage; exit 0 ;;
    *) printf '알 수 없는 옵션: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

say()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }
step() { printf '\n== %s\n' "$*"; }

[ "$DRY_RUN" -eq 1 ] && say "(dry-run: 아무것도 지우지 않습니다)"

# ---------------------------------------------------------------- 1. rc 등록 제거

rc_strip_block() {
  awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
    $0 == b { skip = 1; next }
    $0 == e { skip = 0; next }
    skip != 1 { print }
  ' "$1"
}

rc_trim_trailing_blank() {
  awk '
    { lines[NR] = $0 }
    END {
      last = NR
      while (last > 0 && lines[last] ~ /^[[:space:]]*$/) last--
      for (i = 1; i <= last; i++) print lines[i]
    }
  '
}

rc_unregister() {
  rc="$1"
  [ -f "$rc" ] || return 0
  grep -q "^$BEGIN_MARK\$" "$rc" 2>/dev/null || return 0

  if [ "$DRY_RUN" -eq 1 ]; then
    say "  등록 블록 제거 예정: $rc"
    return 0
  fi

  tmp=$(mktemp "${TMPDIR:-/tmp}/claude-profiles-rc.XXXXXX")
  rc_strip_block "$rc" | rc_trim_trailing_blank > "$tmp"
  backup="$rc.claude-profiles.bak.$(date +%Y%m%d%H%M%S)"
  cp "$rc" "$backup"
  cat "$tmp" > "$rc"
  rm -f "$tmp"
  say "  등록 블록 제거: $rc (백업: $backup)"
}

step "1. 셸 rc 등록 제거"
found_rc=0
for rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile"; do
  if [ -f "$rc" ] && grep -q "^$BEGIN_MARK\$" "$rc" 2>/dev/null; then
    found_rc=1
    rc_unregister "$rc"
  fi
done
[ "$found_rc" -eq 0 ] && say "  등록된 rc 파일 없음"

# ---------------------------------------------------------------- 2. 스크립트 제거

step "2. 스크립트 제거"
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PREFIX_ABS=$(CDPATH= cd -- "$PREFIX" 2>/dev/null && pwd || printf '%s' "$PREFIX")

if [ -f "$PREFIX/$LIB_NAME" ]; then
  say "  삭제: $PREFIX/$LIB_NAME"
  [ "$DRY_RUN" -eq 0 ] && rm -f "$PREFIX/$LIB_NAME"
else
  say "  $PREFIX/$LIB_NAME 없음 (이미 지워졌거나 다른 위치)"
fi
if [ -f "$PREFIX/install-info" ]; then
  say "  삭제: $PREFIX/install-info"
  [ "$DRY_RUN" -eq 0 ] && rm -f "$PREFIX/install-info"
fi

if [ "$SELF_DIR" = "$PREFIX_ABS" ]; then
  # 지금 실행 중인 파일이 그 디렉터리에 있습니다.
  # 실행 도중 자신을 지우는 것은 셸에 따라 위험해서 남겨 둡니다.
  say "  이 제거 스크립트는 남겨 둡니다: $PREFIX/uninstall.sh"
  say "  마저 지우려면: rm -rf \"$PREFIX\""
elif [ -f "$PREFIX/uninstall.sh" ]; then
  say "  삭제: $PREFIX/uninstall.sh"
  if [ "$DRY_RUN" -eq 0 ]; then
    rm -f "$PREFIX/uninstall.sh"
    rmdir "$PREFIX" 2>/dev/null && say "  빈 디렉터리 삭제: $PREFIX" || true
  fi
elif [ "$DRY_RUN" -eq 0 ]; then
  rmdir "$PREFIX" 2>/dev/null && say "  빈 디렉터리 삭제: $PREFIX" || true
fi

# ---------------------------------------------------------------- 3. 프로필 데이터

step "3. 프로필 데이터"
case "$PROFILE_ROOT" in
  "$HOME" | "$HOME/" | "$HOME/.claude" | "/" | "")
    warn "  프로필 루트가 위험한 경로입니다. 건드리지 않습니다: $PROFILE_ROOT"
    PURGE=0 ;;
esac

if [ "$PURGE" -eq 0 ]; then
  if [ -d "$PROFILE_ROOT" ]; then
    say "  유지: $PROFILE_ROOT"
    say "  (여기에 추가 계정의 자격 증명이 들어 있습니다. 지우면 다시 로그인해야 합니다.)"
    say "  정말 지우려면: ./uninstall.sh --purge-profiles"
  else
    say "  $PROFILE_ROOT 없음"
  fi
else
  if [ ! -d "$PROFILE_ROOT" ]; then
    say "  $PROFILE_ROOT 없음"
  else
    say "  아래를 삭제합니다:"
    find "$PROFILE_ROOT" -mindepth 1 -maxdepth 1 2>/dev/null | LC_ALL=C sort | while IFS= read -r d; do
      if [ -f "$d/.credentials.json" ]; then
        say "    $d   <-- 로그인된 자격 증명 있음 (다시 로그인해야 합니다)"
      else
        say "    $d"
      fi
    done
    say "  (~/.claude 는 건드리지 않습니다. 공유 항목은 심볼릭 링크라 원본은 안전합니다.)"

    if [ "$DRY_RUN" -eq 1 ]; then
      say "  dry-run 이므로 삭제하지 않습니다."
    elif [ "$ASSUME_YES" -eq 1 ]; then
      rm -rf "$PROFILE_ROOT"
      say "  삭제 완료: $PROFILE_ROOT"
    elif [ -t 0 ]; then
      printf '정말 삭제할까요? 삭제하려면 yes 를 입력하세요: '
      read -r answer
      if [ "$answer" = "yes" ]; then
        rm -rf "$PROFILE_ROOT"
        say "  삭제 완료: $PROFILE_ROOT"
      else
        say "  취소했습니다. 프로필을 그대로 둡니다."
      fi
    else
      warn "  확인을 받을 수 없어 삭제를 취소했습니다. 비대화형이면 --yes 를 쓰세요."
    fi
  fi
fi

step "4. 완료"
say "현재 셸에 남아 있는 함수는 새 셸을 열면 사라집니다."
say "이 셸에서 바로 지우려면:"
say "  unset -f claude-use claude-who claude-profiles claude-with claude-profiles-update 2>/dev/null"
say "  unset CLAUDE_CONFIG_DIR"
__CLAUDE_PROFILES_UNINSTALL_EOF__

chmod 755 "$_cp_bundle_tmp/uninstall.sh"
CLAUDE_PROFILES_SRC="$_cp_bundle_tmp"
export CLAUDE_PROFILES_SRC
CLAUDE_PROFILES_SOURCE_SPEC="${CLAUDE_PROFILES_SOURCE_SPEC:-url:https://raw.githubusercontent.com/shaichoi/claude-profiles/main/dist/install-standalone.sh}"
export CLAUDE_PROFILES_SOURCE_SPEC

# ---------------------------------------------------------------- install.sh
# Claude Code 계정 프로필 전환 도구 설치 (bash / zsh, Linux / macOS)
#
# 여러 번 실행해도 안전합니다(멱등). rc 파일은 내용이 실제로 바뀔 때만 백업합니다.
# 기존 ~/.claude 는 절대 건드리지 않습니다.

set -eu

BEGIN_MARK='# >>> claude-profiles >>>'
END_MARK='# <<< claude-profiles <<<'
LIB_NAME='claude-profiles.sh'

# 번들(자립형 단일 파일)은 압축을 푼 임시 디렉터리를 여기로 넘깁니다.
SRC_DIR="${CLAUDE_PROFILES_SRC:-$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)}"
PREFIX="${CLAUDE_PROFILES_PREFIX:-$HOME/.local/share/claude-profiles}"
SHELL_OPT=auto
DEFAULT_NAME=default
DEFAULT_NAME_SET=0
DO_MIGRATE=1
NO_PROMPT=0
SOURCE_SPEC="${CLAUDE_PROFILES_SOURCE_SPEC:-}"
DRY_RUN=0
SKIP_PROBE=0

usage() {
  cat <<'USAGE'
사용법: ./install.sh [옵션]

  --prefix DIR     스크립트 설치 위치 (기본: ~/.local/share/claude-profiles)
  --shell 대상     rc 등록 대상: auto | bash | zsh | both | none (기본: auto)
  --default-name N 기본 프로필(~/.claude)을 부를 이름 (예: work-main)
                   지정하지 않으면 이미 등록된 값을 그대로 둡니다.
                   default 로 주면 별칭을 없앱니다.
  --no-prompt      이름을 묻지 않음 (비대화형 설치와 같은 동작)
  --source SPEC    업데이트에 쓸 설치 출처 (url:... | git:... | dir:...)
                   보통은 자동으로 정해지므로 줄 필요가 없습니다.
  --no-migrate     기존 ~/.claude-profiles/profiles.zsh 등록을 정리하지 않음
  --skip-probe     claude 동작 확인(임시 설정 디렉터리 테스트)을 건너뜀
  --dry-run        무엇을 할지 보여주기만 하고 아무것도 바꾸지 않음
  -h, --help       이 도움말

프로필 데이터(~/.claude-profiles/<이름>)는 설치·제거와 무관하게 유지됩니다.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix)     PREFIX="${2:?--prefix 에 경로가 필요합니다}"; shift 2 ;;
    --prefix=*)   PREFIX="${1#--prefix=}"; shift ;;
    --shell)      SHELL_OPT="${2:?--shell 에 값이 필요합니다}"; shift 2 ;;
    --shell=*)    SHELL_OPT="${1#--shell=}"; shift ;;
    --default-name)   DEFAULT_NAME="${2:?--default-name 에 이름이 필요합니다}"; DEFAULT_NAME_SET=1; shift 2 ;;
    --default-name=*) DEFAULT_NAME="${1#--default-name=}"; DEFAULT_NAME_SET=1; shift ;;
    --no-prompt)  NO_PROMPT=1; shift ;;
    --source)     SOURCE_SPEC="${2:?--source 에 값이 필요합니다}"; shift 2 ;;
    --source=*)   SOURCE_SPEC="${1#--source=}"; shift ;;
    --no-migrate) DO_MIGRATE=0; shift ;;
    --skip-probe) SKIP_PROBE=1; shift ;;
    --dry-run)    DRY_RUN=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) printf '알 수 없는 옵션: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$SHELL_OPT" in
  auto|bash|zsh|both|none) ;;
  *) printf -- '--shell 값은 auto|bash|zsh|both|none 중 하나여야 합니다: %s\n' "$SHELL_OPT" >&2; exit 2 ;;
esac

case "$DEFAULT_NAME" in
  '' | . | .. | .* | *[!A-Za-z0-9._-]*)
    printf -- '--default-name 은 영문/숫자/. _ - 만 쓸 수 있습니다: %s\n' "$DEFAULT_NAME" >&2; exit 2 ;;
esac

say()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }
step() { printf '\n== %s\n' "$*"; }

[ "$DRY_RUN" -eq 1 ] && say "(dry-run: 아무것도 바꾸지 않습니다)"

# ---------------------------------------------------------------- 1. 사전 확인

step "1. claude CLI 확인"
if ! command -v claude >/dev/null 2>&1; then
  cat >&2 <<'NOCLAUDE'
claude CLI 를 찾을 수 없습니다. 설치를 중단합니다.

  Claude Code 를 먼저 설치하세요:
    curl -fsSL https://claude.ai/install.sh | bash
  설치 후 PATH 에 claude 가 잡히는지 확인하고 다시 실행하세요.
NOCLAUDE
  exit 1
fi
say "  경로: $(command -v claude)"
say "  버전: $(claude --version 2>/dev/null | head -1)"

if [ "$SKIP_PROBE" -eq 1 ]; then
  say "  동작 확인: 건너뜀 (--skip-probe)"
else
  # 버전 번호를 하드코딩하는 대신 실제 동작을 확인합니다.
  probe_dir=$(mktemp -d "${TMPDIR:-/tmp}/claude-profiles-probe.XXXXXX")
  probe_out=$(CLAUDE_CONFIG_DIR="$probe_dir" claude auth status 2>/dev/null || true)
  rm -rf "$probe_dir"
  case "$probe_out" in
    *'"loggedIn"'*)
      say "  동작 확인: CLAUDE_CONFIG_DIR 로 설정 디렉터리 분리 가능" ;;
    *)
      warn "claude auth status 가 예상한 JSON 을 내지 않았습니다. 이 버전은 지원 범위 밖일 수 있습니다."
      warn "그래도 설치하려면 --skip-probe 를 붙여 다시 실행하세요."
      exit 1 ;;
  esac
fi

step "2. 스크립트 문법 확인"
[ -f "$SRC_DIR/$LIB_NAME" ] || { warn "$SRC_DIR/$LIB_NAME 이 없습니다."; exit 1; }
if command -v bash >/dev/null 2>&1; then
  bash -n "$SRC_DIR/$LIB_NAME" || { warn "bash 문법 검사 실패. 설치를 중단합니다."; exit 1; }
  say "  bash -n 통과"
fi
if command -v zsh >/dev/null 2>&1; then
  zsh -n "$SRC_DIR/$LIB_NAME" || { warn "zsh 문법 검사 실패. 설치를 중단합니다."; exit 1; }
  say "  zsh -n 통과"
fi

# ---------------------------------------------------------------- 3. 파일 설치

step "3. 스크립트 설치"
say "  대상: $PREFIX/$LIB_NAME"
if [ "$DRY_RUN" -eq 0 ]; then
  mkdir -p "$PREFIX"
  cp "$SRC_DIR/$LIB_NAME" "$PREFIX/$LIB_NAME.new"
  mv "$PREFIX/$LIB_NAME.new" "$PREFIX/$LIB_NAME"
  chmod 644 "$PREFIX/$LIB_NAME"
  # 저장소 없이도 제거할 수 있도록 uninstall.sh 를 같이 둡니다.
  if [ -f "$SRC_DIR/uninstall.sh" ]; then
    cp "$SRC_DIR/uninstall.sh" "$PREFIX/uninstall.sh.new"
    mv "$PREFIX/uninstall.sh.new" "$PREFIX/uninstall.sh"
    chmod 755 "$PREFIX/uninstall.sh"
    say "  제거 스크립트도 함께 설치: $PREFIX/uninstall.sh"
  fi
  say "  설치 완료"
fi

# 업데이트에 쓸 설치 출처를 정합니다.
if [ -z "$SOURCE_SPEC" ]; then
  if git -C "$SRC_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    SOURCE_SPEC="git:$SRC_DIR"
  else
    SOURCE_SPEC="dir:$SRC_DIR"
  fi
fi
if [ "$DRY_RUN" -eq 0 ]; then
  version=$(sed -n 's/^CLAUDE_PROFILES_VERSION="\(.*\)"$/\1/p' "$PREFIX/$LIB_NAME" | head -1)
  {
    printf 'version=%s\n' "${version:-?}"
    printf 'prefix=%s\n' "$PREFIX"
    printf 'source=%s\n' "$SOURCE_SPEC"
    printf 'installed=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
  } > "$PREFIX/install-info"
  say "  설치 출처: $SOURCE_SPEC  (claude-profiles-update 로 갱신)"
fi

LIB_PATH="$PREFIX/$LIB_NAME"

# ---------------------------------------------------------------- 4. rc 등록

rc_block() {
  printf '%s\n' "$BEGIN_MARK"
  printf '%s\n' "# Claude Code 계정 프로필 전환: claude-use / claude-who / claude-profiles / claude-with"
  printf '%s\n' "# 이 블록은 claude-profiles 패키지가 관리합니다. 제거는 uninstall.sh."
  printf '%s\n' "CLAUDE_PROFILES_HOME=\"$PREFIX\""
  printf '%s\n' "export CLAUDE_PROFILES_HOME"
  if [ -n "${1:-}" ] && [ "$1" != default ]; then
    printf '%s\n' "CLAUDE_PROFILE_DEFAULT_NAME=$1"
    printf '%s\n' "export CLAUDE_PROFILE_DEFAULT_NAME"
  fi
  printf '%s\n' "[ -f \"$LIB_PATH\" ] && . \"$LIB_PATH\""
  printf '%s\n' "$END_MARK"
}

# 이미 등록된 블록에서 기본 프로필 이름을 읽습니다.
# --default-name 없이 재설치할 때 설정이 조용히 사라지지 않게 합니다.
rc_read_default_name() {
  awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
    $0 == b { inb = 1; next }
    $0 == e { inb = 0; next }
    inb == 1 && index($0, "CLAUDE_PROFILE_DEFAULT_NAME=") == 1 {
      v = substr($0, length("CLAUDE_PROFILE_DEFAULT_NAME=") + 1)
      print v
      exit
    }
  ' "$1"
}

# 마커 블록을 제거한 내용을 표준 출력으로
rc_strip_block() {
  awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
    $0 == b { skip = 1; next }
    $0 == e { skip = 0; next }
    skip != 1 { print }
  ' "$1"
}

# 예전 profiles.zsh 등록 줄과 바로 앞 주석 줄을 제거
rc_strip_legacy() {
  awk '
    {
      if ($0 ~ /\.claude-profiles\/profiles\.zsh/) {
        if (heldset == 1 && held ~ /^[[:space:]]*#/) { heldset = 0; held = "" }
        else if (heldset == 1) { print held; heldset = 0; held = "" }
        next
      }
      if (heldset == 1) print held
      held = $0; heldset = 1
    }
    END { if (heldset == 1) print held }
  '
}

# 끝의 빈 줄 제거 (두 번째 설치 때 결과가 같아지도록)
rc_trim_trailing_blank() {
  awk '
    { lines[NR] = $0 }
    END {
      last = NR
      while (last > 0 && lines[last] ~ /^[[:space:]]*$/) last--
      for (i = 1; i <= last; i++) print lines[i]
    }
  '
}

# 기본 프로필(~/.claude)에 로그인된 계정 이메일. 참고용으로만 씁니다.
current_email() {
  ( unset CLAUDE_CONFIG_DIR; claude auth status 2>/dev/null ) \
    | tr '\n' ' ' \
    | sed -n -E 's/.*"email"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p'
}

# --default-name 없이 대화형으로 실행하면 이름을 물어봅니다.
# 비대화형(스크립트, CI, 파이프)에서는 묻지 않고 기존 설정을 그대로 씁니다.
prompt_default_name() {
  [ "$DEFAULT_NAME_SET" -eq 1 ] && return 0
  [ "$NO_PROMPT" -eq 1 ] && return 0
  [ "$DRY_RUN" -eq 1 ] && return 0
  [ "$SHELL_OPT" = none ] && return 0
  # 입력을 어디서 받을지 정합니다.
  #   - 표준 입력이 터미널이면 그대로
  #   - curl ... | sh 처럼 표준 입력이 파이프면 /dev/tty 에서
  #   - 터미널이 아예 없으면(CI) 묻지 않음
  #   CLAUDE_PROFILES_NO_TTY=1 은 터미널이 없는 상황을 흉내 내는 테스트용입니다.
  use_tty=0
  if [ "${CLAUDE_PROFILES_ASSUME_TTY:-0}" = 1 ]; then
    use_tty=0
  elif [ -t 0 ]; then
    use_tty=0
  elif [ "${CLAUDE_PROFILES_NO_TTY:-0}" = 1 ]; then
    return 0
  elif (exec 3</dev/tty) 2>/dev/null; then
    use_tty=1
  else
    return 0
  fi

  cur=default
  for rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile"; do
    [ -f "$rc" ] || continue
    v=$(rc_read_default_name "$rc")
    if [ -n "$v" ]; then cur="$v"; break; fi
  done

  email=$(current_email)

  printf '\n'
  say "기본 프로필(~/.claude)을 부를 이름을 정하세요."
  [ -n "$email" ] && say "  지금 이 디렉터리에 로그인된 계정: $email"
  say "  계정 이름으로 부르면 프로필이 여러 개일 때 헷갈리지 않습니다. 예: work-main"
  if [ "$cur" = default ]; then
    say "  그냥 Enter 를 누르면 default 를 씁니다."
  else
    say "  그냥 Enter 를 누르면 지금 설정된 '$cur' 을 유지합니다."
  fi

  if [ "$use_tty" -eq 1 ]; then
    prompt_default_name_loop "$cur" < /dev/tty
  else
    prompt_default_name_loop "$cur"
  fi
}

prompt_default_name_loop() {
  cur="$1"
  tries=0
  while [ "$tries" -lt 3 ]; do
    tries=$((tries + 1))
    printf '이름: '
    if ! IFS= read -r ans; then
      printf '\n'
      say "  입력을 받지 못해 '$cur' 로 진행합니다."
      DEFAULT_NAME="$cur"; DEFAULT_NAME_SET=1
      return 0
    fi
    if [ -z "$ans" ]; then
      DEFAULT_NAME="$cur"; DEFAULT_NAME_SET=1
      say "  '$cur' 로 진행합니다."
      return 0
    fi
    case "$ans" in
      . | .. | .* | *[!A-Za-z0-9._-]*)
        warn "  영문/숫자/. _ - 만 쓸 수 있습니다: $ans"
        continue ;;
    esac
    if [ "$ans" != default ] && [ -d "${CLAUDE_PROFILE_ROOT:-$HOME/.claude-profiles}/$ans" ]; then
      warn "  같은 이름의 프로필 디렉터리가 이미 있습니다: $ans"
      warn "  그 이름을 기본 프로필에 쓰면 해당 프로필 계정을 쓸 수 없게 됩니다."
      continue
    fi
    DEFAULT_NAME="$ans"; DEFAULT_NAME_SET=1
    say "  '$ans' 로 진행합니다."
    return 0
  done

  say "  세 번 모두 쓸 수 없는 이름이라 '$cur' 로 진행합니다."
  DEFAULT_NAME="$cur"; DEFAULT_NAME_SET=1
  return 0
}

rc_register() {
  rc="$1"
  label="$2"
  had_legacy=0

  # --default-name 을 주지 않았으면 이미 등록된 값을 유지합니다.
  rc_name="$DEFAULT_NAME"
  if [ "$DEFAULT_NAME_SET" -eq 0 ] && [ -f "$rc" ]; then
    prev_name=$(rc_read_default_name "$rc")
    [ -n "$prev_name" ] && rc_name="$prev_name"
  fi

  if [ ! -f "$rc" ]; then
    say "  $label: $rc 가 없어 새로 만듭니다"
    [ "$DRY_RUN" -eq 0 ] && : > "$rc"
  fi
  [ -f "$rc" ] || return 0

  if grep -q '\.claude-profiles/profiles\.zsh' "$rc" 2>/dev/null; then
    had_legacy=1
  fi

  # 임시 파일은 홈이 아니라 TMPDIR 에 둡니다 (dry-run 이 홈에 아무것도 남기지 않도록).
  tmp=$(mktemp "${TMPDIR:-/tmp}/claude-profiles-rc.XXXXXX")
  if [ "$had_legacy" -eq 1 ] && [ "$DO_MIGRATE" -eq 1 ]; then
    rc_strip_block "$rc" | rc_strip_legacy | rc_trim_trailing_blank > "$tmp"
  else
    rc_strip_block "$rc" | rc_trim_trailing_blank > "$tmp"
  fi
  # 본문이 있으면 블록 앞에 빈 줄 하나
  [ -s "$tmp" ] && printf '\n' >> "$tmp"
  rc_block "$rc_name" >> "$tmp"

  # cmp/diff 가 없는 서버가 있어 셸만으로 비교합니다.
  if [ "$(cat "$tmp")" = "$(cat "$rc")" ]; then
    rm -f "$tmp"
    say "  $label: 이미 최신 상태 (변경 없음)"
    return 0
  fi

  if [ "$had_legacy" -eq 1 ]; then
    if [ "$DO_MIGRATE" -eq 1 ]; then
      say "  $label: 예전 profiles.zsh 등록을 제거합니다"
    else
      warn "  $label: 예전 profiles.zsh 등록이 남아 있습니다 (--no-migrate). 함수가 중복 정의됩니다."
    fi
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    say "  $label: 아래 블록을 추가할 예정 ($rc)"
    rc_block "$rc_name" | sed 's/^/      /'
    rm -f "$tmp"
    return 0
  fi

  backup="$rc.claude-profiles.bak.$(date +%Y%m%d%H%M%S)"
  cp "$rc" "$backup"
  cat "$tmp" > "$rc"   # 원본 권한과 inode 유지
  rm -f "$tmp"
  if [ "$rc_name" != default ]; then
    say "  $label: 등록 완료, 기본 프로필 이름 '$rc_name' (백업: $backup)"
  else
    say "  $label: 등록 완료 (백업: $backup)"
  fi
}

step "4. 셸 rc 등록"
prompt_default_name
want_zsh=0
want_bash=0
case "$SHELL_OPT" in
  zsh)  want_zsh=1 ;;
  bash) want_bash=1 ;;
  both) want_zsh=1; want_bash=1 ;;
  none) ;;
  auto)
    [ -f "$HOME/.zshrc" ]  && want_zsh=1
    [ -f "$HOME/.bashrc" ] && want_bash=1
    case "${SHELL:-}" in
      */zsh)  want_zsh=1 ;;
      */bash) want_bash=1 ;;
      zsh)    want_zsh=1 ;;
      bash)   want_bash=1 ;;
    esac
    if [ "$want_zsh" -eq 0 ] && [ "$want_bash" -eq 0 ]; then
      command -v zsh  >/dev/null 2>&1 && want_zsh=1
      command -v bash >/dev/null 2>&1 && want_bash=1
    fi
    ;;
esac

if [ "$want_zsh" -eq 0 ] && [ "$want_bash" -eq 0 ]; then
  say "  등록 대상 없음. 아래 줄을 직접 rc 파일에 넣으세요:"
  say "    [ -f \"$LIB_PATH\" ] && . \"$LIB_PATH\""
else
  [ "$want_zsh" -eq 1 ]  && rc_register "$HOME/.zshrc"  "zsh "
  [ "$want_bash" -eq 1 ] && rc_register "$HOME/.bashrc" "bash"
fi

# 예전 스크립트 파일은 지우지 않고 이름만 바꿔 둡니다.
LEGACY="${CLAUDE_PROFILE_ROOT:-$HOME/.claude-profiles}/profiles.zsh"
legacy_still_used=0
for rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile"; do
  [ -f "$rc" ] || continue
  grep -q '\.claude-profiles/profiles\.zsh' "$rc" 2>/dev/null && legacy_still_used=1
done
if [ "$legacy_still_used" -eq 1 ] && [ -f "$LEGACY" ]; then
  warn "  주의: 아직 profiles.zsh 를 읽는 rc 파일이 있어 이름을 바꾸지 않습니다."
elif [ "$DO_MIGRATE" -eq 1 ] && [ -f "$LEGACY" ]; then
  legacy_bak="$LEGACY.bak"
  [ -e "$legacy_bak" ] && legacy_bak="$LEGACY.bak.$(date +%Y%m%d%H%M%S)"
  say "  예전 스크립트 보관: $LEGACY -> $legacy_bak"
  [ "$DRY_RUN" -eq 0 ] && mv "$LEGACY" "$legacy_bak"
fi

# macOS bash 는 로그인 셸이 ~/.bashrc 를 읽지 않습니다.
if [ "$want_bash" -eq 1 ] && [ "$(uname -s)" = "Darwin" ]; then
  if [ ! -f "$HOME/.bash_profile" ] || ! grep -q 'bashrc' "$HOME/.bash_profile" 2>/dev/null; then
    warn ""
    warn "[macOS 안내] 로그인 셸 bash 는 ~/.bashrc 를 읽지 않습니다."
    warn "~/.bash_profile 에 아래 줄을 직접 넣어 주세요:"
    warn '  [ -f ~/.bashrc ] && . ~/.bashrc'
  fi
fi

# ---------------------------------------------------------------- 5. 마무리

step "5. 완료"
cat <<DONE
새 셸을 열거나 아래를 실행해 반영하세요.
  zsh:  source ~/.zshrc
  bash: source ~/.bashrc

두 번째 계정 등록:
  claude-use <이름>       # 프로필 생성 및 이 셸에서 전환
  claude auth login       # 이 셸에서 두 번째 계정으로 로그인
  claude-who              # 계정 확인

업데이트:      claude-profiles-update
제거:          $PREFIX/uninstall.sh

프로필 데이터: ${CLAUDE_PROFILE_ROOT:-$HOME/.claude-profiles}
스크립트:      $LIB_PATH
DONE
