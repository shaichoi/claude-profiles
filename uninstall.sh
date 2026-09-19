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
say "  unset -f claude-new claude-use claude-who claude-profiles claude-with claude-profiles-update 2>/dev/null"
say "  unset CLAUDE_CONFIG_DIR"
