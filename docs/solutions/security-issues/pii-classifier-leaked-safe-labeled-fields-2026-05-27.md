---
title: PII sensitivity classifier labeled bank-account and identity fields "safe", leaking customer data into a non-sensitive run
date: 2026-05-27
category: security-issues
module: salesforce_extraction
problem_type: security_issue
component: service_object
symptoms:
  - Fields ABA__c, IBAN__c, Bank_Account_No__c, Routing_No__c, and SSN/EIN fields classified as "safe"
  - Credential fields (AWSSecretKey, Archival_Password) and Contact.FirstName/LastName classified as "safe"
  - Profiler collected top_values and sample_values for these fields, leaking real customer names and bank-account data
  - Leak occurred in a run executed with include_sensitive=false
  - Regex boundary anchors silently failed across underscores in Salesforce API names (\bein\b never matched EIN_or_...)
root_cause: logic_error
resolution_type: code_fix
severity: critical
rails_version: 8.1.3
related_components:
  - background_job
  - database
  - testing_framework
tags:
  - pii
  - sensitivity-classifier
  - data-leak
  - salesforce
  - regex
  - camelcase-normalization
  - type-gate
  - data-remediation
---

# PII sensitivity classifier labeled bank-account and identity fields "safe", leaking customer data into a non-sensitive run

## Problem

The PII sensitivity classifier (`Ontology::SensitivityClassifier`) silently classified real PII fields — bank account numbers, routing/ABA numbers, IBANs, EIN/SSN, stored credentials, and discrete person names — as `safe`. Because `safe` fields are profiled, the extractor collected `top_values`/`sample_values` for them, leaking real customer names, bank names, and bank-account data into extraction run 9 even though it ran with `include_sensitive=false`.

## Symptoms

- Fields that are obviously PII came back `sensitivity: "safe"`: `ABA__c`, `IBAN__c`, `Bank_Account_No__c`, `Routing_No__c`, `sfsrm__EIN_or_Social_Security_Numbre_s__c`, `sfsrm__Archival_Password__c`, `sfsrm__AWSSecretKey__c`, `Contact.FirstName`, `Contact.LastName`.
- A run executed with `include_sensitive=false` nonetheless had populated `field_profiles.top_values` / `sample_values` containing real names, bank names, and account data.
- Discovered during a multi-agent data review of extraction run 9 — not by a failing test, because no test exercised camelCase names or banking/credential vocabulary.
- Person-name leakage was inconsistent: the compound `Name` field (which has `nameField=true`) was caught, but the discrete `FirstName`/`LastName` (which have `nameField=false` in real Salesforce describes) were not.

## What Didn't Work

- **Naively adding `\bein\b|\baba\b|\biban\b|...` word-boundary alternations.** Ruby's `\b` treats `_` as a word character, so the boundary never exists between a letter and an underscore. `\bein\b` does not match inside `EIN_or_Social_Security_Numbre_s__c`, and `\baba\b` does not match inside `ABA__c`. The boundary anchors silently fail across the underscores that pervade Salesforce API names, so the field still falls through to `safe`.
- **Naively adding bare `password|secret|token` to the name pattern.** This flags roughly a dozen Salesforce metadata false positives that contain those substrings but hold no credential value: permission booleans like `PermissionsManagePasswordPolicies`, datetime metadata like `LastPasswordChangeDate`, and reference IDs like `HeadlessForgotPasswordTemplateId`. A name match alone is wrong here; the credential check has to be gated on the field's value type.
- **Fixing only the classifier code.** The classifier governs *future* profiling, but the already-leaked `top_values`/`sample_values` from run 9 remained in `field_profiles`. The code change does not retroactively scrub data that was emitted under the wrong label.
- **Scrubbing with `update_all(top_values: "[]")`.** An early version of the scrub wrote the *string* `"[]"` into a JSONB column instead of an empty array, leaving malformed scalar data. The columns are JSONB and need a real empty array.

> Note: the originating review findings ([`docs/method/reviews/00-synthesis.md`](../../method/reviews/00-synthesis.md) P0.1 and [`05-general-data-analyst.md`](../../method/reviews/05-general-data-analyst.md) headline #2) proposed a **one-line regex extension** as the fix. That one-liner would still carry the `\b`/underscore boundary weakness — it would not match `sfsrm__Bank_Account_No__c`. The shipped fix below supersedes that suggestion; don't copy the weaker regex from the review artifacts.

## Solution

**The regex — before and after.** Original:

```ruby
PII_NAME_PATTERN = /email|phone|ssn|tax_id|dob|birth|first_name|last_name|address|postal|zip/i
```

Current (`app/services/ontology/sensitivity_classifier.rb`):

```ruby
PII_NAME_PATTERN = /
  email | phone |
  ssn | (?<![a-z])ein(?![a-z]) | social_?security | tax_?id |
  dob | birth |
  (?<![a-z])first_?name(?![a-z]) | (?<![a-z])last_?name(?![a-z]) |
  address | postal | zip |
  (?<![a-z])aba(?![a-z]) | (?<![a-z])iban(?![a-z]) | (?<![a-z])swift(?![a-z]) |
  routing | bank_?ac(c?t|count)
/xi
```

This adds banking/identity vocabulary (`ein`, `social_security`, `aba`, `iban`, `swift`, `routing`, `bank_account`), replaces the failed `\b` reliance with `(?<![a-z])...(?![a-z])` letter-boundary lookarounds for short tokens, and uses `_?` so a token matches whether or not an underscore sits at the boundary (so snake_case and post-normalization camelCase both match).

**The camelCase normalize helper** — inserts underscores at camelCase boundaries before matching, so `FirstName`, `first_name`, and `ABANumber__c` all normalize to the same underscore-delimited shape:

```ruby
def normalize_camel_case(name)
  name.gsub(/([a-z\d])([A-Z])/, '\1_\2')
      .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
end
```

Applied at the start of the name check:

```ruby
def pii_by_name_pattern?(field, signals)
  raw = field["name"].to_s
  name = normalize_camel_case(raw)

  if name.match?(PII_NAME_PATTERN)
    signals << "name_pattern:pii:#{raw}"
    return true
  end

  if name.match?(PII_CREDENTIAL_NAME_PATTERN) && CREDENTIAL_VALUE_TYPES.include?(field["type"].to_s.downcase)
    signals << "name_pattern:credential:#{raw}"
    return true
  end

  false
end
```

**The type-gated credential pattern** — a separate constant that only fires when the field's type is string-like, so booleans/datetimes/references with credential-sounding names stay `safe`:

```ruby
PII_CREDENTIAL_NAME_PATTERN = /password|secret|access_?token|refresh_?token|auth_?token|api_?key/i
CREDENTIAL_VALUE_TYPES = %w[string textarea encryptedstring].freeze
```

**The data-scrub script** (`script/reclassify_sensitivity.rb`) — re-classifies every `sfield` from its stored `raw_describe`, updates `sensitivity` + `sensitivity_signals`, and scrubs profiles for fields that flipped from `safe` to non-safe, writing real empty JSONB arrays:

```ruby
leaked_ids = flipped_to_pii + flipped_to_pii_and_financial

scrubbed = FieldProfile.where(sfield_id: leaked_ids.to_a)
                       .where("jsonb_array_length(top_values) > 0 OR jsonb_array_length(sample_values) > 0")
                       .update_all(top_values: [], sample_values: [])
```

The script ends with a verification gate that exits non-zero if any named-and-shamed field is still `safe`:

```ruby
named_and_shamed = %w[
  ABA__c IBAN__c Bank_Account_No__c Routing_No__c
  sfsrm__EIN_or_Social_Security_Numbre_s__c
  sfsrm__Archival_Password__c
  sfsrm__AWSSecretKey__c
  FirstName LastName
]
still_safe = Sfield.where(api_name: named_and_shamed, sensitivity: "safe")
                   .joins(:sobject).distinct.pluck("sobjects.api_name", :api_name)
if still_safe.any?
  warn "WARNING: the following named-and-shamed fields are still classified safe:"
  still_safe.each { |so, sf| warn "  #{so}.#{sf}" }
  exit 1
end
```

Result on run 9: 46 fields flipped `safe → pii`, 6 flipped `safe → financial`, 15 `field_profiles` rows scrubbed of leaked values.

## Why This Works

- **The `\b`-vs-underscore root cause.** In Ruby (Onigmo) regex, `_` is a word character (`\w`), so `\b` only fires at a letter↔non-word transition. Inside Salesforce API names like `ABA__c` or `EIN_or_Social_Security`, the tokens are surrounded by underscores, not non-word characters — so `\baba\b` and `\bein\b` have no boundary to anchor on and never match. Replacing `\b` with `(?<![a-z])...(?![a-z])` anchors on *letters specifically*: the lookarounds succeed when the neighbor is an underscore, digit, or string edge, but fail when it's another letter. That is what lets `aba` match in `ABA__c` while `swift` does not match in `Swiftness__c` and `ein` does not match in `Einstein`.
- **camelCase normalization.** Salesforce native fields are camelCase (`FirstName`, `ABANumber__c`); custom fields are snake_case (`Bank_Account_No__c`). Rather than maintain two pattern dialects, `normalize_camel_case` inserts underscores at lower→upper and acronym→word boundaries so every name is reduced to a single underscore-delimited shape before matching. `FirstName` → `First_Name`, `ABANumber__c` → `ABA_Number__c`. One pattern then covers both conventions.
- **Type-gate rationale.** "Has a credential-sounding name" and "stores a credential value" are different facts. Salesforce metadata is full of the former without the latter: `PermissionsManagePasswordPolicies` (boolean), `LastPasswordChangeDate` (datetime), `HeadlessForgotPasswordTemplateId` (reference). Gating the credential pattern on `CREDENTIAL_VALUE_TYPES` (`string`, `textarea`, `encryptedstring`) means only fields that can actually hold a secret value get flagged, eliminating the false positives while still catching `sfsrm__Archival_Password__c` and `sfsrm__AWSSecretKey__c` (both strings).
- **Why the scrub is part of the fix.** A misclassification bug has two artifacts: the buggy classifier *and* the data it already emitted. The classifier fix prevents new leaks; the scrub removes the leaked values from `field_profiles` for exactly the fields that flipped, writing JSONB `[]` (not the string `"[]"`) so the columns stay well-formed.

## Prevention

Tests now cover all three identifier shapes and the false-positive guards (`test/services/ontology/sensitivity_classifier_test.rb`, 27 tests passing):

- camelCase names via the pattern fallback (no `nameField`): `Contact.FirstName`, `Contact.LastName` → `pii`.
- snake_case banking customs: `ABA__c`, `IBAN__c`, `Bank_Account_No__c`, `Routing_No__c` → `pii`.
- embedded-number / namespaced variant: `sfcapp__ABANumber__c` → `pii`.
- the real typo'd field name: `sfsrm__EIN_or_Social_Security_Numbre_s__c` → `pii`.
- credential strings: `sfsrm__Archival_Password__c`, `sfsrm__AWSSecretKey__c` → `pii`.
- type-gate guards stay `safe`: `PermissionsManagePasswordPolicies` (boolean), `LastPasswordChangeDate` (datetime), `HeadlessForgotPasswordTemplateId` (reference).
- letter-boundary guards stay `safe`: `Swiftness__c` (`swift` followed by letters) and `PermissionsAccessEinsteinAnalytics` (`ein` mid-word).

General rules:

- **Never rely on `\b` near underscores.** Any name-pattern classifier operating over mixed camelCase/snake_case identifiers must normalize camelCase to underscores first and anchor short tokens with letter-boundary lookarounds (`(?<![a-z])...(?![a-z])`), not `\b`.
- **Separate "name suggests X" from "value is X" with a type gate.** When a name pattern would over-match metadata (credentials, IDs, permission flags), gate it on the field's value type so only value-bearing fields are flagged.
- **A misclassifier fix requires a data-scrub pass.** Changing the classifier only governs future output; data already emitted under the wrong label must be scrubbed too — and JSONB columns must be written with real empty arrays (`update_all(top_values: [], sample_values: [])`), never a stringified `"[]"`. Pair the scrub with a verification gate that exits non-zero if any known-bad field is still misclassified.
- **A fail-closed default is not a safety net if the classifier returns a confident wrong answer.** This classifier already defaults to `unknown_sensitivity` (treated as PII) on missing input — but that never triggered here, because the buggy regex returned a confident `safe`. Fail-closed protects against *absent* signal, not *wrong* signal; the name vocabulary itself must be correct.

## Related Issues

- [`docs/method/reviews/00-synthesis.md`](../../method/reviews/00-synthesis.md) — finding **P0.1** (the canonical originating finding; cites the buggy regex and both root-cause sub-bugs). *Analysis artifact, not a solutions-folder doc.*
- [`docs/method/reviews/05-general-data-analyst.md`](../../method/reviews/05-general-data-analyst.md) — headline #2 (missing banking vocabulary), headline #1 (live leakage into run 9), and the `Contact.Name = pii` / `FirstName`+`LastName = safe` discrete-parts discrepancy.
- [`docs/method/reviews/04-analytics-engineer.md`](../../method/reviews/04-analytics-engineer.md) — "Sensitivity flags" section (corroborating empirical source).
- [`docs/solutions/integration-issues/extraction-pipeline-missing-terminal-step-2026-05-23.md`](../integration-issues/extraction-pipeline-missing-terminal-step-2026-05-23.md) — sibling "green unit tests, broken real-data behavior" lesson: both bugs passed full unit suites because no test asserted end-to-end / real-data behavior.
- **Open follow-up (not yet tracked):** the B2B "client-confidential vs PII" gap — in B2B collections a customer's legal-entity name (e.g. company names in `Account.Name`) is confidential business intelligence even though it isn't personal PII. The classifier correctly leaves `Account.Name` as `safe`; whether the domain needs a separate `client_confidential` sensitivity tier is a policy decision, not a classifier bug. No GitHub issue exists yet (repo currently has none).
