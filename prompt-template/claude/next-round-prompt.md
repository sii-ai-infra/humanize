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

1. **Read optimization history**: read `leaderboard.csv`, `docs/draft.md` (attempt ledger / milestone ladder), and run `git log --oneline -- solution/` to understand what has been tried, what speedups were achieved, and what approaches were rejected.
2. **Profile-guided diagnosis**: if the previous round did not advance the speedup target, identify WHY using profiling evidence whenever available. Was it memory bandwidth, memory access pattern/coalescing, occupancy, register pressure, shared-memory behavior, synchronization, compute throughput, or launch overhead? If profiler evidence is missing and profiling is feasible, run or request the smallest relevant profiling experiment before selecting the next optimization.
3. **Consider structural rewrites**: incremental edits (changing block sizes, adding pragmas, minor loop reordering) have diminishing returns. If the current kernel structure has been tuned for 2+ rounds without meaningful improvement, consider:
   - Rewriting the kernel with a fundamentally different algorithm or data layout
   - Fusing multiple operations that are currently separate kernels
   - Changing the parallelization strategy (e.g., thread-per-row to warp-per-row, or persistent kernel)
   - Using hardware-specific features not yet exploited (TMA, warp specialization, shared memory swizzling)
   - Consult the **KernelWiki** knowledge base to provide optimization guidance
4. **Use both evidence sources**: treat profiling analysis and KernelWiki guidance as equally important. The selected optimization should be justified by measured bottlenecks and relevant knowledge-base recommendations.
5. **Record the decision**: in your round contract, explicitly state whether this round is an incremental tune or a structural rewrite, and why. Include the profiling evidence or explain why profiling was unavailable.

## Mainline Guardrails

- Keep the mainline objective from @{{ROUND_CONTRACT_FILE}} stable for this round
- Do not let queued issues take over the round
- If Codex reported several findings, classify them into:
  - mainline gaps
  - blocking side issues
  - queued side issues
- Only mainline gaps and blocking side issues should drive the next code changes
