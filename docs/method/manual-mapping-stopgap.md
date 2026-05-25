# Manual mapping stopgap (pre-Phase-3 workflow)

The Phase 3 mapping workbench (interactive ontology-mapping UI + FIBO suggestions + Turtle export) is deferred to a separate plan. This document covers the **stopgap workflow** the plan calls out: use the Phase 1/2 UI we have today, plus a spreadsheet and a text editor, to author the first draft of the cashline ontology.

The intent of this workflow is to surface what the workbench actually needs to do before we commit to its design. Treat anything that feels painful here as a Phase 3 requirement.

## Prerequisites

- A completed Sailfin-scope extraction run (`bin/rails runs:rebuild_db` or trigger via `/runs/new` with the **Sailfin scope** preset).
- Profile data populated — check `/runs/<id>` and confirm the progress strip reads "Profiling complete" (all green).
- An empty `docs/mapping/` directory or external location for your draft Turtle files.

## The walkthrough

### Step 1 — Scope the work

Open `/objects?run=<id>`. Use the filter chips above the table to narrow to what you're mapping today:

- Click the **`sfsrm (N)`** namespace chip to focus on the Sailfin AR managed package — this is the core ontology surface.
- Click **`Custom only`** if you also want cashline's own custom objects (they sit in the standard namespace and won't show under `sfsrm`).
- Click **`Has Financial`** or **`Has PII`** to surface objects carrying sensitive data; these often have the most domain-meaningful fields.
- Click **`≥ 10`** under "Min fields" to skip thin lookup/junction objects you won't map directly.

The chip URLs are bookmarkable. Save a few combinations for the team.

### Step 2 — Take the CSV in your back pocket

Hit **Download CSV** in the top-right. You get one row per field with 37 columns of metadata + profile stats and three empty columns at the end for your mapping work:

| Column | Purpose |
|---|---|
| `target_iri` | Your proposed mapping (e.g., `fibo-fnd-acc-cur:Invoice`) |
| `confidence` | `high` / `medium` / `low` — your conviction about the mapping |
| `notes` | Anything ambiguous: polymorphism, dual semantics, deprecated field, etc. |

Open it in a spreadsheet (Numbers, Google Sheets, Excel) and fill those three columns as you go.

For namespace prefixes, the working list is in [`docs/brainstorms/2026-05-23-sailfin-extraction-and-ontology-requirements.md`](../brainstorms/2026-05-23-sailfin-extraction-and-ontology-requirements.md) (FIBO modules, schema.org). Keep that doc open in a side tab.

### Step 3 — Walk objects in dependency order

Pick objects in roughly the order their references flow:

1. **Reference targets first** — `Account`, `Contact`, `User`, anything that other objects reference. These tend to be your domain anchors.
2. **Then the entities** — `sfsrm__Invoice__c`, `sfsrm__Payment__c`, etc.
3. **Then the junctions** — `sfsrm__Invoice_Line__c`, association objects, etc.

Use the **Hub / orphan report** (`/reports/hub_orphan?run=<id>`) to identify the highly-connected objects — they're the ones worth mapping first.

For each object:

- Click the chevron in the index to expand its fields inline, OR click into the standalone page for the full layout (relationships + formula sections too).
- **Sort the fields table by Null % ascending** to surface populated columns. Anything > 99% null in a real production run is dead data — typically safe to skip mapping unless the field's existence itself is structurally meaningful.
- **Sort by Distinct descending** to find key candidates. The `Id` field tops the list (per-row unique); `Name` is next for most objects. Fields with high cardinality that aren't the Id are usually meaningful — natural keys, codes, external system IDs.
- **Sort by Refs descending** to find FK fields — these become object properties in your Turtle.

### Step 4 — Per field: click the chevron, decide

The per-field detail panel (click any field's chevron, or visit `/objects/<api>/fields/<name>`) is what you'll look at most. It shows:

- **Top values** with a bar chart — tells you the dominant cases (e.g., a `Status__c` field with 95% "Active" is structurally different from one evenly split across 10 values).
- **Picklist values** — the full enum. Map these to a SKOS ConceptScheme or an OWL class hierarchy.
- **Distribution stats** — for numerics, the p50/p95 tells you the typical range and tail. For dates, min/max tells you historical window.
- **Sensitivity classification rationale** — shows which signals tagged the field as PII/financial. Useful for deciding whether a field maps to a privacy-relevant class.
- **Reference target** — for reference fields, links the target sobject. The target's mapping is your range.
- **Formula** — if the field is calculated, the formula tells you its semantic dependency. Map to a derived property if the formula is stable.

Common decision matrix:

| Profile signal | Likely Turtle interpretation |
|---|---|
| `Id` field, high cardinality, never null | Use as the URI minting key |
| `Name` field, high cardinality, low null rate | `rdfs:label` |
| `*__c` boolean with even split | Probably a status / classification — map to a class subtype |
| Picklist with 2-50 values, low null rate | SKOS concept scheme |
| Reference to Account/Contact/User | Object property — range = target's class |
| `*_Date__c` or `Date_*__c` | Datatype property, `xsd:dateTime` |
| Currency / Number with sensitivity=financial | Datatype property, `fibo-fnd-acc:hasMonetaryAmount` |
| Field with > 99% null in a real run | Likely deprecated; flag for the Sailfin team before mapping |

### Step 5 — Draft Turtle in a text editor

Open a fresh `.ttl` file. The standard prefix preamble:

```turtle
@prefix rdf:     <http://www.w3.org/1999/02/22-rdf-syntax-ns#> .
@prefix rdfs:    <http://www.w3.org/2000/01/rdf-schema#> .
@prefix owl:     <http://www.w3.org/2002/07/owl#> .
@prefix xsd:     <http://www.w3.org/2001/XMLSchema#> .
@prefix skos:    <http://www.w3.org/2004/02/skos/core#> .
@prefix schema:  <https://schema.org/> .
@prefix fibo-fbc-fct-cli: <https://spec.edmcouncil.org/fibo/ontology/FBC/FunctionalEntities/Client/> .
@prefix fibo-fbc-pas-pp:  <https://spec.edmcouncil.org/fibo/ontology/FBC/ProductsAndServices/PaymentsAndPayables/> .
@prefix fibo-fnd-acc-cur: <https://spec.edmcouncil.org/fibo/ontology/FND/Accounting/CurrencyAmount/> .
@prefix cashline:         <https://cashline.tech/ontology/> .

cashline:Invoice
  a owl:Class ;
  rdfs:label "Invoice" ;
  rdfs:comment "Mapped from sfsrm__Invoice__c in the cashline-sf org" ;
  rdfs:subClassOf fibo-fnd-acc-cur:MonetaryAmount .  # tentative — verify

cashline:invoiceNumber
  a owl:DatatypeProperty ;
  rdfs:domain cashline:Invoice ;
  rdfs:range xsd:string ;
  rdfs:label "invoice number" .
```

Cross-reference with your spreadsheet annotations as you go. **Validate as you write** — the `turtle` Ruby gem (or any Apache Jena `riot` install) can lint:

```bash
gem install rdf-turtle
ruby -r rdf/turtle -e "RDF::Turtle::Reader.open('cashline-draft.ttl') { |r| r.each { |s| } }; puts 'valid'"
```

### Step 6 — Capture friction for Phase 3

As you work, keep a third file (`docs/mapping/phase3-requirements.md` or a sticky note) listing every moment of friction. Examples:

- "Wanted to filter fields by data_type but couldn't"
- "Wished for one-click mapping suggestion from the field detail page"
- "Need a way to mark a field as 'intentionally skipped'"

These notes are the Phase 3 plan's input.

## Tips & gotchas

- **Profile data may be stale.** The profile stats reflect the org state at extraction time. If Sailfin's been updated heavily since, re-extract before relying on null rates / top values for decisions.
- **Custom objects in the standard namespace.** cashline's own `Brand__c`, `Business_Entity__c`, etc. live alongside Salesforce standards (no `sfsrm__` prefix). The "Custom only" filter is your friend here.
- **`unknown_sensitivity` is fail-closed.** If a field is tagged `unknown_sensitivity`, that means the classifier wasn't confident and the field is treated as restricted until you (or the next extraction's classifier improvements) resolve it.
- **Polymorphic references.** `Task.WhatId` and similar fields reference multiple types. The CSV's `field_reference_target` column will show them comma-separated with `(polymorphic)`. These often map to a class hierarchy rather than a single class.
- **Don't map deprecated fields.** If a field has high null rate AND no recent record activity (check the `max_date` column in CSV for date fields), confirm with the Sailfin team before investing time mapping it.

## Validation before handoff

When you think a Turtle file is done:

1. **Parse it** with the rdf-turtle gem or `riot --validate`. Syntactic errors are non-negotiable blockers.
2. **Round-trip it** through `riot --output=N-Triples` and back — should be idempotent.
3. **Check coverage** — every sobject in your CSV that should be mapped has at least one Turtle declaration. Use a quick grep to find gaps.
4. **Diff against a previous draft** if you're iterating, so reviewers can see exactly what's new.

## When the Phase 3 plan should be authored

Per the original plan's deferral terms: the Phase 3 plan is authored once **at least one designer has walked one full Sailfin object end-to-end** through this stopgap. The friction notes from Step 6 become the Phase 3 plan's "Implementation-Time Unknowns" section.

If you find yourself doing the stopgap for more than a week without writing the Phase 3 plan, you're paying the manual-workflow tax for too long — bump Phase 3 up the priority list.
