---
title: Writing load-bearing cross-team comparison documents
date: 2026-05-25
category: docs/solutions/best-practices
module: cross-team comparison documents
problem_type: best_practice
component: documentation
severity: high
root_cause: inadequate_documentation
resolution_type: documentation_update
applies_when:
  - writing a document that compares two codebases or schemas across teams
  - assigning priority or severity ratings to a list of gaps
  - describing work authored by another contributor
  - claiming that a schema-level constraint solves a runtime problem
  - producing an analysis artifact that will be read by the people whose work is evaluated
symptoms:
  - '"schema permits X" is conflated with "runtime does X"'
  - priority labels (P0/P1/P2) mix gap size with timeline urgency
  - the same item is rated highest priority but deferred in the recommendation
  - sentences attribute decisions to a named individual ("X didn't model Y")
  - adversarial review by reading source code contradicts the document's claims
related_components:
  - development_workflow
tags:
  - cross-team
  - analysis-document
  - schema-vs-runtime
  - priority-scale
  - depersonalized-framing
  - adversarial-review
  - technical-writing
---

# Writing load-bearing cross-team comparison documents

## Context

When you write an analysis or comparison document evaluating another team's in-progress work — especially a document that will be read by the people whose code you're evaluating — three pitfalls are easy to fall into and hard to spot in your own first draft:

1. **Factual overreach** — claiming the work "solves" a problem because the *schema* allows the right answer, without verifying the *runtime* actually produces it.
2. **Muddled rating scales** — using P0/P1/P2 without anchoring to a single axis, so "P0" silently means both "biggest" and "most urgent" and the two get mashed together.
3. **Accusatory framing** — writing characterizations like "X didn't model Y" or "X chose JSONB" — which read as oversight even when the work is genuinely strong.

This guidance is the workflow that catches all three before the document ships. It emerged from authoring `docs/method/cashline-platform-ontology-comparison.md` (a comparison between an existing Salesforce schema and a colleague's in-progress Rails 8 prototype) and capturing what the revision pass had to fix.

A meta-finding worth stating up front (session history): **an adversarial-document-reviewer subagent will catch the factual and logical pitfalls, but not the framing one.** Reviewers are calibrated to technical and logical validity, not tone toward in-progress colleagues' work. The depersonalization rule has to be applied by the author up front, or surfaced by direct user feedback.

## Guidance

### Pattern 1 — Separate "schema permits" from "runtime implements"

Schemas describe what's *possible*. Code describes what *happens*. A comparison doc that conflates the two will overstate solved problems. When the doc makes a claim like "this fixes problem X," verify the claim against the runtime, not just the migration:

- Find the model file and confirm the constraint exists (uniqueness, validation, FK).
- Find every code path that *creates or matches* the model — service objects, controllers, jobs, importers.
- Confirm the constraint is reachable through every production path, not just one.
- If only some paths honour the constraint, the claim is "schema permits dedup; runtime doesn't." Write it that way and open a separate gap for the runtime hole.

**Before:**

> The schema deduplicates Customer::Organization unique on `(operator_id, normalized_name)`. Aethon-22x problem solved.

**After:**

> `Customer::Organization.normalized_name` is unique within an Operator (`app/models/customer/organization.rb:22-23`). The *schema* is right.
>
> **Caveat — the runtime doesn't yet honour the design.** The bulk-ingest pipeline never touches `Customer::Organization`; only the manual "Create new customer account" controller path does. `normalized_name` is `squish.downcase` only, so "Aethon Energy LLC" and "Aethon Energy" produce different orgs. See Gap 0.

Then promote the runtime hole to its own gap with file citations, a P-rating, a "why this matters" paragraph, and a recommendation with owner, trigger, and default-if-undecided.

### Pattern 2 — Anchor priority ratings to one explicit axis

P0/P1/P2 conflates two axes by default:
- **Size / completeness** ("how much is missing")
- **Urgency / when-decided-by** ("does this block the near-term deliverable")

These pull in opposite directions. A complete-but-non-urgent gap (e.g., Credit ontology — big but Phase 2) and an urgent-but-cheap gap (e.g., multi-invoice promises — small but cost-of-reversal grows fast) both want to be "P0" on different axes.

Pick one axis, state it in one sentence at the top of the gaps section, and re-rate every gap against it:

> P-ratings below are based on **Week-1 pilot urgency** (does this need to be decided before real data starts flowing?), not on absolute size. A P0 gap blocks the pilot's stated deliverables; a P1 gap will hurt within 3 months if untreated; a P2 gap is real but can wait.

When a gap is large on the *other* axis, preserve that signal in a parenthetical rather than letting it pull the rating:

> ### Gap 2 (P2 for Week-1; P0 for ontology completeness) — No credit ontology

This keeps the rating honest (it's not Week-1 urgent — your own recommendation says "defer to Phase 2") without losing the fact that the gap is structurally large.

Watch for the reverse case too: a gap that looks small but whose **cost-of-reversal** grows fast deserves a P0 even if today's footprint is tiny:

> ### Gap 6 (P0 by reversal cost) — Promise model is invoice-level only
>
> The cost of fixing this is approximately zero today (synthetic data only) and unbounded later (every existing promise becomes ambiguous).

Define the scale before you start rating. The session-history record shows this was a reactive recalibration the first time — the adversarial reviewer surfaced the contradictions before any P-axis definition had been written down. Defining it up front would have prevented the recalibration entirely.

### Pattern 3 — Depersonalize characterizations of past decisions; keep names for future work

A comparison doc characterizes choices that are already made. If those choices are attributed to a named contributor ("X got Y right" / "X didn't model Z"), the doc reads as a performance review even when individual sentences are positive. Strip the name from characterizations of existing work; keep it for owner-attribution of upcoming work.

**Before / after:**

| Before | After |
|---|---|
| "Andreas got the Parties cluster structurally right" | "The Parties cluster is structurally right in the initial platform work" |
| "Andreas chose JSONB metadata" | "The current implementation: JSONB `metadata` columns on `Invoice` and `InvoiceLineItem`" |
| "Andreas didn't yet model the cash side" | "The cash side is not yet modelled" |
| "Andreas himself flags this" | "The platform's own summary flags this" |
| Section heading: "Where Andreas got it right (and arguably better than the cluster-map sketch)" | Section heading: "Design decisions worth keeping" |

The rule is **passive voice (or impersonal subject) for state, named attribution for ownership of future work**. So this stays as written:

> Owner: Andreas. Trigger: before first real Client uploads.

That's not accusation — it's load-bearing attribution for what happens next.

The exact user correction from this session (session history): *"please talk about the current state of the work not as 'oversights' or any accusatory way. Instead word as not implemented. Maybe we shouldn't even articulate it as Andreas — he did do the work — but we could call it 'the initial platform work' or something like that."*

Also cut: editorial guidance about *how to read* the document — e.g., a section called "A note on framing for X" telling the reader to grade leniently. That belongs in a cover email, not in the document. Inside the doc it reads as throat-clearing and weakens load-bearing claims. (Session-history note: in this case the agent itself drafted such a section during the revision pass, intending to soften the tone — and the adversarial reviewer correctly flagged it as weakening the doc. Self-added "framing notes" are an anti-pattern; depersonalize the prose itself and trust the reader.)

### Meta-pattern A — Run analysis docs through an adversarial reviewer before finalizing

Spin up a subagent whose only job is to find load-bearing claims that don't survive contact with the source code. Give it read access to both the doc and the underlying repo. Ask it to cite specific files and line numbers for every disagreement.

In this session, the adversarial reviewer is what caught the schema-vs-runtime mismatch on Customer dedup — it read `app/services/ingestion/customer_account_matcher.rb` and reported that the file never queries `Customer::Organization`, which directly contradicted the doc's "solved" claim. Without that pass, the overreach would have shipped.

**What the reviewer catches reliably:**
- Factual overreaches (claim X is supported only by partial evidence).
- Internal contradictions (highest priority + "defer" recommendation in the same gap).
- Hand-wavy recommendations ("discuss with the team" with no default).
- Missing perspectives (whose viewpoint is conspicuously absent).

**What the reviewer does NOT catch reliably:**
- Tone, framing, and attribution. The depersonalization rule must be applied by the author. If you're reviewing your own first draft, do a separate read-through whose only goal is to find named-contributor attributions of past decisions, and rewrite them.

### Meta-pattern B — Every recommendation gets a default-if-undecided, an owner, and a trigger

"Discuss with the team" is epistemic hygiene, not a recommendation. A recommendation that ships if no one objects is load-bearing; an open question is not.

**Before:**

> We should discuss whether multi-invoice promises belong in the pilot.

**After:**

> Promote `PaymentPromise` to support a many-to-many with `Invoice` via a `PaymentPromiseAllocation` join model now, before any real data accumulates. Owner: Andreas. Trigger: before the first real Client uploads. Default if undecided: ship the join model — the cost is near-zero today and unbounded later.

### Meta-pattern C — Decision tables beat decision lists

A bulleted list of 11 open questions reads as "we haven't decided anything." A 6-row table with columns **Decision / Default if undecided / Owner / Trigger** reads as "we've decided; here's the audit trail." Move items off the table by stating their resolution inline below it:

> Decisions deliberately *not* on this list:
>
> - **Communications ingestion shape** — the default is "one CommunicationEvent per inbound email." Don't litigate unless a stakeholder objects.
> - **Dispute vs Task boundary** — the rule is "Disputes block payment; Tasks are work." Write it down, move on.

## Why This Matters

**Load-bearing docs need precise claims.** A comparison document gets used as input to roadmap decisions and pilot-scope conversations. An overreach ("Aethon-22x solved") propagates into planning and is much harder to retract than to get right the first time. The schema-vs-runtime split is the single most common source of analysis overreach in Rails-style codebases, where migrations are easy to read and service objects are not.

**Rating scales conflate axes silently.** When P0/P1/P2 is undefined, every reader fills in their own axis — and the author will too, inconsistently, across a long document. Anchoring to one explicit axis (and parenthesizing the other when it matters) is what makes the gap section actually scannable by a busy stakeholder.

**Accusatory framing breaks cross-team trust and weakens the doc's reception.** When the doc lands in front of the person whose work is being evaluated, the framing determines whether they engage with the substance or push back on the tone. Depersonalized framing keeps the substance load-bearing without spending trust. It also makes the doc more durable — six months later when the contributor has rotated off, the doc still reads as analysis rather than performance review.

**Editorial guidance inside the doc weakens the doc.** "A note on framing" sections, "how to read this," and "be charitable about X" passages signal that the author isn't confident the rest of the doc stands on its own. If the analysis is right, it doesn't need framing apology. If it's wrong, framing apology won't save it.

**Adversarial review is necessary but not sufficient.** Across three doc reviews in this session, the adversarial reviewer caught factual overreaches, logical contradictions in ratings, and architectural assumption gaps. It did not catch accusatory framing. Author discipline plus reviewer dispatch is the combined pattern; either alone is incomplete.

## When to Apply

- Writing a comparison document across two systems, two repos, or two teams' work.
- Writing a review of an in-progress prototype or platform you didn't build.
- Writing a roadmap or decision document that will be read by the people whose work is being evaluated.
- Writing an ontology / schema / architecture audit where the audit conclusions will drive subsequent epic scoping.
- Any analysis document whose claims need to survive contact with the source material it analyzes.

Apply **Pattern 1** (schema vs runtime) any time a claim of the form "this fixes X" or "X is solved" appears in a draft. Apply **Pattern 2** (single-axis ratings) any time you're using P0/P1/P2 or any tiered scale. Apply **Pattern 3** (depersonalize) any time a named contributor's work is the subject of the analysis. Apply **Meta-patterns A–C** to every analysis doc with load-bearing recommendations.

## Examples

### Example 1 — Schema permits vs runtime implements

The first draft contained:

> `Customer::Organization.normalized_name` is unique scoped to `operator_id`. Aethon-22x problem solved.

The adversarial reviewer disagreed, citing:

- `app/services/ingestion/customer_account_matcher.rb` and the rest of `app/services/ingestion/` never query `Customer::Organization`. The matcher looks for an existing `Customer::Account` (via `CustomerAccountAlias` or exact `display_name`/`account_number` match) and falls through to `needs_resolution` if nothing matches.
- The only code path that creates a `Customer::Organization` is the manual operator-resolution controller (`app/controllers/operator/import_records_controller.rb`), using `first_or_initialize` on `(operator, normalized_name)`.
- `normalized_name` is `squish.downcase` — "Aethon Energy LLC" and "Aethon Energy" produce different normalizations.

The revised doc split the claim:

- "Design decisions worth keeping" item 3 affirms the schema is right (with the `app/models/customer/organization.rb:22-23` citation) and adds a one-paragraph caveat pointing at Gap 0.
- A new "Gap 0 (P0) — Customer dedup is not yet implemented in the runtime" carries the load: cited service file, cited controller path, cited normalization shortfall, recommendation to add a `Customer::Organization` lookup step in `Ingestion::CustomerAccountMatcher` plus a `pg_trgm` fuzzy-match suggestion ≥0.85 in the manual-resolution UI, owner Andreas/Stephen, trigger "before first real client uploads," and an explicit default-if-undecided: *"leave as-is and accept that the pilot's dedup story is aspirational — that's not a non-decision, it's a no-fix."*

### Example 2 — Anchoring P-ratings to one axis

**Before** — implicit, conflated:

> Gap 2 (P0) — No credit ontology. (...) Recommendation: Defer until Phase 2 scoping.

The contradiction: a P0 gap whose own recommendation is "defer."

**After** — explicit axis at the top of the gaps section, plus a parenthetical that preserves the other axis when relevant:

> P-ratings below are based on **Week-1 pilot urgency** (does this need to be decided before real data starts flowing?), not on absolute size. A P0 gap blocks the pilot's stated deliverables; a P1 gap will hurt within 3 months if untreated; a P2 gap is real but can wait.
>
> ### Gap 2 (P2 for Week-1; P0 for ontology completeness) — No credit ontology

And, for the reverse case (small footprint, big cost-of-reversal):

> ### Gap 6 (P0 by reversal cost) — Promise model is invoice-level only
>
> The cost of fixing this is approximately zero today (synthetic data only) and unbounded later (every existing promise becomes ambiguous).

### Example 3 — Depersonalization, before / after

| Before | After |
|---|---|
| "Andreas got the Parties cluster structurally right" | "The Parties cluster is structurally right in the initial platform work" |
| "Andreas didn't yet model the cash side" | "The cash side is not yet modelled" |
| "Andreas chose JSONB metadata" | "The current implementation: JSONB `metadata` columns on `Invoice` and `InvoiceLineItem`" |
| "Andreas himself flags this as deferred" | "The platform's own summary flags this as deferred" |
| Heading: "Where Andreas got it right (and arguably better than the cluster-map sketch)" | Heading: "Design decisions worth keeping" |
| "For Andreas: grade these choices leniently — most of this is right." (How-to-use bullet) | *(cut entirely)* |
| Section: "A note on framing for Andreas" | *(cut entirely)* |

Kept as-is (correct ownership attribution for future work):

> Owner: Andreas. Trigger: before first real Client uploads.

### Example 4 — From "discuss with the team" to a real recommendation

**Before:**

> We should discuss with the team whether to model multi-invoice promises now or defer.

**After** (one row in the Decisions table):

| # | Decision | Default if undecided | Owner | Trigger |
|---|---|---|---|---|
| 6 | **Promise model granularity.** Multi-invoice promises now, or invoice-level through pilot? | Promote to many-to-many now via `PaymentPromiseAllocation`. The cost is near-zero today and unbounded later. | Andreas | Before any real promise data lands |

### Example 5 — Adversarial reviewer dispatch

The reviewer was an adversarial-document-reviewer subagent given two inputs: the draft comparison doc, and read access to `/Users/stephenparslow/Sites/cashline-platform`. Its instruction was to find load-bearing claims that don't survive contact with the source code, and to cite specific files and line numbers for every disagreement. It returned ~8 findings; the load-bearing one was the schema-vs-runtime Customer dedup mismatch (cited `app/services/ingestion/customer_account_matcher.rb` and `app/controllers/operator/import_records_controller.rb`), which became Gap 0 in the revised doc. It also flagged a "note on framing" section as weakening the doc and several recommendations as ending in "discuss" rather than a default — both of which drove the revision pattern in Pattern 3 and Meta-pattern B above.

It did **not** flag the accusatory framing of past decisions ("Andreas got X right", "Andreas chose Y"). That feedback came directly from the user mid-revision (session history). Author discipline owns the framing axis; the adversarial reviewer owns the factual/logical axis.

## Related

- `docs/method/cashline-platform-ontology-comparison.md` — the document this learning was extracted from; the final version models all the patterns above (P-rating scale defined at the top of "Gaps and risks"; six-row decisions table with Default / Owner / Trigger columns; "Decisions deliberately not on this list" section).
- `docs/method/sailfin-cluster-map.md` — the paired baseline-side document the comparison was written against; established the depersonalized framing convention the comparison doc had to adopt.
- `docs/method/manual-mapping-stopgap.md` — adjacent workflow doc in the same project / authorial voice.
