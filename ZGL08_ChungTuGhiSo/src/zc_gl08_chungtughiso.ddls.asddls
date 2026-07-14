@EndUserText.label: 'ZGL08 - Chung tu ghi so (GL line item split report)'

// ---------------------------------------------------------------------------
// Custom Entity for the ZGL08_ChungTuGhiSo report.
//
// WHY a Custom Entity instead of a plain projection on I_GLAccountLineItem:
// the FS requires splitting each Journal Entry's debit/credit line items into
// paired output rows with sign-flipped "derived" amounts (see rules TH1/TH2/TH3
// in the FS, section 2.2). That row-pairing logic cannot be expressed as a
// declarative CDS view, so it is implemented in ABAP inside the query
// provider class ZBP_GL08_CHUNGTUGHISO (see if_rap_query_provider~select).
//
// This entity has NO underlying persistence (`root custom entity`) - all data
// comes from I_GLAccountLineItem at query time, reshaped by the query class.
// ---------------------------------------------------------------------------
@ObjectModel.query.implementedBy: 'ABAP:ZBP_GL08_CHUNGTUGHISO'
define root custom entity ZC_GL08_CHUNGTUGHISO
{
      // --- technical key: identifies one (debit line, credit line) pairing ---
  key company_code               : abap.char(4);
  key fiscal_year                 : abap.numc(4);
  key accounting_document         : abap.char(10);
  key debit_journal_entry_item    : abap.numc(6);
  key credit_journal_entry_item   : abap.numc(6);

      // --- FS field 1: Status ---------------------------------------------
      // TODO VERIFY: I_GLAccountLineItem has no plain "Status" field AFAIK.
      // Likely derived from the clearing fields (ClearingDate/ClearingDocument
      // initial => 'Open', else 'Cleared'). Confirm exact source with the FS
      // author / by checking the "Display Line Items in General Ledger" app.
      status                          : abap.char(1);

      // --- FS field 2: So chung tu (document number) -----------------------
      // TODO VERIFY: FS lists "So chung tu" both as an output field (#2) and
      // as a *separate* optional selection parameter, distinct from
      // "Journal Entry" (=AccountingDocument). Mapped here to ReferenceDocument
      // as a best guess - confirm against the FS author's intent.
      document_number                 : abap.char(20);

      // --- FS field 3: Ngay hoa don (invoice/document date) ----------------
      invoice_date                    : abap.dats;

      // --- FS field 4: Document Reference ID --------------------------------
      document_reference_id           : abap.char(20);

      // --- FS field 5: Ten don vi (company name) ---------------------------
      // TODO VERIFY: not a native field of I_GLAccountLineItem - needs a text
      // lookup (association to I_CompanyCodeText or similar) in the query class.
      company_name                    : abap.char(100);

      customer                        : abap.char(10);
      supplier                        : abap.char(10);
      fixed_asset                     : abap.char(12);

      // --- FS field 9: Journal Entry (accounting document number) ----------
      journal_entry                   : abap.char(10);

      item_text                       : abap.char(50);
      journal_entry_type              : abap.char(2);
      posting_date                    : abap.dats;

      // --- FS field 13: Journal Entry Date ----------------------------------
      // TODO VERIFY: distinct from Posting Date / Document Date - confirm
      // which ACDOCA/I_GLAccountLineItem date field this maps to.
      journal_entry_date              : abap.dats;

      // NOTE: the debit/credit journal entry item numbers are already exposed
      // via the key fields debit_journal_entry_item / credit_journal_entry_item
      // above (FS fields #14/#15) - always taken as-is from the paired source
      // line, never sign-flipped.

      debit_gl_account                : abap.char(10);
      credit_gl_account                : abap.char(10);
      debit_code                      : abap.char(1);
      credit_code                     : abap.char(1);

      // --- amounts: derived per TH1/TH2/TH3 rules in the query class --------
      debit_amount_cc                 : abap.curr(23,2);
      credit_amount_cc                : abap.curr(23,2);
      debit_amount_tc                 : abap.curr(23,2);
      credit_amount_tc                : abap.curr(23,2);
      company_code_currency           : abap.cuky(5);
      transaction_currency            : abap.cuky(5);

      base_unit_of_measure            : abap.unit(3);
      quantity                        : abap.quan(13,3);

      // --- FS field 26/27: computed fields (see query class) ----------------
      unit_price                      : abap.curr(23,2);
      total_amount                    : abap.curr(23,2);

      tax_code                        : abap.char(2);
      tax_amount                      : abap.curr(23,2);
      product                         : abap.char(40);

      // TODO VERIFY: "Account Assignment" - FS leaves the length blank; likely
      // the CO account assignment object type/key. Confirm exact source field.
      account_assignment              : abap.char(30);

      cost_center                     : abap.char(10);
      profit_center                   : abap.char(10);

      // TODO VERIFY: "Dia chi" (address) - not native to I_GLAccountLineItem;
      // likely a customer/supplier address lookup. Confirm which BP/address.
      address                         : abap.char(100);

      // TODO VERIFY: confirm these reversal flags exist on I_GLAccountLineItem
      // directly, or require an association to I_JournalEntry (header).
      is_reversed                     : abap_boolean;
      is_reversing                    : abap_boolean;

      // -----------------------------------------------------------------
      // Filter-only technical fields: needed by the FS's selection-parameter
      // list (section 2.2.2) but not part of the displayed field list
      // (section 2.2.3). Excluded from @UI.lineItem in the metadata
      // extension - present only so Fiori Elements can offer them in the
      // filter bar and the query class can push them down into the WHERE
      // clause on I_GLAccountLineItem.
      // -----------------------------------------------------------------
      gl_account                      : abap.char(10);
      creation_date_time              : abap.dats;
      created_by_user                 : abap.char(12);
}
