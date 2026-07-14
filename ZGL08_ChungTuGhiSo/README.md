# ZGL08_ChungTuGhiSo - RAP List Report module

Generated from the FS `PTB_FS_FA_ZGL08_ChungTuGhiSo_v1.0.doc` (PTB_SAP_2026_TH_DA,
module FA, report ZGL08 "Chung tu ghi so" / GL journal entry line item report),
data source `I_GLAccountLineItem`.

**I do not have a live connection to any SAP system.** Everything in `src/`
is hand-written ABAP/CDS source meant to be pasted into ADT (Eclipse) as new
repository objects, then activated and adjusted there. It has **not** been
compiled or tested against a real system - treat the field-name assumptions
below as a first draft to verify, not as confirmed fact.

## Why a Custom Entity, not a plain CDS projection

The FS's core requirement (section 2.2) is: for every Journal Entry, split
its debit and credit line items and pair them into report rows, matching each
side up and allocating amounts between them. That's row-pairing / conditional
logic that a declarative CDS view can't express cleanly, so the data model is
a **RAP Custom Entity** with no persistence of its own - all data is produced
at query time by an ABAP class (`ZBP_GL08_CHUNGTUGHISO`) that reads
`I_GLAccountLineItem` and does the pairing in-memory.

## Objects in `src/`

| File | Repo object | Type | Purpose |
|---|---|---|---|
| `zc_gl08_chungtughiso.ddls.asddls` | `ZC_GL08_CHUNGTUGHISO` | Custom Entity (DDLS) | Data model - all 36 FS output fields + technical filter-only fields |
| `zc_gl08_chungtughiso_md.ddlx.asddlxs` | `ZC_GL08_CHUNGTUGHISO_MD` | Metadata Extension (DDLX) | `@UI.selectionField` (filter bar) + `@UI.lineItem` (table columns) + default sort |
| `zc_gl08_chungtughiso.bdef.asbdef` | `ZC_GL08_CHUNGTUGHISO` | Behavior Definition (BDEF) | Marks the entity read-only (`query;`), points to the query class |
| `zbp_gl08_chungtughiso.clas.abap` | `ZBP_GL08_CHUNGTUGHISO` | Class (CLAS) | `IF_RAP_QUERY_PROVIDER` implementation - reads `I_GLAccountLineItem`, applies TH1/TH2/TH3 pairing |
| `zbp_gl08_chungtughiso.clas.testclasses.abap` | (test include) | Class (CLAS, local test class) | ABAP Unit tests for the pairing algorithm, independent of the DB |
| `zui_gl08_chungtughiso.srvd.srvdsrv` | `ZUI_GL08_CHUNGTUGHISO` | Service Definition (SRVD) | Exposes the entity as `ChungTuGhiSo` |

Not generated (see "Manual steps" below): the OData V4 UI **Service Binding**
and the Fiori Elements **List Report app**. Both are normally created/wired
up interactively in ADT / the Fiori app generator rather than hand-written.

Suggested package: `ZPTB_FA` (placeholder - use whatever package/transport
your Basis team assigns for this project). All objects use the `Z` customer
namespace; rename to your own naming convention if different.

## Business logic implemented (v3 - rewritten after business review)

The FS's own text (TH1/TH2/TH3, section 2.2) turned out to be an incomplete
description of the real algorithm. After showing the FS-literal v2
implementation for review, the business (via 2 real screenshots + written
clarification) confirmed the actual rule uses a real field on
`I_GLAccountLineItem` - **Offsetting Account** - plus an amount-splitting
step. `ZBP_GL08_CHUNGTUGHISO=>combine_debit_credit` now does, per Journal
Entry:

1. **Cluster by Offsetting Account** (`cluster_by_offsetting_account`): a
   Debit line and a Credit line belong together if either one's Offsetting
   Account equals the other's G/L Account, or - when the offsetting side is
   a customer/vendor reconciliation posting - equals the other's
   Customer/Supplier. Linked lines are grouped transitively (if A links to B
   and B links to C, all three end up in one group).
2. **Positional fallback** (`cluster_by_position_fallback`) for any line that
   didn't link to anything: tax lines (`TaxCode` filled) are pulled out
   first; the remaining lines are walked in document order and every new
   Debit line starts a new group (subsequent Credit lines join it until the
   next Debit line); pulled-out tax lines are then reinserted into whichever
   resulting group is furthest from balancing (confirmed business rule:
   "nhom nao thieu thi bu thue vao" - top up whichever group is short).
3. **Waterfall allocation** (`waterfall_allocate`) within each group: sort
   Debit lines by amount descending and Credit lines by amount descending
   (ACDOCA convention - Debit positive, Credit negative - so this yields
   largest-absolute-first for Debit, smallest-absolute-first for Credit);
   repeatedly consume `min(abs(remaining debit), abs(remaining credit))`
   from the current pair, emit one output row per consumption, advance
   whichever side hits zero. Confirmed business rule: "chia so lon theo so
   nho ... it phai chia nho nhat" (split the larger line using the smaller
   ones, minimizing the number of splits).

This single algorithm reproduces the FS's TH1/TH2/TH3 examples exactly as a
special case (pure positional fallback, no Offsetting Account data: a lone
Debit or Credit line just keeps getting consumed one row at a time by the
other side), while correctly handling real multi-line documents using actual
account-level linkage instead of a blind cross join (which is what v2 did,
and was wrong - see the git history of this file for that version).

**Verified against 2 real examples during review** (now encoded as ABAP Unit
tests in `zbp_gl08_chungtughiso.clas.testclasses.abap`):
`offsetting_account_waterfall_example` reproduces the exact 3-row result
(2,000,000 / 4,000,000 / 400,000) the business confirmed for a 2-debit/
2-credit document linked via Offsetting Account.

The document-level "Thanh tien" field (#27) is a real `SUM` of all debit
lines' `Amount In Company Code Currency` for that document, deliberately
separate from the per-row debit/credit amount columns above (which get
split/allocated and would double-count if summed in a UI footer).

### Remaining open point

What happens when a group still doesn't balance to zero after tax
reinsertion (data quality issue, or a document shape this algorithm doesn't
anticipate)? Currently `waterfall_allocate` just stops when one side runs out
of lines, silently dropping any residual amount left on the other side. Flag
if this needs different handling (e.g. an explicit "unmatched remainder" row,
or raising an error).

## Field mapping - FS -> entity -> `I_GLAccountLineItem` (VERIFY before activation)

**v2 update:** I still have no live connection to your SAP system, but I
cross-checked field names against SAP's public CDS/OData VDM documentation
(SAP Business Accelerator Hub, SAP Cloud SDK docs, and a public ACDOCA-based
CDS field reference) and corrected the ones that were wrong or unconfirmed in
the first draft - most importantly the line-item-number field, which was
**wrong** in v1 (`glaccountlineitem`, not a real field - it doesn't exist and
would have pulled no data / an activation error, likely the "data lay sai"
you hit) and is now `LedgerGLLineItem` (ACDOCA's `DOCLN`, confirmed). Status
and the reversal flags are now derived from confirmed fields instead of
being left blank. A handful of fields remain genuinely unconfirmed (marked
**Low** below) - I could not verify these from public documentation and they
still need a check in ADT.

| # | FS field | Entity field | Source field | Confidence |
|---|---|---|---|---|
| 1 | Status | `status` | Derived: `ClearingDate`/`ClearingAccountingDocument` initial => Open, else Cleared | Medium - fields confirmed, derivation logic (O/C) is my assumption |
| 2 | So chung tu | `document_number` | `DocumentReferenceID` (reused) | Low - FS lists this separately from Journal Entry and Document Reference ID with no clear distinct source |
| 3 | Ngay hoa don | `invoice_date` | `DocumentDate` | Medium |
| 4 | Document Reference ID | `document_reference_id` | `DocumentReferenceID` | Medium-High |
| 5 | Ten don vi | `company_name` | Not wired - needs `I_CompanyCodeText`/similar association | **Low** |
| 6 | Customer | `customer` | `Customer` | High |
| 7 | Supplier | `supplier` | `Supplier` | High |
| 8 | Fixed Asset | `fixed_asset` | `FixedAsset` | High (confirmed via SAP Cloud SDK VDM docs) |
| 9 | Journal Entry | `journal_entry` | `AccountingDocument` | High (confirmed) |
| 10 | Item Text | `item_text` | `DocumentItemText` (name TODO) | Medium |
| 11 | Journal Entry Type | `journal_entry_type` | `AccountingDocumentType` | High (confirmed) |
| 12 | Posting Date | `posting_date` | `PostingDate` | High |
| 13 | Journal Entry Date | `journal_entry_date` | `DocumentDate` (reused - TODO) | **Low - likely a distinct field from #3/#12** |
| 14/15 | Debit/Credit Journal Entry Item | key fields | `LedgerGLLineItem` | **High (confirmed - fixes the wrong `glaccountlineitem` guess from v1)** |
| 16/17 | Debit/Credit G/L account | `debit_gl_account`/`credit_gl_account` | `GLAccount` | High |
| 18/19 | Debit/Credit Code | `debit_code`/`credit_code` | `DebitCreditCode` | High (confirmed) |
| 20-23 | Amount columns | `debit_amount_cc` etc. | `AmountInCompanyCodeCurrency` / `AmountInTransactionCurrency` (+ `CompanyCodeCurrency` / `TransactionCurrency`) | High (all confirmed), logic per TH1-3 |
| 24/25 | Base Unit / Quantity | `base_unit_of_measure`/`quantity` | `BaseUnit` / `Quantity` | Medium |
| 26/27 | Don gia / Thanh tien | computed in ABAP | n/a (derived) | n/a |
| 28/29 | Tax Code/Amount | `tax_code`/`tax_amount` | `TaxCode`/`TaxAmount` | Medium-High |
| 30 | Product | `product` | `Product` (may be `Material`) | Medium |
| 31 | Account Assignment | `account_assignment` | Not wired | **Low - unclear which CO object (length 30 confirmed, name still a guess)** |
| 32/33 | Cost/Profit Center | `cost_center`/`profit_center` | `CostCenter`/`ProfitCenter` | High |
| 34 | Dia chi | `address` | Not wired - needs BP address lookup | **Low** |
| 35 | Is Reversed | `is_reversed` | `IsReversed` | High (confirmed) |
| 36 | Is Reversing | `is_reversing` | Derived: `ReverseDocument` populated AND `IsReversed` = false | Medium - fields confirmed, direction of `ReverseDocument` and the derivation itself are my assumption |

Also confirmed and now used internally (not FS-visible fields): `CompanyCode`,
`FiscalYear`, `AccountingDocument`, `Ledger` (report hardcodes leading ledger
`0L` - the FS has no ledger selection field), `ReversalReason`, and
**`OffsettingAccount`** - confirmed to exist from a live screenshot you
provided during review; exact CDS spelling is still a guess (`offsettingaccount`)
and needs a final check in ADT.

## Known gaps to close before go-live

1. Verify every field name in the two `SELECT`/`fill_common_fields` methods
   of `ZBP_GL08_CHUNGTUGHISO` against your actual `I_GLAccountLineItem` -
   most are now confirmed against public SAP documentation, but a live
   Data Preview in ADT is still the only way to be 100% sure for your
   release/system.
2. Wire up `company_name`, `address`, `account_assignment` (currently
   blank - see table above); double check the `status` / `is_reversing`
   derivation logic against real Open/Cleared and reversed/reversing
   documents.
3. Confirm the exact CDS field name for **Offsetting Account** (the whole
   v3 pairing algorithm depends on it) and decide what should happen when a
   group still doesn't balance after tax-line reinsertion (see "Remaining
   open point" above).
4. Decide whether "Debit G/L account" / "Credit G/L account" / Is
   Reversed / Is Reversing should be **server-side filterable** - as coded
   they're UI filter fields but only usable as a post-filter on the paired
   result (they don't exist as single-row properties before pairing). See
   the `NOTE` comment in `read_line_items`.
5. The report hardcodes the leading ledger (`0L`) since the FS doesn't
   mention Ledger as a selection field - add a real filter if parallel
   ledgers are in scope.
6. `IF_RAP_QUERY_PROVIDER`/`IF_RAP_QUERY_REQUEST` method names (paging,
   response object) are written to the best of my knowledge but can vary
   slightly by release - see the class-level ABAP Doc comment in
   `zbp_gl08_chungtughiso.clas.abap`.
7. Run the new ABAP Unit tests (`zbp_gl08_chungtughiso.clas.testclasses.abap`)
   against your real system and, ideally, replay the 2 example documents you
   showed during review end-to-end via the activated OData service to
   double check the final numbers match.

## Manual setup steps (in ADT)

1. Create package `ZPTB_FA` (or your chosen package) if it doesn't exist.
2. Import/paste the objects **in this order** (each depends on the previous):
   `ZC_GL08_CHUNGTUGHISO` (DDLS) -> `ZBP_GL08_CHUNGTUGHISO` (CLAS, incl. test
   include) -> `ZC_GL08_CHUNGTUGHISO` (BDEF) -> `ZC_GL08_CHUNGTUGHISO_MD`
   (DDLX) -> `ZUI_GL08_CHUNGTUGHISO` (SRVD).
3. Fix the field names flagged `TODO VERIFY` in the class, re-activate.
4. Run the ABAP Unit tests (`Ctrl+Shift+F10` on the class, or right-click ->
   Run As -> ABAP Unit Test) to confirm the pairing logic before wiring up
   OData.
5. In ADT: right-click `ZUI_GL08_CHUNGTUGHISO` -> New -> Service Binding ->
   OData V4, UI; bind `ChungTuGhiSo`; activate; Publish.
6. Use "Preview" on the service binding to sanity-check the data, or
   generate a List Report app (SAP Fiori tools / App Generator, or via the
   ADT "Generate UI" option on the service binding) pointing at this
   service.
7. Assign the generated app's tile/catalog per your Fiori Launchpad setup
   (outside the scope of this delivery).
