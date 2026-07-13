# Homebrew tap setup — manual steps

Not run automatically (creating/pushing a public GitHub repo is something you
run yourself). Two repos are involved, both currently unset up:

- `khr898/ntfsmac` — the main repo this working tree becomes. No git remote is
  configured yet (`git remote -v` is empty).
- `khr898/homebrew-ntfsmac` — the tap repo. **Naming is mandatory, not a
  preference**: Homebrew only finds a third-party tap named exactly
  `homebrew-<tapname>` — `khr898/ntfsmac` as a tap requires the backing repo to
  be literally `khr898/homebrew-ntfsmac`. `brew tap khr898/ntfsmac` resolves
  that name to that repo by convention; any other repo name won't be found.

## 0. Prerequisite: authenticate gh

```sh
gh auth login
```

Confirm it worked:

```sh
gh auth status
```

## 1. Push the main repo

```sh
cd "/Volumes/My Shared Files/Windows Shared Folder/ntfsmac"
gh repo create khr898/ntfsmac --public --source=. --remote=origin
git push -u origin main
```

(The tap repo's `Formula/ntfsmac.rb` `head` URL already points at
`https://github.com/khr898/ntfsmac.git` — nothing to change there once this
repo exists at that address.)

## 2. Push the tap repo

The tap repo already exists locally at
`/Volumes/My Shared Files/Windows Shared Folder/homebrew-ntfsmac` (git-initialized,
`Formula/ntfsmac.rb` + `tests/formula.bats` + `README.md` committed, no remote yet —
`Formula/ntfsmac.rb` no longer lives in this main repo at all). Just needs a remote
and a push:

```sh
cd "/Volumes/My Shared Files/Windows Shared Folder/homebrew-ntfsmac"
gh repo create khr898/homebrew-ntfsmac --public --source=. --remote=origin --description "Homebrew tap for ntfsmac"
git push -u origin main
```

Whenever the formula needs to change, edit it directly in that tap repo (or copy
in an updated version) and push again — the tap only ever holds the formula
file(s), it isn't a mirror of the whole project.

## 3. Verify (from any Mac, after step 2)

```sh
brew tap khr898/ntfsmac
brew install ntfsmac
ntfsmac diagnose
```

Uninstall check (must leave nothing behind — see the `post_uninstall` hook
in the Formula):

```sh
brew uninstall ntfsmac
ls ~/.anylinuxfs 2>/dev/null          # should not exist
ls ~/Library/Logs/anylinuxfs* 2>/dev/null   # should not exist
```

## Notes

- `brew audit --strict khr898/ntfsmac/ntfsmac` is already verified clean
  locally (the tap repo's `tests/formula.bats`) against a scratch tap — this
  doc is only about making that tap real/public, not about formula
  correctness.
- A full `brew install` (real source build: Rust cross-compile + Go build +
  Alpine rootfs pull) was tested locally against a `file://`-sourced scratch
  tap in this session — see the conversation for the current result. That
  local test never touched GitHub; it's a separate concern from the steps
  above.
- **Keeping the two repos in sync:** no automated cross-repo CI (decided —
  adds a PAT + cross-repo dependency for a layout that rarely changes).
  Whenever `install.sh` or `build/build-all.sh` changes what gets installed
  where (`bin`, `libexec`, `lib` contents/paths), manually re-run the tap
  repo's `tests/formula.bats` (`bats tests/formula.bats`, needs `brew`) —
  its `brew audit --strict` + structural checks catch a formula that no
  longer matches this repo's real output — before pushing the tap.
