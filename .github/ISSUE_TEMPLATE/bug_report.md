---
name: Bug report
about: Report a problem with ntfsmac
title: "[Bug] "
labels: bug
assignees: ''
---

## Describe the bug

A clear, concise description of what's wrong.

## Steps to reproduce

1. Run `ntfsmac ...`
2. ...
3. See error

## Expected behavior

What you expected to happen instead.

## Actual behavior

What actually happened. Include full terminal output/error messages if possible.

## Diagnostics

Please run and paste the output of:

```
ntfsmac diagnose
```

## Environment

- macOS version:
- Mac model / chip (must be Apple Silicon — Intel is not supported):
- ntfsmac version (`ntfsmac --version` or the tag/commit you built from):
- Install method: Homebrew tap / built from source / GUI DMG
- NTFS driver used (ntfs-3g default, or `--fs-driver ntfs3`):

## Additional context

Anything else relevant — e.g. external drive model, whether the drive has a dirty
NTFS journal, whether this started after a macOS update, etc.
