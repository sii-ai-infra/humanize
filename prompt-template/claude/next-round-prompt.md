Your work is not finished. Read and execute the below with ultrathink.

## Original Implementation Plan

**IMPORTANT**: Before proceeding, review the original plan you are implementing:
@{{PLAN_FILE}}

This plan contains the full scope of work and requirements. Ensure your work aligns with this plan.

---

## Round Re-anchor (REQUIRED FIRST STEP)

Before writing code:
- Re-read @{{PLAN_FILE}}
- Re-read @{{GOAL_TRACKER_FILE}}
- Re-read the most recent round summaries/reviews that led to this round
- Write the current round contract to @{{ROUND_CONTRACT_FILE}}

Your round contract must contain:
- Exactly one **mainline objective**
- The 1-2 target ACs for this round
- Which issues are truly **blocking** that mainline objective
- Which issues are **queued** and explicitly out of scope
- Concrete success criteria for this round

Do not start implementation until the round contract exists.

## Task Lane Rules

Use the Task system (TaskCreate, TaskUpdate, TaskList) with one required tag per task:
- `[mainline]` for plan-derived work that directly advances this round's objective
- `[blocking]` for issues that prevent the mainline objective from succeeding safely
- `[queued]` for non-blocking bugs, cleanup, or follow-up work

Rules:
- `[mainline]` work is the round's primary success condition
- `[blocking]` work is allowed only when it truly blocks the mainline objective
- `[queued]` work must be documented but must NOT replace the round objective
- If a new bug does not block the current objective, tag it `[queued]` and keep moving on mainline work

Before executing each task in this round:
1. Read @{{BITLESSON_FILE}}
2. Run `bitlesson-selector` for each task/sub-task
3. Follow selected lesson IDs (or `NONE`) during implementation

---
Below is Codex's review result:
<!-- CODEX's REVIEW RESULT START -->
{{REVIEW_CONTENT}}
<!-- CODEX's REVIEW RESULT  END  -->
---

## Goal Tracker Reference

Before starting work, **read** @{{GOAL_TRACKER_FILE}} to understand:
- The Ultimate Goal and Acceptance Criteria you're working toward
- Which tasks are Active, Completed, or Deferred
- Which side issues are blocking vs queued
- Any Plan Evolution that has occurred
- The latest side-issue state that needs attention

**IMPORTANT**: Keep the mutable section of `goal-tracker.md` up to date during the round.
Do NOT change the immutable section after Round 0.
If you cannot safely reconcile the tracker yourself, include an optional "Goal Tracker Update Request" section in your summary (see below).

## Kernel Optimization Re-anchor (when applicable)

If this task is a kernel optimization task, perform these steps before writing code:

1. **Start from latest feedback**: read the latest summary/review conclusion and its existing candidate/report references. Check actual correctness, required case/device coverage, geometric speedup, weakest/regressed cases and unresolved issues. Missing metrics remain unknown; exit status alone does not establish full validity. Consult `leaderboard.csv`, `docs/draft.md`, earlier reports or `git log --oneline -- solution/` for a concrete unresolved question, such as a prior rejection or candidate lineage.
2. **Define the next experiment**: briefly connect current task facts, measured evidence and applicable knowledge to the proposed change and a distinguishing check in the existing Selected experiment/summary. Reuse saved method references; retrieve more only for a named question that can change the choice. A returned method is not automatically selected, and an unmeasured bottleneck remains a hypothesis. End retrieval when an actionable experiment or condition check is defined.
3. **Use measured feedback**: reuse available profiles and inspect the smallest relevant additional measurement when needed. Choose incremental tuning, an expression/algorithm change, fusion or a different layout/parallelization from the evidence; no fixed number of rounds requires a structural rewrite. Related changes and multiple evaluations are allowed within this round without new per-call forms or extra round charges. Keep the existing profiling rule: deep diagnostic profiling follows a kernel-code change; full gates and failed collection retries follow the contract.
4. **Record outcome and next decision**: after running the existing evaluation commands, cite the actual change, candidate version, report/job reference and validation scope in the existing summary. Briefly say whether the measurement supports the hypothesis and what to keep, adjust or replace. Preserve meaningful failed conditions and counterexamples; small debugging steps may be summarized together. Planned work is not measured evidence; partial-case gains are not full results; an older candidate's report cannot certify changed source. Missing data/infrastructure failure does not refute an algorithm.
5. **Preserve the handoff**: carry the outcome, unresolved review issues, necessary counterexamples and next decision in the existing summary/handoff. Recover the same loop and remaining budget after compact/resume. The Stop-gate full evaluation and contract constraints remain required.

## Mainline Guardrails

- Keep the mainline objective from @{{ROUND_CONTRACT_FILE}} stable for this round
- Do not let queued issues take over the round
- If Codex reported several findings, classify them into:
  - mainline gaps
  - blocking side issues
  - queued side issues
- Only mainline gaps and blocking side issues should drive the next code changes
