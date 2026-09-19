# claude-profiles

Claude Code 계정을 셸에서 즉시 바꿔 쓰는 도구입니다. bash와 zsh 모두에서 동작하고,
`python3`나 `jq` 없이 POSIX 도구(sed, awk, tr, find)만으로 돌아갑니다.

```
$ claude-use personal
프로필 전환: personal  (/home/me/.claude-profiles/personal)
  계정: me@example.com / Personal / pro

$ claude-use default
프로필 전환: default  (/home/me/.claude)
  계정: me@company.com / Acme / team
```

## 동작 원리

Claude Code는 `CLAUDE_CONFIG_DIR` 환경변수로 설정 디렉터리를 정합니다.
자격 증명(`.credentials.json`)도 그 디렉터리에 들어가므로, 디렉터리를 나누면
계정이 완전히 분리됩니다. 이 도구는 환경변수만 바꿔 줍니다.

- 기본 프로필 `default` = `~/.claude` (환경변수를 **해제**한 상태)
- 추가 프로필 = `~/.claude-profiles/<이름>`

계정과 무관한 항목은 `~/.claude`로 심볼릭 링크하므로, 계정을 바꿔도
`--continue`와 자동 기억, 설정이 그대로 유지됩니다.

전환은 **그 셸에서만** 유효합니다. 새 터미널은 항상 `default`로 시작합니다.

## 요구사항

- Claude Code CLI (`claude`) — 설치 스크립트가 존재와 동작을 먼저 확인합니다
- bash 또는 zsh
- 표준 유닉스 도구: `sed`, `awk`, `tr`, `find`, `grep`, `mktemp`
  (`python3`, `jq`, `cmp`, `diff`는 필요 없습니다)

## 설치

한 줄이면 됩니다. 인터넷이 되는 서버라면 저장소를 받지 않아도 설치됩니다.

```sh
curl -fsSL https://raw.githubusercontent.com/shaichoi/claude-profiles/main/dist/install-standalone.sh | sh
```

`dist/install-standalone.sh`는 라이브러리와 제거 스크립트를 안에 품은 자립형
단일 파일입니다(`bundle.sh`가 만듭니다). 파이프로 실행해도 터미널이 있으면
기본 프로필 이름을 물어봅니다. 옵션을 주려면 `-s --`를 붙이세요.

```sh
curl -fsSL <같은 URL> | sh -s -- --default-name work-main
```

저장소를 받아서 설치해도 됩니다. 이쪽은 테스트까지 함께 받습니다.

```sh
git clone git@github.com:shaichoi/claude-profiles.git
cd claude-profiles
./install.sh
```

설치 스크립트가 하는 일:

1. `claude` 존재 확인, 버전 출력, 임시 설정 디렉터리로 실제 동작 확인
2. `claude-profiles.sh`와 `uninstall.sh`를 `~/.local/share/claude-profiles/`에 복사
3. 터미널에서 직접 실행하면 기본 프로필을 부를 이름을 물어봄 (Enter 는 기존값 유지)
4. `~/.zshrc`와 `~/.bashrc`에 마커 블록으로 등록 (있는 rc 파일 + 현재 셸 기준)
5. 업데이트에 쓸 설치 출처를 `install-info`에 기록

이름을 묻는 건 사람이 터미널에서 실행할 때뿐입니다. 파이프나 CI처럼 입력이 없는
환경에서는 묻지 않고 기존 설정을 그대로 씁니다. `--default-name`이나
`--no-prompt`를 주면 역시 묻지 않습니다.

여러 번 실행해도 안전합니다. 이미 최신이면 아무것도 바꾸지 않고, 내용이
바뀔 때만 `~/.zshrc.claude-profiles.bak.<시각>`으로 백업합니다.

| 옵션 | 설명 |
| --- | --- |
| `--prefix DIR` | 스크립트 설치 위치 (기본 `~/.local/share/claude-profiles`) |
| `--shell auto\|bash\|zsh\|both\|none` | rc 등록 대상 (기본 `auto`) |
| `--default-name <이름>` | 기본 프로필(`~/.claude`)을 부를 이름 (아래 참고) |
| `--no-prompt` | 이름을 묻지 않음 |
| `--no-migrate` | 예전 `profiles.zsh` 등록을 정리하지 않음 |
| `--skip-probe` | claude 동작 확인 건너뜀 |
| `--dry-run` | 무엇을 할지 보여주기만 함 |
| `--source SPEC` | 업데이트에 쓸 출처를 직접 지정 (`url:` / `git:` / `dir:`) |

설치 후 새 셸을 열거나 `source ~/.zshrc`를 실행하세요.

### 다른 서버에 설치하기

서버마다 위 한 줄 설치(또는 `git clone` → `./install.sh`) 후 계정 로그인입니다.

```sh
claude-use work        # 프로필 생성 및 전환
claude auth login      # 그 셸에서 로그인
claude-who             # 확인
```

자격 증명 파일을 서버 사이에 복사하는 방식은 권하지 않습니다. 토큰이 그대로
복제되고 갱신 시점에 서로 어긋날 수 있습니다. 서버마다 새로 로그인하세요.

## 업데이트

```sh
claude-profiles-update
```

설치할 때 기록해 둔 출처에서 다시 받아 재설치합니다. curl로 설치했으면 같은
URL을 다시 받고, `git clone`으로 설치했으면 `git pull --ff-only` 후 재설치합니다.
설치가 멱등이라 몇 번 돌려도 안전하고, 프로필 데이터와 로그인 상태는 그대로입니다.
끝나면 새 셸을 열어야 새 함수가 적용됩니다.

현재 버전과 설치 출처는 이렇게 봅니다.

```sh
claude-profiles -v
```

## 사용법

| 명령 | 하는 일 |
| --- | --- |
| `claude-use <이름>` | 현재 셸의 프로필 전환 (없으면 새로 만듦) |
| `claude-use default` | 기본 계정(`~/.claude`)으로 복귀 |
| `claude-who` | 현재 프로필과 로그인 계정 표시 |
| `claude-profiles` | 프로필 목록과 각 계정 표시 (`-q`는 계정 조회 생략) |
| `claude-with <이름> [인자...]` | 셸 프로필은 그대로 두고 한 번만 그 계정으로 실행 |
| `claude-profiles-update` | 설치 출처에서 다시 받아 갱신 |
| `claude-profiles -v` | 버전과 설치 출처 표시 |

프로필 이름은 영문/숫자/`.`/`_`/`-`만 쓸 수 있습니다. 기본 프로필의 이름은
`default`이고, `--default-name`으로 계정 이름을 붙일 수 있습니다(아래 참고). `claude-use`와
`claude-with`는 탭 자동 완성이 됩니다.

### 두 번째 계정 등록

```sh
claude-use personal
claude auth login
claude-who
```

### 기본 프로필에 계정 이름 붙이기

메인 계정은 `~/.claude`에 그대로 두고 이름만 붙이는 방식을 권합니다.
`~/.claude-profiles/` 밑으로 옮기면 그 계정을 다시 로그인해야 하고,
전역 설정이 `~/.claude.json`에서 `<설정 디렉터리>/.claude.json`으로 바뀌면서
아래 "알려진 함정"의 `email: null` 문제를 그대로 맞게 됩니다.

```sh
./install.sh --default-name work-main
```

터미널에서 그냥 `./install.sh`를 실행하면 이 이름을 물어봅니다.
그러면 `default` 대신 그 이름으로 보이고, 그 이름으로 전환할 수 있습니다.
`default`라는 이름도 계속 통합니다.

```
$ claude-profiles
* work-main   —  main@example.com / Acme / team
  work-sub  —  sub@example.com / Acme / team
```

rc를 직접 고쳐도 됩니다. 등록 블록보다 **앞에** 두어야 합니다.

```sh
export CLAUDE_PROFILE_DEFAULT_NAME=work-main
```

`--default-name` 없이 다시 설치하면 이미 등록된 이름을 그대로 유지합니다.
없애려면 `--default-name default`를 주세요.

같은 이름의 프로필 디렉터리가 `~/.claude-profiles/`에 있으면 별칭을 포기하고
`default`로 돌아갑니다. 별칭이 이기면 같은 이름의 프로필 계정에 영영 접근할 수
없기 때문입니다. 이때는 셸을 열 때 한 번 경고가 나옵니다.

### 특정 프로필로 터미널 시작

`~/.zshrc` 맨 끝(등록 블록 뒤)에 `claude-use personal`을 넣으세요.

### 한 번만 다른 계정으로 실행

```sh
claude-with personal -p "안녕"
```

## 공유되는 것과 분리되는 것

프로필을 만들 때 아래 항목을 `~/.claude`로 심볼릭 링크합니다.

`settings.json`, `projects`, `plugins`, `hooks`, `commands`, `agents`, `skills`, `CLAUDE.md`

덕분에 계정을 바꿔도 대화 이어가기(`--continue`), 자동 기억, 설정, 플러그인이
유지됩니다. 목록을 바꾸려면 rc에서 `CLAUDE_PROFILE_SHARED`를 덮어쓰면 됩니다
(공백 구분, 등록 블록보다 **앞에** 두어야 합니다).

```sh
export CLAUDE_PROFILE_SHARED="settings.json plugins hooks commands agents skills CLAUDE.md"
```

특정 항목만 계정별로 독립시키려면 그 링크를 지우면 됩니다.

```sh
rm ~/.claude-profiles/personal/projects   # 대화 기록과 기억을 분리
```

계정별로 분리되는 것: `.credentials.json`(자격 증명), `.claude.json`(프로젝트
신뢰 여부·기기 상태), `policy-limits.json`, `cache`, `sessions`, `session-env`,
`history.jsonl`, `backups`, `shell-snapshots`.

## 알려진 함정

**`CLAUDE_CONFIG_DIR=~/.claude`로 명시하면 계정 정보가 `null`로 나옵니다.**
변수를 해제했을 때 Claude Code는 전역 설정을 `~/.claude.json`(홈 바로 아래,
`oauthAccount` 포함)에서 읽지만, 변수를 지정하면 `<설정 디렉터리>/.claude.json`을
읽습니다. `~/.claude/.claude.json`에는 `oauthAccount`가 없어서 `loggedIn`은
`true`인데 `email`, `orgId`, `orgName`만 `null`이 됩니다. 그래서 이 도구는
기본 프로필을 다룰 때 항상 변수를 해제합니다(`claude-with default`도 마찬가지).
즉 `default` 프로필의 실제 전역 설정 파일은 `~/.claude/.claude.json`이 아니라
`~/.claude.json`입니다.

**`claude auth status`는 미로그인 상태에서 종료 코드 1을 반환합니다.**
종료 코드로 성공/실패를 판단하면 안 되고, 출력 JSON의 `loggedIn`을 봐야 합니다.

**전환은 현재 셸에만 적용됩니다.** 이미 열려 있는 다른 터미널이나 실행 중인
`claude` 세션에는 영향이 없습니다.

**macOS는 미검증입니다.** 코드는 BSD 도구(`sed -E`, `mktemp` 템플릿, `sed -i`
미사용)에 맞춰 작성했지만, 개발·검증은 Linux(WSL2, Arch, Claude Code 2.1.220,
네이티브 설치)에서만 했습니다. macOS에서는 자격 증명이 파일이 아니라 Keychain에
저장될 수 있고, 그러면 `CLAUDE_CONFIG_DIR`을 나눠도 계정이 분리되지 않을 수
있습니다. 처음 쓰는 macOS 머신에서는 `claude-use test` 후 `claude-who`로
**두 프로필이 실제로 다른 계정을 가리키는지** 먼저 확인하세요.

**macOS의 bash 로그인 셸은 `~/.bashrc`를 읽지 않습니다.** 설치 스크립트가
이 경우 안내를 출력합니다. `~/.bash_profile`에 다음 줄을 넣으세요.

```sh
[ -f ~/.bashrc ] && . ~/.bashrc
```

**조직 이름에 줄바꿈·따옴표가 들어가도 한 줄로 표시됩니다.** JSON 파싱은
`sed` + `awk`로 하며 `\"`, `\\`, `\n`, `\t`, 한글을 처리합니다. `\uXXXX`
이스케이프는 그대로 출력합니다.

## 제거

저장소가 없어도 됩니다. 설치할 때 제거 스크립트도 같이 넣어 둡니다.

```sh
~/.local/share/claude-profiles/uninstall.sh
```

저장소가 있으면 그쪽에서 실행해도 같습니다.

```sh
./uninstall.sh
```

rc 등록 블록과 설치한 스크립트만 지웁니다. **프로필 디렉터리는 남깁니다** —
그 안에 추가 계정의 자격 증명이 있어서, 지우면 다시 로그인해야 합니다.
`~/.claude`는 어떤 경우에도 건드리지 않습니다.

프로필까지 지우려면 명시적으로 요청해야 하고, 무엇이 지워지는지 먼저 보여준 뒤
`yes` 입력을 받습니다.

```sh
./uninstall.sh --purge-profiles --dry-run   # 목록만 확인
./uninstall.sh --purge-profiles             # 확인 후 삭제
```

현재 셸에 남은 함수까지 즉시 없애려면:

```sh
unset -f claude-use claude-who claude-profiles claude-with claude-profiles-update
unset CLAUDE_CONFIG_DIR
```

## 개발

라이브러리나 설치 스크립트를 고쳤으면 번들을 다시 만들어 함께 커밋합니다.
생성 결과는 결정적이라(날짜·커밋 해시를 넣지 않습니다) 테스트가 최신 여부를 검사합니다.

```sh
./bundle.sh          # dist/install-standalone.sh 재생성
./tests/run-tests.sh
```

## 검증

```sh
./tests/run-tests.sh
```

문법 검사(`bash -n`/`sh -n`/`zsh -n`), JSON 파서(따옴표·역슬래시·한글·`null`·
구두점 포함 값), 프로필 이름 검증(경로 탈출 차단), `CLAUDE_CONFIG_DIR` 격리,
설치 → 재설치(멱등) → 제거 → 재설치 순환, 깨끗한 셸(`bash --noprofile --norc`,
`zsh -f`)에서의 실제 전환, 자립형 번들(sh·bash·zsh 각각으로 설치해 품고 있던
파일이 바이트 그대로 나오는지), `claude-profiles-update`, 그리고 `curl | sh`
모양에서 `/dev/tty`로 질문이 뜨는지까지 확인합니다.

테스트는 가짜 `HOME` 안에서만 돌고 실제 홈의 rc 파일이 바뀌지 않았는지
스스로 검사합니다. `claude auth logout`은 어떤 경로로도 실행하지 않습니다.
