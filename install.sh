#!/bin/sh
# Claude Code 계정 프로필 전환 도구 설치 (bash / zsh, Linux / macOS)
#
# 여러 번 실행해도 안전합니다(멱등). rc 파일은 내용이 실제로 바뀔 때만 백업합니다.
# 기존 ~/.claude 는 절대 건드리지 않습니다.

set -eu

BEGIN_MARK='# >>> claude-profiles >>>'
END_MARK='# <<< claude-profiles <<<'
LIB_NAME='claude-profiles.sh'

SRC_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PREFIX="${CLAUDE_PROFILES_PREFIX:-$HOME/.local/share/claude-profiles}"
SHELL_OPT=auto
DEFAULT_NAME=default
DEFAULT_NAME_SET=0
DO_MIGRATE=1
NO_PROMPT=0
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
  say "  설치 완료"
fi

LIB_PATH="$PREFIX/$LIB_NAME"

# ---------------------------------------------------------------- 4. rc 등록

rc_block() {
  printf '%s\n' "$BEGIN_MARK"
  printf '%s\n' "# Claude Code 계정 프로필 전환: claude-use / claude-who / claude-profiles / claude-with"
  printf '%s\n' "# 이 블록은 claude-profiles 패키지가 관리합니다. 제거는 uninstall.sh."
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
  # 테스트에서 가짜 tty 를 쓰기 위한 통로입니다.
  if [ "${CLAUDE_PROFILES_ASSUME_TTY:-0}" != 1 ] && [ ! -t 0 ]; then
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

프로필 데이터: ${CLAUDE_PROFILE_ROOT:-$HOME/.claude-profiles}
스크립트:      $LIB_PATH
DONE
