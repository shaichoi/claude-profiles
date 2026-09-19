#!/usr/bin/env bash
# claude-profiles 자체 검증
#
# 실제 홈 디렉터리를 건드리지 않습니다.
#   - 설치/제거 시험은 가짜 HOME 안에서만 합니다.
#   - claude auth status 는 임시 CLAUDE_CONFIG_DIR 로만 호출합니다.
#   - claude auth logout 은 어떤 경우에도 실행하지 않습니다.

set -u

SRC_DIR=$(cd -- "$(dirname -- "$0")/.." && pwd)
REAL_HOME="$HOME"
PASS=0
FAIL=0

ok()   { PASS=$((PASS+1)); printf '  \033[32mOK\033[0m   %s\n' "$1"; }
ng()   { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

check() { # check <설명> <기대값> <실제값>
  if [ "$2" = "$3" ]; then ok "$1"; else ng "$1 (기대: [$2] 실제: [$3])"; fi
}

# 실제 홈의 rc 파일이 바뀌지 않는지 감시
snapshot_real_home() {
  for f in "$REAL_HOME/.zshrc" "$REAL_HOME/.bashrc" "$REAL_HOME/.bash_profile"; do
    [ -f "$f" ] && cksum < "$f"
  done
}
REAL_BEFORE=$(snapshot_real_home)

TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/claude-profiles-test.XXXXXX")
cleanup() { rm -rf "$TMPROOT"; }
trap cleanup EXIT

# ---------------------------------------------------------------- 문법

head_ "1. 문법 검사"
for f in claude-profiles.sh install.sh uninstall.sh; do
  if bash -n "$SRC_DIR/$f" 2>/dev/null; then ok "bash -n $f"; else ng "bash -n $f"; fi
done
for f in install.sh uninstall.sh; do
  if sh -n "$SRC_DIR/$f" 2>/dev/null; then ok "sh -n $f"; else ng "sh -n $f"; fi
done
if command -v zsh >/dev/null 2>&1; then
  for f in claude-profiles.sh install.sh uninstall.sh; do
    if zsh -n "$SRC_DIR/$f" 2>/dev/null; then ok "zsh -n $f"; else ng "zsh -n $f"; fi
  done
else
  echo "  (zsh 없음: zsh 검사 생략)"
fi

# ---------------------------------------------------------------- JSON 파서

head_ "2. JSON 파서 (python3/jq 없이)"
PARSE_PROBE="$TMPROOT/parse.sh"
cat > "$PARSE_PROBE" <<'PROBE'
. "$SRC_DIR/claude-profiles.sh"
s() { printf '%s' "$2" | _claude_profile_json_str "$1"; }
b() { printf '%s' "$2" | _claude_profile_json_bool "$1"; }
J_MULTI='{
  "loggedIn": true,
  "authMethod": "claude.ai",
  "email": "user@example.com",
  "orgId": null,
  "orgName": "Acme",
  "subscriptionType": "team"
}'
J_OUT='{"loggedIn":false,"authMethod":"none","apiProvider":"firstParty"}'
J_QUOTE='{"loggedIn": true, "orgName": "따옴표 \"안쪽\" 조직"}'
J_BSLASH='{"loggedIn": true, "orgName": "back\\slash"}'
J_PUNCT='{"loggedIn": true, "orgName": "쉼표,콜론:중괄호{}"}'
J_NULL='{"loggedIn": true, "email": null, "orgName": null, "subscriptionType": "team"}'
printf '%s\n' "$(s email "$J_MULTI")"
printf '%s\n' "$(s orgName "$J_MULTI")"
printf '%s\n' "$(s subscriptionType "$J_MULTI")"
printf '%s\n' "$(s orgId "$J_MULTI")"
printf '%s\n' "$(b loggedIn "$J_MULTI")"
printf '%s\n' "$(b loggedIn "$J_OUT")"
printf '%s\n' "$(s email "$J_OUT")"
printf '%s\n' "$(s orgName "$J_QUOTE")"
printf '%s\n' "$(s orgName "$J_BSLASH")"
printf '%s\n' "$(s orgName "$J_PUNCT")"
printf '%s\n' "$(s email "$J_NULL")"
printf '%s\n' "$(s subscriptionType "$J_NULL")"
printf '%s\n' "$(s email '')"
PROBE

EXPECTED='user@example.com
Acme
team

true
false

따옴표 "안쪽" 조직
back\slash
쉼표,콜론:중괄호{}

team
'
for sh_name in bash zsh; do
  command -v "$sh_name" >/dev/null 2>&1 || continue
  case "$sh_name" in
    bash) actual=$(SRC_DIR="$SRC_DIR" bash --noprofile --norc "$PARSE_PROBE") ;;
    zsh)  actual=$(SRC_DIR="$SRC_DIR" zsh -f "$PARSE_PROBE") ;;
  esac
  check "$sh_name 파서 결과 13종" "$(printf '%s' "$EXPECTED")" "$actual"
done

# ---------------------------------------------------------------- 이름 검증

head_ "3. 프로필 이름 검증 (경로 탈출 차단)"
NAME_PROBE="$TMPROOT/name.sh"
cat > "$NAME_PROBE" <<'PROBE'
. "$SRC_DIR/claude-profiles.sh"
for n in "../../x" "a b" ".hidden" "ok-name_1.2" "" "default" "x/y" "..";do
  if _claude_profile_valid_name "$n"; then printf 'OK:%s\n' "$n"; else printf 'NO:%s\n' "$n"; fi
done
PROBE
NAME_EXPECTED='NO:../../x
NO:a b
NO:.hidden
OK:ok-name_1.2
NO:
OK:default
NO:x/y
NO:..'
for sh_name in bash zsh; do
  command -v "$sh_name" >/dev/null 2>&1 || continue
  case "$sh_name" in
    bash) actual=$(SRC_DIR="$SRC_DIR" bash --noprofile --norc "$NAME_PROBE") ;;
    zsh)  actual=$(SRC_DIR="$SRC_DIR" zsh -f "$NAME_PROBE") ;;
  esac
  check "$sh_name 이름 검증" "$NAME_EXPECTED" "$actual"
done

# ---------------------------------------------------------------- 격리

head_ "4. CLAUDE_CONFIG_DIR 격리"
if command -v claude >/dev/null 2>&1; then
  probe="$TMPROOT/isolated"
  mkdir -p "$probe"
  out=$(CLAUDE_CONFIG_DIR="$probe" claude auth status 2>/dev/null || true)
  case "$out" in
    *'"loggedIn": false'*|*'"loggedIn":false'*) ok "임시 설정 디렉터리는 로그인되어 있지 않음" ;;
    *) ng "임시 설정 디렉터리 격리 실패: $out" ;;
  esac
  case "$out" in
    *'"loggedIn"'*) ok "auth status 가 JSON 을 출력" ;;
    *) ng "auth status JSON 아님" ;;
  esac
else
  echo "  (claude 없음: 격리 검사 생략)"
fi

# ---------------------------------------------------------------- 설치 사이클

head_ "5. 설치 사이클 (가짜 HOME)"
FAKE="$TMPROOT/home"
mkdir -p "$FAKE/.claude/projects" "$FAKE/.claude-profiles"
printf '{}\n' > "$FAKE/.claude/settings.json"
printf '# CLAUDE\n' > "$FAKE/.claude/CLAUDE.md"
# 예전 방식 설치 상태를 재현
printf '# 기존 zshrc 내용\nalias ll="ls -l"\n\n# Claude Code 계정 프로필 전환 (claude-use)\n[[ -f ~/.claude-profiles/profiles.zsh ]] && source ~/.claude-profiles/profiles.zsh\n' > "$FAKE/.zshrc"
printf '# 기존 bashrc 내용\n' > "$FAKE/.bashrc"
printf 'legacy\n' > "$FAKE/.claude-profiles/profiles.zsh"
PFX="$FAKE/.local/share/claude-profiles"

run_install() { (cd "$SRC_DIR" && env -u CLAUDE_PROFILE_ROOT HOME="$FAKE" CLAUDE_PROFILES_NO_TTY=1 sh ./install.sh --prefix "$PFX" --shell both "$@" < /dev/null); }
run_uninstall() { (cd "$SRC_DIR" && env -u CLAUDE_PROFILE_ROOT HOME="$FAKE" sh ./uninstall.sh --prefix "$PFX" "$@"); }
markers() { awk -v m='# >>> claude-profiles >>>' '$0 == m { n++ } END { print n + 0 }' "$1" 2>/dev/null; }
backups() { find "$FAKE" -maxdepth 1 -name '.*.claude-profiles.bak.*' 2>/dev/null | wc -l | tr -d ' '; }

out1=$(run_install 2>&1) || ng "1차 설치 실패: $out1"
check "1차 설치 후 .zshrc 마커 1개"  1 "$(markers "$FAKE/.zshrc")"
check "1차 설치 후 .bashrc 마커 1개" 1 "$(markers "$FAKE/.bashrc")"
if grep -q 'profiles\.zsh' "$FAKE/.zshrc"; then ng "예전 등록 줄이 남아 있음"; else ok "예전 등록 줄 제거됨"; fi
if grep -q '기존 zshrc 내용' "$FAKE/.zshrc"; then ok "기존 rc 내용 보존"; else ng "기존 rc 내용 유실"; fi
if [ -f "$PFX/claude-profiles.sh" ]; then ok "스크립트 설치됨"; else ng "스크립트 설치 안 됨"; fi
if [ -f "$FAKE/.claude-profiles/profiles.zsh.bak" ]; then ok "예전 스크립트 .bak 로 보관"; else ng "예전 스크립트 보관 실패"; fi
B1=$(backups)

out2=$(run_install 2>&1) || ng "2차 설치 실패: $out2"
check "2차 설치 후 마커 여전히 1개" 1 "$(markers "$FAKE/.zshrc")"
check "2차 설치로 백업 늘지 않음" "$B1" "$(backups)"
case "$out2" in *"이미 최신 상태"*) ok "멱등 메시지 출력" ;; *) ng "멱등 메시지 없음" ;; esac

out3=$(run_uninstall 2>&1) || ng "제거 실패: $out3"
check "제거 후 .zshrc 마커 0개"  0 "$(markers "$FAKE/.zshrc")"
check "제거 후 .bashrc 마커 0개" 0 "$(markers "$FAKE/.bashrc")"
if [ -f "$PFX/claude-profiles.sh" ]; then ng "제거 후 스크립트가 남음"; else ok "스크립트 제거됨"; fi
if [ -d "$FAKE/.claude-profiles" ]; then ok "프로필 디렉터리는 유지됨 (기본 동작)"; else ng "프로필 디렉터리가 지워짐"; fi
if grep -q '기존 zshrc 내용' "$FAKE/.zshrc"; then ok "제거 후에도 기존 rc 내용 보존"; else ng "제거 후 rc 내용 유실"; fi

out4=$(run_install 2>&1) || ng "재설치 실패: $out4"
check "재설치 후 마커 1개" 1 "$(markers "$FAKE/.zshrc")"

# SHELL 이 없는 환경(컨테이너, cron)에서도 set -u 로 죽지 않아야 합니다
out4b=$( (cd "$SRC_DIR" && env -u CLAUDE_PROFILE_ROOT -u SHELL HOME="$FAKE" sh ./install.sh --prefix "$PFX" --dry-run) 2>&1 )
if [ $? -eq 0 ]; then ok "SHELL 미설정 환경에서도 동작"; else ng "SHELL 미설정 환경에서 실패: $out4b"; fi

# 라이브러리 문법이 깨지면 설치가 중단되어야 합니다
BROKEN="$TMPROOT/broken"
mkdir -p "$BROKEN/tests"
cp "$SRC_DIR/install.sh" "$BROKEN/install.sh"
printf 'claude-use() { if\n' > "$BROKEN/claude-profiles.sh"
if (cd "$BROKEN" && env -u CLAUDE_PROFILE_ROOT HOME="$FAKE" sh ./install.sh --prefix "$TMPROOT/nope" >/dev/null 2>&1); then
  ng "문법이 깨진 스크립트를 그대로 설치함"
else
  ok "문법 검사 실패 시 설치 중단"
fi

# --purge-profiles 는 확인 없이는 지우지 않아야 합니다
mkdir -p "$FAKE/.claude-profiles/testacct"
out5=$(run_uninstall --purge-profiles --dry-run 2>&1) || true
if [ -d "$FAKE/.claude-profiles/testacct" ]; then ok "--dry-run 은 프로필을 지우지 않음"; else ng "--dry-run 이 프로필을 지움"; fi
case "$out5" in *testacct*) ok "삭제 대상 목록을 먼저 보여줌" ;; *) ng "삭제 대상 목록 없음" ;; esac
out6=$(run_uninstall --purge-profiles < /dev/null 2>&1) || true
if [ -d "$FAKE/.claude-profiles/testacct" ]; then ok "비대화형에서는 확인 없이 지우지 않음"; else ng "확인 없이 삭제됨"; fi
out7=$(run_uninstall --purge-profiles --yes 2>&1) || true
if [ -d "$FAKE/.claude-profiles" ]; then ng "--yes 인데 삭제되지 않음"; else ok "--yes 로 명시할 때만 삭제"; fi
if [ -d "$FAKE/.claude" ]; then ok "~/.claude 는 그대로"; else ng "~/.claude 가 사라짐"; fi

# ---------------------------------------------------------------- 깨끗한 셸 동작

head_ "6. 깨끗한 셸에서 실제 동작 (가짜 HOME)"
FUNC_PROBE="$TMPROOT/func.sh"
cat > "$FUNC_PROBE" <<'PROBE'
. "$LIB"
claude-use work >/dev/null
printf 'CONFIG_DIR=%s\n' "${CLAUDE_CONFIG_DIR#$HOME/}"
printf 'NAME=%s\n' "$(_claude_profile_name)"
for item in settings.json projects CLAUDE.md; do
  if [ -L "$HOME/.claude-profiles/work/$item" ]; then printf 'LINK:%s\n' "$item"; else printf 'MISSING:%s\n' "$item"; fi
done
claude-use default >/dev/null
printf 'AFTER_DEFAULT=%s\n' "${CLAUDE_CONFIG_DIR-unset}"
printf 'NAME=%s\n' "$(_claude_profile_name)"
claude-use ../evil 2>/dev/null && printf 'ESCAPE=허용됨\n' || printf 'ESCAPE=차단됨\n'
printf 'LIST=%s\n' "$(claude-profiles -q | tr -d ' \n')"
PROBE
mkdir -p "$FAKE/.claude/projects"
printf '{}\n' > "$FAKE/.claude/settings.json"
printf '# CLAUDE\n' > "$FAKE/.claude/CLAUDE.md"
FUNC_EXPECTED='CONFIG_DIR=.claude-profiles/work
NAME=work
LINK:settings.json
LINK:projects
LINK:CLAUDE.md
AFTER_DEFAULT=unset
NAME=default
ESCAPE=차단됨
LIST=*defaultwork'
for sh_name in bash zsh; do
  command -v "$sh_name" >/dev/null 2>&1 || continue
  rm -rf "$FAKE/.claude-profiles"
  case "$sh_name" in
    bash) actual=$(env -u CLAUDE_PROFILE_ROOT -u CLAUDE_CONFIG_DIR HOME="$FAKE" LIB="$SRC_DIR/claude-profiles.sh" bash --noprofile --norc "$FUNC_PROBE" 2>&1) ;;
    zsh)  actual=$(env -u CLAUDE_PROFILE_ROOT -u CLAUDE_CONFIG_DIR HOME="$FAKE" LIB="$SRC_DIR/claude-profiles.sh" zsh -f "$FUNC_PROBE" 2>&1) ;;
  esac
  check "$sh_name 프로필 전환/링크/차단" "$FUNC_EXPECTED" "$actual"
done

# ---------------------------------------------------------------- 기본 프로필 별칭

head_ "7. 기본 프로필 별칭 (CLAUDE_PROFILE_DEFAULT_NAME)"
ALIAS_PROBE="$TMPROOT/alias.sh"
cat > "$ALIAS_PROBE" <<'PROBE'
. "$LIB"
printf 'NAME1=%s\n' "$(_claude_profile_name)"
claude-use main >/dev/null
printf 'AFTER_ALIAS=%s\n' "${CLAUDE_CONFIG_DIR-unset}"
printf 'NAME2=%s\n' "$(_claude_profile_name)"
claude-use sub >/dev/null
printf 'SUB=%s\n' "${CLAUDE_CONFIG_DIR##*/}"
claude-use default >/dev/null
printf 'BACK=%s:%s\n' "${CLAUDE_CONFIG_DIR-unset}" "$(_claude_profile_name)"
printf 'LIST=%s\n' "$(claude-profiles -q | tr -d ' \n')"
printf 'COMPLETE=%s\n' "$(_claude_profile_names | tr '\n' ',')"
PROBE
ALIAS_EXPECTED='NAME1=main
AFTER_ALIAS=unset
NAME2=main
SUB=sub
BACK=unset:main
LIST=*mainsub
COMPLETE=main,default,sub,'
for sh_name in bash zsh; do
  command -v "$sh_name" >/dev/null 2>&1 || continue
  rm -rf "$FAKE/.claude-profiles"
  case "$sh_name" in
    bash) actual=$(env -u CLAUDE_PROFILE_ROOT -u CLAUDE_CONFIG_DIR HOME="$FAKE" LIB="$SRC_DIR/claude-profiles.sh" CLAUDE_PROFILE_DEFAULT_NAME=main bash --noprofile --norc "$ALIAS_PROBE" 2>/dev/null) ;;
    zsh)  actual=$(env -u CLAUDE_PROFILE_ROOT -u CLAUDE_CONFIG_DIR HOME="$FAKE" LIB="$SRC_DIR/claude-profiles.sh" CLAUDE_PROFILE_DEFAULT_NAME=main zsh -f "$ALIAS_PROBE" 2>/dev/null) ;;
  esac
  check "$sh_name 별칭 전환/표시/완성" "$ALIAS_EXPECTED" "$actual"
done

# 같은 이름의 프로필 디렉터리가 있으면 별칭을 포기해야 합니다 (그 계정이 가려지면 안 됨)
COLLIDE_PROBE="$TMPROOT/collide.sh"
cat > "$COLLIDE_PROBE" <<'PROBE'
. "$LIB"
printf 'NAME=%s\n' "$(_claude_profile_name)"
claude-use main >/dev/null
printf 'DIR=%s\n' "${CLAUDE_CONFIG_DIR##*/}"
PROBE
rm -rf "$FAKE/.claude-profiles"
mkdir -p "$FAKE/.claude-profiles/main"
collide=$(env -u CLAUDE_PROFILE_ROOT -u CLAUDE_CONFIG_DIR HOME="$FAKE" LIB="$SRC_DIR/claude-profiles.sh" CLAUDE_PROFILE_DEFAULT_NAME=main bash --noprofile --norc "$COLLIDE_PROBE" 2>/dev/null)
check "이름 충돌 시 별칭 포기" 'NAME=default
DIR=main' "$collide"
collide_err=$(env -u CLAUDE_PROFILE_ROOT -u CLAUDE_CONFIG_DIR HOME="$FAKE" LIB="$SRC_DIR/claude-profiles.sh" CLAUDE_PROFILE_DEFAULT_NAME=main bash --noprofile --norc "$COLLIDE_PROBE" 2>&1 >/dev/null)
case "$collide_err" in *"쓸 수 없어"*) ok "충돌을 셸 시작 때 한 번 경고" ;; *) ng "충돌 경고 없음: $collide_err" ;; esac

# 잘못된 이름은 조용히 default 로
bad=$(env -u CLAUDE_PROFILE_ROOT -u CLAUDE_CONFIG_DIR HOME="$FAKE" LIB="$SRC_DIR/claude-profiles.sh" CLAUDE_PROFILE_DEFAULT_NAME='../evil' bash --noprofile --norc -c '. "$LIB"; _claude_profile_name' 2>/dev/null)
check "잘못된 별칭은 default 로" default "$bad"

head_ "8. install.sh --default-name"
rm -rf "$FAKE/.claude-profiles"
dn_line() { sed -n 's/^CLAUDE_PROFILE_DEFAULT_NAME=//p' "$FAKE/.zshrc"; }
run_install --default-name alpha >/dev/null 2>&1
check "이름 지정 설치" alpha "$(dn_line)"
check "마커는 여전히 1개" 1 "$(markers "$FAKE/.zshrc")"
run_install --default-name beta >/dev/null 2>&1
check "이름 변경" beta "$(dn_line)"
out_keep=$(run_install 2>&1)
check "이름 없이 재설치하면 유지" beta "$(dn_line)"
case "$out_keep" in *"이미 최신 상태"*) ok "유지 시 rc 를 다시 쓰지 않음" ;; *) ng "유지인데 rc 를 다시 씀" ;; esac
run_install --default-name default >/dev/null 2>&1
check "default 로 되돌리면 줄 제거" "" "$(dn_line)"
if (cd "$SRC_DIR" && env -u CLAUDE_PROFILE_ROOT HOME="$FAKE" CLAUDE_PROFILES_NO_TTY=1 sh ./install.sh --prefix "$PFX" --default-name '../evil' >/dev/null 2>&1); then
  ng "잘못된 --default-name 을 받아들임"
else
  ok "잘못된 --default-name 거부"
fi

head_ "9. 설치 중 이름 묻기"
# 가짜 tty 통로로 대화형 경로를 시험합니다 (실제 tty 는 script(1) 로 따로 확인).
ask() { # ask <입력> [추가 옵션...]
  input="$1"; shift
  printf '%b' "$input" | (cd "$SRC_DIR" && env -u CLAUDE_PROFILE_ROOT HOME="$FAKE" \
    CLAUDE_PROFILES_ASSUME_TTY=1 sh ./install.sh --prefix "$PFX" --shell both "$@" 2>&1)
}
rm -rf "$FAKE/.claude-profiles"
run_install --default-name default >/dev/null 2>&1   # 초기화

out=$(ask 'work-main\n')
check "물어본 이름이 등록됨" work-main "$(dn_line)"
case "$out" in *"이름:"*) ok "이름을 물어봄" ;; *) ng "묻지 않음" ;; esac

out=$(ask '\n')
check "Enter 만 누르면 기존 값 유지" work-main "$(dn_line)"

out=$(ask 'a b\nwork-b\n')
check "잘못된 이름은 다시 물어봄" work-b "$(dn_line)"
case "$out" in *"영문/숫자"*) ok "잘못된 이름을 알려 줌" ;; *) ng "안내 없음" ;; esac

mkdir -p "$FAKE/.claude-profiles/taken"
out=$(ask 'taken\nwork-c\n')
check "기존 프로필과 같은 이름은 거부" work-c "$(dn_line)"
case "$out" in *"이미 있습니다"*) ok "충돌을 이유와 함께 알려 줌" ;; *) ng "충돌 안내 없음" ;; esac

before="$(dn_line)"
out=$(ask 'ignored\n' --no-prompt)
check "--no-prompt 면 묻지 않음" "$before" "$(dn_line)"
out=$(ask 'ignored\n' --default-name explicit)
check "--default-name 이 있으면 묻지 않음" explicit "$(dn_line)"

# 비대화형(파이프/CI)에서는 멈추지 않고 기존 값을 유지해야 합니다
out=$( (cd "$SRC_DIR" && env -u CLAUDE_PROFILE_ROOT HOME="$FAKE" CLAUDE_PROFILES_NO_TTY=1 sh ./install.sh --prefix "$PFX" --shell both < /dev/null) 2>&1 )
check "비대화형에서는 묻지 않고 유지" explicit "$(dn_line)"
case "$out" in *"이름:"*) ng "비대화형인데 물어봄" ;; *) ok "비대화형에서는 묻지 않음" ;; esac

head_ "10. 자립형 번들과 업데이트"

# 번들 생성이 결정적인지, 그리고 dist 가 최신인지
BSRC="$TMPROOT/bundlesrc"
mkdir -p "$BSRC"
cp "$SRC_DIR/claude-profiles.sh" "$SRC_DIR/install.sh" "$SRC_DIR/uninstall.sh" "$SRC_DIR/bundle.sh" "$BSRC/"
(cd "$BSRC" && sh ./bundle.sh >/dev/null 2>&1)
check "dist/install-standalone.sh 가 최신" \
  "$(cksum < "$SRC_DIR/dist/install-standalone.sh")" "$(cksum < "$BSRC/dist/install-standalone.sh")"

# 셸 세 가지로 번들 설치 — 품고 있던 파일이 바이트 그대로 나와야 합니다
for sh_name in sh bash zsh; do
  command -v "$sh_name" >/dev/null 2>&1 || continue
  BH="$TMPROOT/bundlehome-$sh_name"
  rm -rf "$BH"; mkdir -p "$BH/.claude"; printf '# rc\n' > "$BH/.zshrc"
  if env -u CLAUDE_PROFILE_ROOT -u CLAUDE_PROFILES_HOME HOME="$BH" CLAUDE_PROFILES_NO_TTY=1 \
      "$sh_name" "$SRC_DIR/dist/install-standalone.sh" --prefix "$BH/pfx" --shell zsh --no-prompt >/dev/null 2>&1; then
    lib_ok=n; uni_ok=n
    [ "$(cksum < "$SRC_DIR/claude-profiles.sh")" = "$(cksum < "$BH/pfx/claude-profiles.sh")" ] && lib_ok=y
    [ "$(cksum < "$SRC_DIR/uninstall.sh")" = "$(cksum < "$BH/pfx/uninstall.sh")" ] && uni_ok=y
    check "$sh_name 번들 설치 후 파일 바이트 일치" "y y" "$lib_ok $uni_ok"
  else
    ng "$sh_name 번들 설치 실패"
  fi
done

BH="$TMPROOT/bundlehome-sh"
check "번들 설치는 출처를 URL 로 기록" \
  "url:https://raw.githubusercontent.com/shaichoi/claude-profiles/main/dist/install-standalone.sh" \
  "$(sed -n 's/^source=//p' "$BH/pfx/install-info" 2>/dev/null)"
case "$(sed -n 's/^version=//p' "$BH/pfx/install-info" 2>/dev/null)" in
  [0-9]*.[0-9]*.[0-9]*) ok "버전이 install-info 에 기록됨" ;;
  *) ng "버전 기록 안 됨" ;;
esac

vout=$(env -u CLAUDE_PROFILE_ROOT HOME="$BH" CLAUDE_PROFILES_HOME="$BH/pfx" \
  LIB="$BH/pfx/claude-profiles.sh" bash --noprofile --norc -c '. "$LIB"; claude-profiles -v' 2>&1)
case "$vout" in *"claude-profiles 1."*) ok "claude-profiles -v 가 버전 표시" ;; *) ng "버전 표시 안 됨: $vout" ;; esac
case "$vout" in *"설치 출처"*) ok "claude-profiles -v 가 설치 출처 표시" ;; *) ng "출처 표시 안 됨" ;; esac

# 로컬 디렉터리 출처로 설치한 뒤 claude-profiles-update 로 복구되는지
PKG="$TMPROOT/pkgdir"
rm -rf "$PKG"; mkdir -p "$PKG"
cp "$SRC_DIR/claude-profiles.sh" "$SRC_DIR/install.sh" "$SRC_DIR/uninstall.sh" "$PKG/"
chmod +x "$PKG/install.sh" "$PKG/uninstall.sh"
UH="$TMPROOT/updhome"
rm -rf "$UH"; mkdir -p "$UH/.claude"; printf '# rc\n' > "$UH/.zshrc"
env -u CLAUDE_PROFILE_ROOT -u CLAUDE_PROFILES_HOME HOME="$UH" CLAUDE_PROFILES_NO_TTY=1 \
  sh "$PKG/install.sh" --prefix "$UH/pfx" --shell zsh --no-prompt >/dev/null 2>&1
check "로컬 디렉터리 설치는 출처를 dir 로 기록" "dir:$PKG" "$(sed -n 's/^source=//p' "$UH/pfx/install-info" 2>/dev/null)"

printf '# 일부러 망가뜨림\n' > "$UH/pfx/claude-profiles.sh"
uout=$(env -u CLAUDE_PROFILE_ROOT HOME="$UH" CLAUDE_PROFILES_HOME="$UH/pfx" CLAUDE_PROFILES_NO_TTY=1 \
  LIB="$PKG/claude-profiles.sh" bash --noprofile --norc -c '. "$LIB"; claude-profiles-update' 2>&1)
check "claude-profiles-update 가 라이브러리를 되돌림" \
  "$(cksum < "$SRC_DIR/claude-profiles.sh")" "$(cksum < "$UH/pfx/claude-profiles.sh")"
case "$uout" in *"업데이트 완료"*) ok "업데이트 완료 메시지" ;; *) ng "업데이트 실패: $uout" ;; esac

# 설치 정보가 없으면 안내하고 실패해야 합니다
nout=$(env -u CLAUDE_PROFILE_ROOT HOME="$UH" CLAUDE_PROFILES_HOME="$TMPROOT/nowhere" \
  LIB="$PKG/claude-profiles.sh" bash --noprofile --norc -c '. "$LIB"; claude-profiles-update' 2>&1 || true)
case "$nout" in *"설치 정보를 찾을 수 없습니다"*) ok "설치 정보 없으면 안내" ;; *) ng "안내 없음: $nout" ;; esac

# curl ... | sh 모양 (표준 입력은 파이프, 질문은 /dev/tty 에서) — python3 있을 때만
if command -v python3 >/dev/null 2>&1; then
  PH="$TMPROOT/ptyhome"
  rm -rf "$PH"; mkdir -p "$PH/.claude"; printf '# rc\n' > "$PH/.zshrc"
  cat > "$TMPROOT/pipe-prompt-probe.py" <<'PYEOF'
import os, pty, select, sys, time
home, bundle, prefix = sys.argv[1], sys.argv[2], sys.argv[3]
env = dict(os.environ, HOME=home)
for k in ("CLAUDE_PROFILE_ROOT", "CLAUDE_PROFILES_HOME", "CLAUDE_PROFILES_NO_TTY"):
    env.pop(k, None)
cmd = ["sh", "-c", "cat %s | sh -s -- --prefix %s --shell zsh" % (bundle, prefix)]
pid, master = pty.fork()
if pid == 0:
    os.execvpe("sh", cmd, env)
    os._exit(1)
buf, sent, start = b"", False, time.time()
while time.time() - start < 90:
    r, _, _ = select.select([master], [], [], 1)
    if r:
        try:
            d = os.read(master, 4096)
        except OSError:
            break
        if not d:
            break
        buf += d
        if not sent and "이름: ".encode() in buf:
            os.write(master, "piped-name\n".encode())
            sent = True
    if os.waitpid(pid, os.WNOHANG)[0] != 0:
        break
sys.exit(0 if sent else 1)
PYEOF
  if python3 "$TMPROOT/pipe-prompt-probe.py" "$PH" "$SRC_DIR/dist/install-standalone.sh" "$PH/pfx" >/dev/null 2>&1; then
    ok "파이프로 실행해도 /dev/tty 에서 이름을 물어봄"
    check "물어본 이름이 rc 에 반영됨" piped-name "$(sed -n 's/^CLAUDE_PROFILE_DEFAULT_NAME=//p' "$PH/.zshrc")"
  else
    ng "파이프 설치에서 질문이 뜨지 않음"
  fi
else
  echo "  (python3 없음: 파이프 프롬프트 검사 생략)"
fi

# ---------------------------------------------------------------- 실제 홈 무결성

head_ "11. 실제 홈 디렉터리 무결성"
REAL_AFTER=$(snapshot_real_home)
check "실제 rc 파일 변경 없음" "$REAL_BEFORE" "$REAL_AFTER"
if [ -e "$REAL_HOME/.local/share/claude-profiles/claude-profiles.sh" ]; then
  echo "  (참고: 실제 홈에 이미 설치되어 있습니다. 테스트는 건드리지 않았습니다.)"
fi

printf '\n통과 %d / 실패 %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
