# Contributing

Thanks for helping improve the framework. It is small on purpose; please keep it
that way. The bar for changes is **correctness and portability**, not features.

## Run the tests

```sh
sh tests/run-tests.sh
```

It builds a throwaway sandbox, drives the helper scripts, and asserts on their
behaviour. It must print `N passed, 0 failed` and exit 0. CI runs it on Linux and
macOS, with and without `jq` — see `.github/workflows/test.yml`.

Run it under more than one shell before sending a change:

```sh
/bin/sh tests/run-tests.sh     # macOS: this is bash 3.2
dash    tests/run-tests.sh     # strict POSIX
```

Every behaviour change to a script must come with a test (or an updated one). A
test should fail if the behaviour it checks regresses — assert on **exit codes and
absence of side effects**, not just on a message substring.

## POSIX shell rules (the scripts are `/bin/sh`, not bash)

The scripts run on macOS (BSD userland) and Linux (GNU) under whatever `/bin/sh`
is — often bash 3.2 or dash. Stick to POSIX. Traps that have already bitten us:

- **No `case ... esac` inline inside `$( … )`** — bash 3.2 fails to parse it. Pull
  it into a function or use parameter expansion / `tr`.
- **No GNU-only `sed`/`grep` features** — e.g. `sed` `\|` alternation, `-i` without
  an argument, `grep -P`. Use POSIX BRE/ERE only.
- **No GNU-only `find` predicates** — `-delete`, `-mindepth`, `-maxdepth`,
  `-printf`. Use shell loops + `rm`.
- **No `local`, no arrays, no `[[ ]]`, no process substitution.** Use `[ ]`,
  positional params, and plain pipes.
- **Quote every expansion** (`"$var"`), and assume paths may contain spaces.
- `jq` is **optional**: any script that uses it must keep working (degrading
  safely) when it is absent, and no safety gate may depend on it.

## Protocol changes

`PROTOCOL.md` is the authoritative contract; `PRIMARY_AGENT.md` and
`SECONDARY_AGENT.md` are the playbooks. If you change behaviour, update all three
plus the relevant template, and add a `CHANGELOG.md` entry. Preserve the safety
invariants in `PROTOCOL.md §10` — bounded loops, the hard escalation cap, the
`human_required` pause, the single-owner decider, and the rule that the progress
overlay can only stop the loop *earlier*, never later.

## Scope

Prefer the smallest change that fixes the problem. New abstractions, options, or
"flexibility" that nobody asked for will be sent back. If you spot unrelated dead
code, mention it — don't sweep it into your change.
