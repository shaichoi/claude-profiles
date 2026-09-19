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

CLAUDE_PROFILES_VERSION="1.2.1"

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

# 현재 셸은 그대로 두고 프로필만 만듭니다.
#   claude-new work2            만들기만
#   claude-new work2 --login    만들고 바로 그 계정으로 로그인 (셸은 그대로)
claude-new() {
  local name="$1" dir item existed=0 do_login=0
  if [ -z "$name" ]; then
    printf '%s\n' "사용법: claude-new <프로필 이름> [--login]" >&2
    printf '%s\n' "  현재 셸의 프로필은 바뀌지 않습니다." >&2
    return 1
  fi
  case "${2:-}" in
    '')      ;;
    --login) do_login=1 ;;
    *) printf '%s\n' "알 수 없는 옵션: $2   (쓸 수 있는 것: --login)" >&2; return 1 ;;
  esac
  if ! _claude_profile_valid_name "$name"; then
    printf '%s\n' "프로필 이름은 영문/숫자/. _ - 만 쓸 수 있습니다: $name" >&2
    return 1
  fi
  dir="$(_claude_profile_dir "$name")"
  if [ "$dir" = "$HOME/.claude" ]; then
    printf '%s\n' "'$name' 은 기본 프로필이라 이미 있습니다. 새로 만들 수 없습니다." >&2
    return 1
  fi
  [ -d "$dir" ] && existed=1
  _claude_profile_init "$dir" || return 1

  if [ "$existed" -eq 1 ]; then
    printf '%s\n' "이미 있는 프로필: $name  ($dir)"
    printf '%s\n' "  빠진 공유 링크가 있으면 채웠습니다."
  else
    printf '%s\n' "프로필 생성: $name  ($dir)"
  fi
  printf '%s\n' "$CLAUDE_PROFILE_SHARED" | tr ' ' '\n' | while IFS= read -r item; do
    [ -n "$item" ] || continue
    [ -L "$dir/$item" ] && printf '%s\n' "  공유 링크: $item"
  done
  printf '%s\n' "  계정: $(_claude_profile_account "$dir")"
  printf '%s\n' "현재 셸은 그대로입니다: $(_claude_profile_name)"

  if [ "$do_login" -eq 1 ]; then
    printf '%s\n' "이제 $name 계정으로 로그인합니다. 이 셸의 프로필은 바뀌지 않습니다."
    claude-with "$name" auth login || return 1
    printf '%s\n' "로그인 결과: $(_claude_profile_account "$dir")"
  else
    printf '%s\n' "로그인하려면: claude-with $name auth login   (셸은 그대로)"
    printf '%s\n' "이 셸을 전환하려면: claude-use $name"
  fi
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
  # zsh 에서 path 는 PATH 와 연결된 특수 변수입니다. local path 로 잡으면
  # 이 함수 안에서 PATH 가 비어 sed 조차 찾지 못합니다. 이름을 피합니다.
  local info src url src_path
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
      src_path="${src#git:}"
      if [ ! -d "$src_path" ]; then
        printf '%s\n' "저장소를 찾을 수 없습니다: $src_path" >&2
        return 1
      fi
      printf '%s\n' "저장소 갱신: $src_path"
      git -C "$src_path" pull --ff-only || {
        printf '%s\n' "git pull 실패. 저장소에서 직접 정리한 뒤 다시 시도하세요." >&2
        return 1
      }
      "$src_path/install.sh" --no-prompt --prefix "$CLAUDE_PROFILES_HOME" || return 1
      ;;
    dir:*)
      src_path="${src#dir:}"
      if [ ! -x "$src_path/install.sh" ]; then
        printf '%s\n' "설치 스크립트를 찾을 수 없습니다: $src_path/install.sh" >&2
        return 1
      fi
      "$src_path/install.sh" --no-prompt --prefix "$CLAUDE_PROFILES_HOME" || return 1
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
