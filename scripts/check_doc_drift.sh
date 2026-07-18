#!/usr/bin/env bash
# Deterministic doc-drift gate for CI.
#
# This is the MECHANICAL subset of the full doc-drift review: the checks that
# can be decided with zero judgement, so they are safe to fail a build on.
# The fuzzy prose checks (scenario/checkpoint wording, intra-doc numeric
# self-consistency, "is this version tag historical or a current-state claim")
# stay with the human-in-the-loop reviewer — they false-positive too easily to
# gate a push.
#
# Scope: the active public English docs only. README.md, DOCUMENTATION.md,
# SETUP.md. CHANGELOG.md is FROZEN provenance — a path named
# there (e.g. a since-deleted script) is honored lineage, not drift, and is
# never scanned here.
#
#   FATAL (exit 1): a repo-relative path referenced in an active doc that does
#                   not exist on disk. A dead reference is an unambiguous bug.
#   WARN  (exit 0): version badge vs the newest tag, retired build commands,
#                   and the "N EL0 scenarios" count vs the boot contract.
#                   Printed for visibility; never fails CI.
#
# Usage: scripts/check_doc_drift.sh   (run from the repo root)
set -uo pipefail

DOCS="README.md DOCUMENTATION.md SETUP.md"
fatal=0

note()  { printf '%s\n' "$*"; }
warn()  { printf 'WARN  %s\n' "$*"; }
block() { printf 'BLOCK %s\n' "$*"; fatal=1; }

# --- FATAL: dead repo-relative paths ----------------------------------------
note "== dead-path check (FATAL) =="
# Extract MAXIMAL slashed tokens (so `armstub/src/x.S` is not truncated to
# `src/x.S`), then keep only those whose first segment is a real top-level
# directory — that both filters out non-paths (`and/or`) and anchors the path
# at its true root. Skip <placeholder> tokens and build artifacts (*.elf etc.
# are generated, legitimately absent from a clean checkout — not doc drift).
raw=$(grep -rhoE '[A-Za-z0-9_][A-Za-z0-9_./-]*/[A-Za-z0-9_.-]+' $DOCS 2>/dev/null \
      | sed -E 's/[.,:;)]+$//' \
      | sort -u)
dead=0
for p in $raw; do
  case "$p" in *'<'*|*'>'*|*/) continue ;; esac      # placeholder / bare dir
  case "$p" in *.elf|*.img|*.o|*.bin|*.a) continue ;; esac  # build artifacts
  first=${p%%/*}
  [ -d "$first" ] || continue                        # first segment not a repo dir
  [ -e "$p" ] && continue
  # Exists somewhere as a path SUFFIX? Then it is a relatively-shown reference
  # (e.g. a path drawn nested inside an ASCII tree diagram), not a dead one.
  # Only a segment sequence that appears NOWHERE in the repo is a true
  # rename/deletion worth failing on.
  find . -path "*/$p" -not -path './target/*' -not -path './rust-out/*' 2>/dev/null | grep -q . && continue
  hits=$(grep -rnF "$p" $DOCS 2>/dev/null | head -3 | sed 's/^/    /')
  block "dead path: $p"
  printf '%s\n' "$hits"
  dead=$((dead+1))
done
[ "$dead" -eq 0 ] && note "ok: every referenced repo path exists"

# --- WARN: version badge vs newest tag --------------------------------------
note ""
note "== version badge vs newest tag (WARN) =="
tag=$(git tag --sort=-v:refname 2>/dev/null | head -1)
badge=$(grep -oE 'badge/version-v[0-9]+\.[0-9]+\.[0-9]+' README.md 2>/dev/null | head -1 | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+')
if [ -z "$tag" ]; then
  warn "no git tags reachable (shallow clone?) — skipped. For full coverage the CI checkout needs fetch-depth: 0."
elif [ -z "$badge" ]; then
  warn "no version-vX.Y.Z badge found in README.md — skipped."
elif [ "$badge" = "$tag" ]; then
  note "ok: README badge $badge == newest tag $tag"
else
  # numeric compare: badge behind tag is the real smell
  lower=$(printf '%s\n%s\n' "${badge#v}" "${tag#v}" | sort -V | head -1)
  if [ "$lower" = "${badge#v}" ]; then
    warn "README badge $badge is BEHIND newest tag $tag — bump the badge (or tag is ahead of a doc update)."
  else
    warn "README badge $badge is AHEAD of newest tag $tag — fine mid-development, stale if the tag was expected."
  fi
fi

# --- WARN: retired build commands remain in active docs ---------------------
note ""
note "== retired build command references (WARN) =="
if grep -qE 'zig build([[:space:]]|`)' $DOCS 2>/dev/null; then
  warn "active docs still name the retired zig build command surface; synchronize them during the scheduled public-doc refresh."
else
  note "ok: active docs no longer name the retired zig build command surface"
fi

# --- WARN: "N EL0 scenarios" count vs the boot contract ---------------------
note ""
note "== EL0 scenario count (WARN) =="
contract=$(grep -oE '[0-9]+ EL0 scenarios' scripts/run_qemu_test.sh 2>/dev/null | head -1 | grep -oE '^[0-9]+')
if [ -n "$contract" ]; then
  bad=$(grep -rnoE '[0-9]+ EL0 scenarios' $DOCS 2>/dev/null | grep -vE ":$contract EL0 scenarios$" || true)
  if [ -n "$bad" ]; then
    warn "a doc states a different EL0-scenario count than the contract ($contract):"
    printf '%s\n' "$bad" | sed 's/^/    /'
  else
    note "ok: no doc contradicts the contract's $contract EL0 scenarios"
  fi
else
  warn "could not read the EL0-scenario count from scripts/run_qemu_test.sh — skipped."
fi

note ""
if [ "$fatal" -ne 0 ]; then
  note "RESULT: FAIL — dead doc references above. Fix the path (or remove the reference)."
  exit 1
fi
note "RESULT: pass (FATAL checks clean; warnings above are advisory — run /doc-drift for the deep pass)."
exit 0
