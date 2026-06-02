# Sailfin → cashline-platform field map

Per-field source proposal for every column on snapshot #1's 32 cashline classes.

## Legend

| Shape | Meaning |
|---|---|
| **direct** | Sailfin value copies verbatim into the cashline column |
| **derived (cents)** | Sailfin currency (dollars/double) → cashline integer cents (× 100) |
| **derived (split)** | One Sailfin field → multiple cashline fields (e.g. `Name` → `first_name` + `last_name`) |
| **derived (other)** | Concat, parse, normalize, invert, or compose from multiple sources |
| **value_collapse** | Salesforce picklist string → cashline enum integer (per-value `MappingValueEntry` rows define the map) |
| **sync_reference** | Sailfin `Id`/lookup → cashline integer FK via `sailfin_*_id` crosswalk column at sync time |
| **net_new** | Cashline-only construct; no Sailfin origin |
| **operational** | Cashline lifecycle/internal (PKs, Rails timestamps, Devise fields, soft-delete flags). Sync writes its own values; not a mapping question. |
| **uncertain** | Best guess noted; needs further triage |

Annotations:
- ✓ = already committed as a `MappingEntry` on snapshot #1
- ⏳ = deferred pending crosswalk columns (see `sailfin-crosswalk-columns.md`)

---

## AR-core classes (real Sailfin origin)

### Customer::Organization — canonical customer identity (deduped across Brand pairings)

| Column | Shape | Sailfin source | Note |
|---|---|---|---|
| `id` | operational | — | PK |
| `canonical_name` | derived (other) | `Account.Name` | Pick canonical Name across the duplicate Account rows for the same legal entity (one Customer::Org spawns N Customer::Accounts) |
| `legal_name` | direct | `Account.Name`; fall back to `sfsrm__Credit_Application__c.sfsrm__Full_Legal_Business_Name__c` if present | Credit app full legal name is more authoritative when it exists |
| `normalized_name` | derived (other) | `Account.Name` | Lowercase + strip punctuation for dedup matching |
| `website` | direct | `Account.Website` | |
| `notes` | net_new | — | Cashline-side org notes; no Sailfin origin |
| `operator_id` | net_new | — | Cashline platform construct |
| `created_at`, `updated_at` | operational | — | |

### Customer::Account — AR link (one per customer × client pairing)

| Column | Shape | Sailfin source | Note |
|---|---|---|---|
| `id` | operational | — | |
| `account_number` ✓ | direct | `Account.AccountNumber` | committed |
| `display_name` | direct | `Account.Name` | What appears in collectors' UI |
| `customer_organization_id` | sync_reference | resolves from `Account.Id` via `Customer::Org.sailfin_account_id` crosswalk | The Customer::Org this account dedups into |
| `client_organization_id` | sync_reference | resolves from `Brand__c.Id` via `Client::Org.sailfin_brand_id` crosswalk | Account.OwnerId / Brand link |
| `customer_group_id`, `client_group_id` | sync_reference | derived via Org→Group | |
| `status` | value_collapse | `Account.Status__c` | Active/Inactive/On-hold picklist → enum |
| `submission_channel` | value_collapse | `Account.Ecommerce_System__c` (or `Account.Ecommerce_System2__c`) | Portal/email/EDI/manual → enum |
| `portal_name` | direct | `Account.Ecommerce_System__c` | The raw label, before enum collapse |
| `notes` | direct | `Account.Description` (standard SF Description field) | Free-form collections notes |
| `collection_notes` | derived (other) | `sfsrm__Collection_Detail__c.sfsrm__Notes__c` joined per Account, OR `Account.Description` | Aggregated collections journal; may merge multiple sources |
| `payment_terms_notes` | direct | `Account.Payment_Terms_Description__c` | |
| `check_run_schedule_notes` | uncertain | `Account.Check_Run_Schedule__c` if exists, else net_new | Sailfin-side schedule narrative for AP check runs |
| `created_at`, `updated_at` | operational | — | |

### Customer::Contact

| Column | Shape | Sailfin source | Note |
|---|---|---|---|
| `id` | operational | — | |
| `email` ✓ | direct | `Contact.Email` | committed |
| `first_name` ✓ | direct | `Contact.FirstName` | committed |
| `last_name` ✓ | direct | `Contact.LastName` | committed |
| `phone` ✓ | direct | `Contact.Phone` | committed |
| `title` ✓ | direct | `Contact.Title` | committed |
| `customer_account_id` ⏳ | sync_reference | `Contact.AccountId` → resolves via `Customer::Account.sailfin_account_id` crosswalk | Deferred pending crosswalk |
| `customer_organization_id` | sync_reference | derived from `customer_account_id` join | |
| `customer_group_id` | sync_reference | derived | |
| `role_label` | direct | `Contact.Customer_Group__c` (string) | If used for "AP clerk", "decision-maker", etc. |
| `notes` | direct | `Contact.Description` | |
| `created_at`, `updated_at` | operational | — | |

### Client::Organization — operators (the brand/billing entity, NOT the customer)

| Column | Shape | Sailfin source | Note |
|---|---|---|---|
| `id` | operational | — | |
| `name` | direct | `Brand__c.Name` | 0.98 LLM — **uncommitted, ready to commit** |
| `description` | direct | none clean | Brand__c has no Description; could derive from Brand_Manager__c + ERP_System__c, but **net_new** is more honest |
| `slug` | derived (other) | `Brand__c.Name` | Parameterize |
| `group_label` | uncertain | `Brand__c.Reporting_Client__c` (resolves to parent Brand's Name) | If group_label denotes the reporting parent; otherwise net_new |
| `operator_id` | net_new | — | Cashline platform construct |
| `created_at`, `updated_at` | operational | — | |

### Client::Contact — operator-side personnel

In Sailfin, operator-side people live in `User`, not `Contact`. `Brand__c.IT_Contact__c` is a free-text string, not a relationship. Cashline `Client::Contact` is best derived from the subset of Sailfin Users associated with each Brand, plus a few brand-level strings.

| Column | Shape | Sailfin source | Note |
|---|---|---|---|
| `id` | operational | — | |
| `first_name`, `last_name` | derived (split) | `User.FirstName`, `User.LastName` (for Users assigned to this brand) | Filter by brand membership |
| `email` | direct | `User.Email` | |
| `phone` | direct | `User.Phone` | |
| `title` | direct | `User.Title` | |
| `role_label` | direct | `User.UserRole.Name` (relationship) | Or net_new |
| `client_organization_id` | sync_reference | derived from User → Brand mapping | |
| `client_group_id` | sync_reference | derived | |
| `user_id` | sync_reference | `User.Id` via crosswalk | The cashline-internal User row |
| `notes` | net_new | — | |
| `created_at`, `updated_at` | operational | — | |

### Client::Group — sub-grouping of Brands under a reporting parent

| Column | Shape | Sailfin source | Note |
|---|---|---|---|
| `id` | operational | — | |
| `name` | direct | `Brand__c.Reporting_Client__c` → resolves to that parent Brand's `Name` | A Group is the reporting parent of N child Brands |
| `description` | net_new | — | |
| `slug` | derived (other) | derived from `name` | |
| `client_organization_id` | sync_reference | derived | The reporting-parent Brand becomes the Client::Org for this Group |
| `created_at`, `updated_at` | operational | — | |

### Client::Membership — User ↔ Group join

| Column | Shape | Sailfin source | Note |
|---|---|---|---|
| `id` | operational | — | |
| `user_id` | sync_reference | `User.Id` | |
| `client_group_id`, `client_organization_id` | sync_reference | derived from User's brand assignments | |
| `member_type` | value_collapse | `User.UserType` or `User.UserRole.Name` | Internal/External/Customer Portal |
| `role` | value_collapse | `User.UserRole.Name` | |
| `status` | value_collapse | `User.IsActive` | active/blocked → enum |
| `created_at`, `updated_at` | operational | — | |

### Invoice — 43 columns, the AR core

| Column | Shape | Sailfin source | Note |
|---|---|---|---|
| `id` | operational | — | |
| `invoice_number` ✓ | direct | `sfsrm__Transaction__c.Invoice_Number__c` | committed |
| `area` ✓ | direct | `sfsrm__Transaction__c.Area__c` | committed |
| `division` ✓ | direct | `sfsrm__Transaction__c.DIVISION__c` | committed |
| `region` ✓ | direct | `Account.Region__c` | committed (Account-denormalized) |
| `currency` ✓ | direct | `sfsrm__Transaction__c.CurrencyIsoCode` | committed |
| `issue_date` ✓ | direct | `sfsrm__Transaction__c.sfsrm__Create_Date__c` | committed |
| `due_date` ✓ | direct | `sfsrm__Transaction__c.sfsrm__Due_Date__c` | committed |
| `payment_terms_code` ✓ | direct | `sfsrm__Transaction__c.sfsrm__Payment_Terms__c` | committed |
| `payment_terms_days` ✓ | direct | `sfsrm__Transaction__c.Terms__c` | committed |
| `payment_terms_description` | direct | `Account.Payment_Terms_Description__c` | Account-denormalized |
| `purchase_order_number` ✓ | direct | `sfsrm__Transaction__c.Order__c` | committed |
| `ticket_number` ✓ | direct | `sfsrm__Transaction__c.Field_Ticket__c` | committed |
| `original_amount_cents` ✓ | derived (cents) | `sfsrm__Transaction__c.Original_Amount__c × 100` | committed |
| `total_cents` ✓ | derived (cents) | `SalesforceInvoice.TotalAmount × 100` | committed |
| `subtotal_cents` | derived (cents) | `sfsrm__Transaction__c.sfsrm__Subtotal__c × 100` | |
| `tax_cents` | derived (cents) | `sfsrm__Transaction__c.Tax_Amount__c × 100` | |
| `balance_due_cents` | derived (cents) | `SalesforceInvoice.Balance × 100` (or `sfsrm__Transaction__c.Balance_Due_Without_Tax__c × 100`) | |
| `status` | value_collapse | `SalesforceInvoice.SalesforceInvoiceStatus` (or derived from `sfsrm__Transaction__c.Status__c`) | Open/Paid/Overdue/Disputed → enum |
| `job_number` | direct | `sfsrm__Transaction__c.JOB_Number__c` | |
| `location_name` | direct | `sfsrm__Transaction__c.Location_Name__c` | |
| `well_site` | direct | `sfsrm__Transaction__c.Well_Name__c` | |
| `repair_order_number` | uncertain | `sfsrm__Transaction__c.Repair_Order__c` if exists; else net_new | |
| `description` | direct | `sfsrm__Transaction__c.Action_Notes__c` (latest narrative) | |
| `customer_account_id` ⏳ | sync_reference | `sfsrm__Transaction__c.sfsrm__Account__c` → `Customer::Account.sailfin_account_id` | Deferred |
| `customer_group_id`, `client_group_id` | sync_reference | derived from Account | |
| `source_account_number` | direct | `Account.AccountNumber` (denormalized for sync fidelity) | |
| `source_customer_number` | direct | `sfsrm__Transaction__c.JDE_Customer__c` | |
| `source_document_type` | direct | `sfsrm__Transaction__c.Document_Type_Description__c` | |
| `source_transaction_id` | direct | `sfsrm__Transaction__c.sfsrm__Transaction_Key__c` | |
| `source_external_id` | direct | `sfsrm__Transaction__c.Id` | The Salesforce 18-char Id (= future `sailfin_transaction_id`) |
| `source_system` | derived (other) | literal `"sailfin"` written by sync | |
| `source_tenant_key` | net_new | — | Cashline multi-tenancy tag |
| `source_updated_at` | direct | `sfsrm__Transaction__c.LastModifiedDate` | |
| `last_synced_at` | operational | — | Set by sync resolver |
| `metadata` | net_new (sink) | — | jsonb bucket for non-promoted fields (Open_Invoices__c snapshot, ageing fields, etc.) |
| `approved_at`, `submitted_at`, `paid_at` | operational | — | Set by cashline submission/payment lifecycle |
| `created_by_user_id` | sync_reference | `sfsrm__Transaction__c.CreatedById` | |
| `created_at`, `updated_at` | operational | — | |

### InvoiceLineItem — `sfsrm__Line_Item__c` is the source

| Column | Shape | Sailfin source | Note |
|---|---|---|---|
| `id` | operational | — | |
| `invoice_id` ⏳ | sync_reference | `sfsrm__Line_Item__c.sfsrm__Transaction__c` → `Invoice.sailfin_transaction_id` | Deferred |
| `quantity` | direct | `sfsrm__Line_Item__c.sfsrm__Quantity__c` | |
| `unit_price_cents` | derived (cents) | `sfsrm__Line_Item__c.sfsrm__Unit_Price__c × 100` | |
| `amount_cents` | derived (cents) | `sfsrm__Line_Item__c.sfsrm__Line_Total__c × 100` | Computed in Sailfin, just × 100 to convert |
| `description` | direct | `sfsrm__Line_Item__c.sfsrm__Description__c` | |
| `item_code` | direct | `sfsrm__Line_Item__c.sfsrm__Item_Number__c` | |
| `line_number` | direct | `sfsrm__Line_Item__c.Name` | The standard SF Name field is the line number/identifier |
| `service_date` | direct | `sfsrm__Line_Item__c.sfsrm__Service_Date__c` | |
| `service_period_start`, `service_period_end` | net_new | — | Sailfin only stores a single service date |
| `service_code` | uncertain | `sfsrm__Line_Item__c.sfsrm__Flags__c` (if used for classification) | Probably net_new |
| `tax_code` | direct | `sfsrm__Transaction__c.Header_Tax_Code__c` (line items inherit from transaction) | Note: line items don't carry their own tax code |
| `unit_of_measure` | net_new | — | sfsrm__Line_Item__c has no UOM field; could derive from `Product2.QuantityUnitOfMeasure` via product lookup but Sailfin doesn't FK to Product2 |
| `source_line_id` | direct | `sfsrm__Line_Item__c.sfsrm__Line_Key__c` | |
| `position` | derived (other) | row index within transaction (sort by Name or CreatedDate) | |
| `metadata` | net_new (sink) | — | Discount, disputed amount, list price, notes — bucket |
| `created_at`, `updated_at` | operational | — | |

### InvoiceDispute — `sfsrm__Dispute__c` is the source

| Column | Shape | Sailfin source | Note |
|---|---|---|---|
| `id` | operational | — | |
| `invoice_id` ⏳ | sync_reference | `sfsrm__Dispute__c.sfsrm__Transaction__c` → `Invoice.sailfin_transaction_id` | Deferred |
| `customer_account_id` ⏳ | sync_reference | `sfsrm__Dispute__c.sfsrm__Account__c` → `Customer::Account.sailfin_account_id` | Deferred |
| `status` ✓ | value_collapse | `sfsrm__Dispute__c.sfsrm__Status__c` | committed |
| `subtype` | value_collapse | `sfsrm__Dispute__c.sfsrm__Sub_Type__c` (better than Reason_Code) | picklist → enum |
| `summary` | direct | `sfsrm__Dispute__c.sfsrm__Notes__c` | |
| `resolution_summary` | direct | `sfsrm__Dispute__c.sfsrm__Latest_Note__c` (or `sfsrm__Resolution_Code__c` if just a code) | |
| `opened_at` | direct | `sfsrm__Dispute__c.sfsrm__Created_Date__c` (date) — or `CreatedDate` (datetime) | Prefer the explicit business date when populated |
| `resolved_at` | direct | `sfsrm__Dispute__c.sfsrm__Dispute_Close_DateTime__c` (datetime) | |
| `opened_by_user_id` | sync_reference | `sfsrm__Dispute__c.CreatedById` → `User.sailfin_user_id` | |
| `resolved_by_user_id` | sync_reference | `sfsrm__Dispute__c.sfsrm__Owner__c` or `LastModifiedById` | |
| `client_visible` | derived (other) | inverse of `sfsrm__Dispute__c.Dispute_Created_by_CE__c`, OR net_new | If CE-created, visibility likely differs |
| `waiting_on_party` | value_collapse | derived from `sfsrm__Status__c` (status-conditional) | Or net_new |
| `client_group_id` | sync_reference | derived | |
| `created_at`, `updated_at` | operational | — | |

### InvoiceAttachment

| Column | Shape | Sailfin source | Note |
|---|---|---|---|
| `id` | operational | — | |
| `invoice_id` ⏳ | sync_reference | `Attachment.ParentId` or `ContentDocumentLink.LinkedEntityId` → `Invoice.sailfin_transaction_id` | Deferred |
| `description` | direct | `Attachment.Description` or `ContentVersion.Title` | |
| `source` | derived (other) | literal `"salesforce-attachment"` or `"salesforce-content"` based on origin object | |
| `uploaded_by_user_id` | sync_reference | `Attachment.CreatedById` / `ContentVersion.CreatedById` | |
| `created_at`, `updated_at` | operational | — | |

### PaymentPromise — dual origin (`sfsrm__Transaction__c.sfsrm__Promised_Amount__c` or `sfsrm__Payment__c`)

| Column | Shape | Sailfin source | Note |
|---|---|---|---|
| `id` | operational | — | |
| `promised_amount_cents` ✓ | derived (cents) | `sfsrm__Transaction__c.sfsrm__Promised_Amount__c × 100` | committed |
| `promise_date` | direct | `sfsrm__Transaction__c.sfsrm__Promise_Date__c` | |
| `currency` | direct | `sfsrm__Transaction__c.CurrencyIsoCode` (or `sfsrm__Payment__c.CurrencyIsoCode`) | |
| `payment_method` | value_collapse | `sfsrm__Payment__c.sfsrm__Payment_Type__c` | picklist → enum (when from Payment) |
| `cleared_at` | direct | `sfsrm__Payment__c.sfsrm__Payment_Date__c` | When promise is realized as payment |
| `status` | derived (other) | computed from presence of `cleared_at` vs `promise_date` vs current date | |
| `source` | derived (other) | literal `"transaction-promise"` or `"payment"` based on origin row | |
| `notes` | direct | `sfsrm__Transaction__c.sfsrm__Latest_Note_Title__c` (or `sfsrm__Payment__c.sfsrm__Memo__c` if present) | |
| `invoice_id` ⏳ | sync_reference | `sfsrm__Transaction__c.Id` (this transaction is the invoice it promises against) | Deferred |
| `customer_account_id` ⏳ | sync_reference | derived from invoice | Deferred |
| `client_group_id` | sync_reference | derived | |
| `created_by_user_id` | sync_reference | `CreatedById` of origin row | |
| `resolved_at`, `resolved_by_user_id` | operational | — | cashline-side resolution lifecycle |
| `created_at`, `updated_at` | operational | — | |

### User (cashline-internal — operator personnel)

| Column | Shape | Sailfin source | Note |
|---|---|---|---|
| `id` | operational | — | |
| `email` ✓ | direct | `User.Email` | committed |
| `first_name` ✓ | direct | `User.FirstName` | committed |
| `last_name` | direct | `User.LastName` | **uncommitted, ready to commit** |
| `blocked` | derived (other) | `!User.IsActive` (boolean inversion) | |
| `theme_preference` | net_new | — | Cashline UI pref, not Salesforce theme |
| `invitation_token`, `invitation_created_at`, `invitation_sent_at`, `invitation_accepted_at`, `invitation_limit`, `invited_by_id`, `invited_by_type` | net_new | — | Devise invitation flow |
| `encrypted_password`, `reset_password_token`, `reset_password_sent_at`, `remember_created_at` | operational | — | Devise auth internals |
| `created_at`, `updated_at` | operational | — | |

### CommunicationEvent — `EmailMessage` + call-type `Task` + `Event` (logged-call)

| Column | Shape | Sailfin source | Note |
|---|---|---|---|
| `id` | operational | — | |
| `channel` | value_collapse | derived from origin object type (`EmailMessage`→email, `Task`→call/note, `Event`→meeting) | |
| `direction` ✓ | value_collapse | `Task.CallType` (also from `EmailMessage.Incoming` boolean) | committed (Task source) |
| `summary` | direct | `EmailMessage.Subject` / `Task.Subject` / `Event.Subject` (varies by origin) | |
| `body` | direct | `EmailMessage.TextBody` / `Task.Description` / `Event.Description` | |
| `occurred_at` | direct | `EmailMessage.MessageDate` / `Task.ActivityDate` / `Event.ActivityDateTime` | |
| `contact_email` | direct | `EmailMessage.ToAddress` (or `FromAddress` for inbound) | |
| `contact_name` | direct | `EmailMessage.FromName` / `sfsrm__Transaction__c.Customer_Contact__c` | |
| `customer_account_id` ⏳ | sync_reference | `EmailMessage.sfsrm__Account__c` / `Task.WhatId` / `Event.WhatId` → `Customer::Account.sailfin_account_id` | Deferred |
| `customer_contact_id` ⏳ | sync_reference | `EmailMessage.RelatedToId` / `Task.WhoId` / `Event.WhoId` → `Customer::Contact.sailfin_contact_id` | Deferred |
| `invoice_id`, `invoice_dispute_id`, `payment_promise_id`, `operational_task_id` ⏳ | sync_reference | crosswalk lookup on `WhatId` polymorphic ref | Deferred |
| `created_by_user_id` | sync_reference | `CreatedById` of origin row | |
| `client_group_id` | sync_reference | derived | |
| `visibility` | net_new | — | Cashline-side visibility flag |
| `created_at`, `updated_at` | operational | — | |

### OperationalTask — non-call `Task` rows + `sfsrm__Collection_Detail__c`

| Column | Shape | Sailfin source | Note |
|---|---|---|---|
| `id` | operational | — | |
| `priority` ✓ | value_collapse | `Task.Priority` | committed |
| `title` | direct | `Task.Subject` | |
| `description` | direct | `Task.Description` | |
| `category` | value_collapse | `Task.Type` (excluding call types which route to CommunicationEvent) | |
| `status` | value_collapse | `Task.Status` | |
| `due_at` | direct | `Task.ActivityDate` | |
| `resolved_at` | direct | `Task.CompletedDateTime` | |
| `assigned_to_user_id` | sync_reference | `Task.OwnerId` → `User.sailfin_user_id` | |
| `created_by_user_id` | sync_reference | `Task.CreatedById` | |
| `customer_account_id` ⏳ | sync_reference | `Task.WhatId` when it's an Account | Deferred |
| `customer_contact_id` ⏳ | sync_reference | `Task.WhoId` when it's a Contact | Deferred |
| `customer_organization_id` | sync_reference | derived | |
| `invoice_id`, `invoice_dispute_id`, `payment_promise_id`, `communication_event_id` ⏳ | sync_reference | crosswalk on `WhatId` polymorphic ref | Deferred |
| `client_organization_id`, `client_group_id`, `operator_id` | sync_reference / net_new | derived from assignee context | |
| `visibility` | net_new | — | |
| `created_at`, `updated_at` | operational | — | |

---

## Cashline-only classes (no Sailfin origin)

These represent cashline-platform constructs that have no counterpart in Sailfin's data model. Every business field is **net_new**; only sync-related metadata (e.g., a source filename) might originate elsewhere.

### Operator

Platform-tier entity (the firm operating cashline for a brand). No Sailfin equivalent — Brand__c is the *Client* identity, Operator is one level above.

| Column | Shape | Note |
|---|---|---|
| `id`, `created_at`, `updated_at` | operational | |
| `name`, `description`, `slug`, `sector` | net_new | The LLM proposal `Account.Sector__c → Operator.sector` is a false positive — that's customer industry, not operator sector |

### OperatorMembership

| Column | Shape | Note |
|---|---|---|
| all columns | net_new / operational | Cashline platform RBAC join. The `UserLicense.Status` proposal is a false positive. |

### Customer::Group

| Column | Shape | Note |
|---|---|---|
| `name`, `description` | net_new | Cashline-side sub-grouping of Customer::Orgs (e.g. parent companies). Sailfin has no equivalent. |
| `customer_organization_id` | sync_reference | derived |
| rest | operational | |

### Customer::AccountPortal — per-account portal credentials/notes

| Column | Shape | Sailfin source / note |
|---|---|---|
| `account_identifier` | direct (if portal is in Sailfin's Ecommerce system) | `Account.Account_ID_Text__c` |
| `portal_name` | derived (other) | `Account.Ecommerce_System__c` normalized |
| `status` | value_collapse | `Account.Status__c` |
| `customer_account_id` | sync_reference | |
| `login_url`, `metadata`, `name`, `notes` | net_new | Portal config data lives in cashline; Sailfin doesn't track logins |
| rest | operational | |

### ExternalPortalStatus — polled portal status events

All fields are cashline-side polling state. **net_new** across the board. The LLM proposal `Weekly_AR_Snapshot__c.ELS_Portal_Status__c → status_label` is a real signal but it's a polled snapshot, not a Sailfin record — cashline polls portals directly, not via Sailfin.

### InvoiceStatusEvent — cashline-side audit trail

Every state change to an Invoice generates one row. No Sailfin source — cashline's own state machine writes these. **net_new**.

The LLM proposals (`sfsrm__Transaction__c.Ticket_Ecommerce_Status__c → new_status`, `sfsrm__Latest_Note_Title__c → note`) are misdirected: those fields are denormalized current state on Transaction, not an event log. They feed Invoice.status (current), not InvoiceStatusEvent.

### InvoiceSubmission — cashline's portal-submission lifecycle

Tracks a cashline-mediated push of an invoice to an external portal. Some fields may carry Sailfin metadata, but the lifecycle itself is cashline-side.

| Column | Shape | Note |
|---|---|---|
| `source_system` ✓ | direct | `Account.Ecommerce_System__c` — committed |
| `external_reference` | direct | `sfsrm__Transaction__c.Reference__c` (portal-side invoice ID, if Sailfin tracks it) |
| `portal_name` | derived (other) | `Account.Ecommerce_System__c` normalized |
| all other business fields | net_new | Cashline tracks submission state; Sailfin doesn't |
| FK columns | sync_reference | |

### SubmissionArtifact, SubmissionRequirement

Cashline-only artifact/requirement model for portal submissions. **net_new** across the board.

### Ingestion::Connector, Ingestion::ImportBatch, Ingestion::ImportRecord, Ingestion::MappingTemplate, Ingestion::FieldMapping, Ingestion::ValidationIssue, Ingestion::ResolutionDecision, Ingestion::CustomerAccountAlias

Cashline's CSV-ingestion subsystem (Aging Reports, Open Invoices uploads). **Entirely net_new** — these power a parallel ingest path, not the Sailfin API sync.

A few apparent LLM matches (`sfsrm__Data_Load_Batch__c.sfsrm__Batch_Job_End_Time__c → ImportBatch.committed_at`, `sfsrm__Object_Configuration__c.CreatedById → Connector.created_by_user_id`) are false positives — those Sailfin objects are internal to Sailfin's own data-loader tooling, not a source for cashline's customer-facing ingest.

---

## Summary — counts by shape

(Approximate; uncertain rows are noted in-row.)

| Shape | ~count | Examples |
|---|---|---|
| direct | ~55 | Names, emails, dates, codes, descriptions |
| derived (cents) | 6 | All `*_cents` invoice/line/dispute amounts |
| derived (split) | ~2 | Client::Contact first/last from User.Name (only if User.FirstName/LastName are sparse) |
| derived (other) | ~12 | Slugs, normalized names, computed status, channel-from-origin |
| value_collapse | ~14 | Picklists → enums (status, priority, channel, direction, payment_method, dispute subtype) |
| sync_reference | ~50 | Every cashline `*_id` FK with a Sailfin origin |
| net_new | ~180 | Entire Ingestion::*, Operator/OperatorMembership, Submission*, ExternalPortalStatus, lifecycle/visibility fields on AR-core |
| operational | ~120 | PKs, Rails timestamps, Devise fields, sync timestamps |
| uncertain | ~10 | Flagged in-row |

---

## Reading this file

- **For Dre**: the `sync_reference` rows are the migration's payload — every one of them is a Sailfin lookup that needs the matching `sailfin_*_id` crosswalk column to land in cashline-platform. The companion doc `sailfin-crosswalk-columns.md` lists exactly which columns and on which tables.
- **For the sync resolver design**: the `derived (cents)` and `value_collapse` rows are where transformation code lives — currency × 100 helpers and per-picklist enum maps.
- **For the LLM adjudicator's next pass**: feed in the conventions above (Account=customer, Brand=client, currency=cents, picklist=enum, FK=sync_reference) so it stops proposing string-Id → integer-FK direct mappings.
- **Confidence**: ✓-marked rows are the validated baseline. Uncommitted-direct rows in this doc are the next-tier commit candidates — most can land as soon as we agree on the shape calls per class.
