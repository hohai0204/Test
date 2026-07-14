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
its debit and credit line items and pair them into report rows, with 3 cases
(TH1/TH2/TH3) that flip the sign of the amount shown depending on which side
(debit or credit) has fewer posting lines. That's row-pairing / conditional
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

## Business logic implemented (FS section 2.2, "Yeu cau nghiep vu chi tiet")

For each Journal Entry (grouped by Company Code + Fiscal Year + Accounting
Document), line items are split into Debit (`DebitCreditCode = 'S'`) and
Credit (`'H'`) sets of size `n1`/`n2`:

- **TH1** (`n1=1, n2>1`): the single debit line is paired with every credit
  line; the shown **debit amount is derived as `-1 * that row's credit
  amount`**, credit keeps its real amount.
- **TH2** (`n2=1, n1>1`): symmetric - credit is derived as `-1 * that row's
  debit amount`.
- **TH3** (`n1>1, n2>1, n1<>n2`): whichever side has **fewer** lines gets its
  amount derived (as `-1 *` the paired line on the other, more-itemized
  side); the side with **more** lines keeps its own real amounts.

All three are implemented as one general rule in
`ZBP_GL08_CHUNGTUGHISO=>combine_debit_credit`.

### Two assumptions the FS leaves undefined - confirm with the FS author

1. **`n1 = n2` (equal counts, not covered by TH1/TH2/TH3):** implemented as
   1:1 pairing in ascending item order, both sides keep their own real
   amounts (no derivation, since neither side is a "coarser summary" of the
   other).
2. **General `n1 <> n2` with both `>1` (e.g. 3 debits vs 2 credits):** the FS
   states the amount-override *formula* but never states the row count for
   this case. This implementation takes the literal reading - a full cross
   join (`n1 x n2` rows) - of which TH1/TH2 are the special cases where one
   side has exactly 1 line. **Validate this against real sample documents**
   before go-live; it can produce a lot of rows for heavily-itemized
   documents (e.g. 5 debit x 6 credit = 30 rows for one journal entry).

The document-level "Thanh tien" field (#27) is a real `SUM` of all debit
lines' `Amount In Company Code Currency` for that document, deliberately
separate from the per-row debit/credit amount columns above (which are
sign-flipped/derived and would double-count if summed in a UI footer).

## Field mapping - FS -> entity -> `I_GLAccountLineItem` (VERIFY before activation)

I do not have field-level access to your system's `I_GLAccountLineItem`, so
this table is my best-effort guess based on the standard SAP CDS view of
that name. **Open the view in ADT (Data Preview / Ctrl+click) and correct any
mismatches** in `zbp_gl08_chungtughiso.clas.abap` (`read_line_items` and
`fill_common_fields`) before activating.

| # | FS field | Entity field | Assumed source | Confidence |
|---|---|---|---|---|
| 1 | Status | `status` | Not wired - no obvious native field | **Low - needs a derivation (e.g. clearing date/doc initial => Open)** |
| 2 | So chung tu | `document_number` | `DocumentReferenceID` (reused) | Low - FS lists this separately from Journal Entry and Document Reference ID with no clear distinct source |
| 3 | Ngay hoa don | `invoice_date` | `DocumentDate` | Medium |
| 4 | Document Reference ID | `document_reference_id` | `DocumentReferenceID` | Medium-High |
| 5 | Ten don vi | `company_name` | Not wired - needs `I_CompanyCodeText`/similar association | **Low** |
| 6 | Customer | `customer` | `Customer` | High |
| 7 | Supplier | `supplier` | `Supplier` | High |
| 8 | Fixed Asset | `fixed_asset` | `FixedAsset` | Medium |
| 9 | Journal Entry | `journal_entry` | `AccountingDocument` | High |
| 10 | Item Text | `item_text` | `DocumentItemText` (name TODO) | Medium |
| 11 | Journal Entry Type | `journal_entry_type` | `AccountingDocumentType` | High |
| 12 | Posting Date | `posting_date` | `PostingDate` | High |
| 13 | Journal Entry Date | `journal_entry_date` | `DocumentDate` (reused - TODO) | **Low - likely a distinct field from #3/#12** |
| 14/15 | Debit/Credit Journal Entry Item | key fields | `GLAccountLineItem` (name TODO) | Medium |
| 16/17 | Debit/Credit G/L account | `debit_gl_account`/`credit_gl_account` | `GLAccount` | High |
| 18/19 | Debit/Credit Code | `debit_code`/`credit_code` | `DebitCreditCode` | High |
| 20-23 | Amount columns | `debit_amount_cc` etc. | `AmountInCompanyCodeCurrency` / `AmountInTransactionCurrency` | High (name), logic per TH1-3 |
| 24/25 | Base Unit / Quantity | `base_unit_of_measure`/`quantity` | `BaseUnit` / `Quantity` | Medium |
| 26/27 | Don gia / Thanh tien | computed in ABAP | n/a (derived) | n/a |
| 28/29 | Tax Code/Amount | `tax_code`/`tax_amount` | `TaxCode`/`TaxAmount` | Medium |
| 30 | Product | `product` | `Product` (may be `Material`) | Medium |
| 31 | Account Assignment | `account_assignment` | Not wired | **Low - unclear which CO object** |
| 32/33 | Cost/Profit Center | `cost_center`/`profit_center` | `CostCenter`/`ProfitCenter` | High |
| 34 | Dia chi | `address` | Not wired - needs BP address lookup | **Low** |
| 35/36 | Is Reversed/Reversing | `is_reversed`/`is_reversing` | Not wired | **Low - may require association to `I_JournalEntry` header** |

## Known gaps to close before go-live

1. Verify every field name in the two `SELECT`/`fill_common_fields` methods
   of `ZBP_GL08_CHUNGTUGHISO` against your actual `I_GLAccountLineItem`.
2. Wire up `status`, `company_name`, `address`, `account_assignment`,
   `is_reversed`, `is_reversing` (currently blank - see table above).
3. Confirm the two undefined-by-the-FS assumptions (`n1=n2` pairing, general
   `n1<>n2` cross join) with the FS author using real documents.
4. Decide whether "Debit G/L account" / "Credit G/L account" / Is
   Reversed / Is Reversing should be **server-side filterable** - as coded
   they're UI filter fields but only usable as a post-filter on the paired
   result (they don't exist as single-row properties before pairing). See
   the `NOTE` comment in `read_line_items`.
5. The leading ledger is implicitly whatever `I_GLAccountLineItem`'s default
   is - the FS doesn't mention Ledger as a selection field; add one if
   parallel ledgers are in scope.
6. `IF_RAP_QUERY_PROVIDER`/`IF_RAP_QUERY_REQUEST` method names (paging,
   response object) are written to the best of my knowledge but can vary
   slightly by release - see the class-level ABAP Doc comment in
   `zbp_gl08_chungtughiso.clas.abap`.

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
