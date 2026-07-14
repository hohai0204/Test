"! Query provider class for the ZGL08_ChungTuGhiSo custom entity.
"!
"! v3 CHANGE LOG - the debit/credit pairing algorithm was REWRITTEN based on
"! two real examples and business clarifications provided directly by the
"! requester (not literally spelled out in the FS's TH1/TH2/TH3 text, which
"! turned out to be an incomplete description of this same real algorithm):
"!
"!   1. Lines are first grouped using the real "Offsetting Account" field
"!      (confirmed to exist on I_GLAccountLineItem from a live screenshot):
"!      a Debit line and a Credit line belong together if one line's
"!      Offsetting Account equals the other line's G/L Account, OR - when
"!      the offsetting side is a customer/vendor reconciliation posting -
"!      equals the other line's Customer or Supplier.
"!   2. Any line that doesn't link to anything via Offsetting Account falls
"!      back to positional grouping: tax lines (TaxCode filled) are pulled
"!      out first; the remaining lines are walked in document order and
"!      every new Debit line starts a new group (subsequent Credit lines
"!      join that group until the next Debit line starts a new one); the
"!      pulled-out tax lines are then added back into whichever resulting
"!      group is furthest from balancing (debit total <> credit total).
"!   3. Within each resulting group, amounts are allocated with a waterfall
"!      algorithm to minimize the number of splits: sort Debit lines by
"!      amount descending and Credit lines by amount descending too (ACDOCA
"!      convention: Debit amounts are stored positive, Credit amounts
"!      negative, so "descending" gives largest-absolute-first for Debit and
"!      smallest-absolute-first for Credit) and repeatedly consume
"!      min(abs(remaining debit), abs(remaining credit)) from the current
"!      pair, emitting one output row per consumption, advancing whichever
"!      side reaches zero, until both lists are exhausted.
"!
"!   This single algorithm reproduces the FS's TH1/TH2/TH3 examples exactly
"!   when there is no Offsetting Account data (pure positional fallback: a
"!   lone Debit or Credit line simply keeps absorbing/being absorbed by the
"!   other side's lines one at a time), while additionally handling real
"!   documents correctly when Offsetting Account data lets specific lines be
"!   linked instead of guessed at via a blind cross join (the v2 approach).
"!
"! STILL UNVERIFIED (I have no live connection to your SAP system):
"!   1. Every field marked "TODO VERIFY" below - open I_GLAccountLineItem in
"!      ADT (F2 / Data Preview) and adjust the SELECT's field list. The
"!      "Offsetting Account" field name below is my best guess at its exact
"!      CDS spelling (OffsettingAccount) - confirm it matches what you saw
"!      in your screenshot.
"!   2. The exact IF_RAP_QUERY_PROVIDER / IF_RAP_QUERY_REQUEST method
"!      signatures below (paging, response object creation) can differ
"!      slightly by release.
"!   3. What happens when a group still doesn't balance to zero after tax
"!      reinsertion (data quality issue, or a document type this algorithm
"!      doesn't anticipate) - currently the waterfall simply leaves a
"!      residual unmatched amount on whichever side has lines left over
"!      when the other side is exhausted; that residual line is dropped
"!      (see waterfall_allocate). Flag if this needs different handling.
CLASS zbp_gl08_chungtughiso DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    INTERFACES if_rap_query_provider.

  PRIVATE SECTION.
    TYPES:
      "! One row as read from I_GLAccountLineItem (one row per GL line item,
      "! i.e. BEFORE debit/credit pairing).
      BEGIN OF ty_raw,
        company_code                TYPE bukrs,
        fiscal_year                  TYPE gjahr,
        accounting_document          TYPE belnr_d,
        ledger                       TYPE rldnr,       " confirmed: ACDOCA/RLDNR - not in FS as a filter, hardcoded to leading ledger below
        ledger_gl_line_item          TYPE docln6,        " confirmed field: LedgerGLLineItem (ACDOCA-DOCLN, 6 chars)
        gl_account                   TYPE saknr,
        offsetting_account           TYPE char10,        " confirmed to exist (user screenshot); exact CDS name still TODO VERIFY
        debit_credit_code            TYPE shkzg,
        posting_date                 TYPE budat,
        document_date                TYPE bldat,
        creation_date_time           TYPE cpudt,
        created_by_user              TYPE usnam,
        accounting_document_type     TYPE blart,
        amount_in_company_code_ccy   TYPE wrbtr,
        company_code_currency        TYPE waers,
        amount_in_transaction_ccy    TYPE wrbtr,
        transaction_currency         TYPE waers,
        document_reference_id        TYPE xblnr1,
        customer                     TYPE kunnr,
        supplier                     TYPE lifnr,
        fixed_asset                  TYPE anln1,
        item_text                    TYPE sgtxt,
        quantity                     TYPE menge_d,
        base_unit_of_measure         TYPE meins,
        tax_code                     TYPE mwskz,
        tax_amount                   TYPE wmwst,
        product                      TYPE matnr,
        cost_center                  TYPE kostl,
        profit_center                TYPE prctr,
        is_reversed                  TYPE abap_boolean,  " confirmed field: IsReversed
        reversal_reason              TYPE bkpf-stgrd,    " confirmed field: ReversalReason
        reverse_document             TYPE belnr_d,       " confirmed field: ReverseDocument
        clearing_date                TYPE budat,         " confirmed field: ClearingDate
        clearing_accounting_document TYPE belnr_d,       " confirmed field: ClearingAccountingDocument
      END OF ty_raw.
    TYPES ty_raw_tab TYPE STANDARD TABLE OF ty_raw WITH EMPTY KEY.
    TYPES ty_result_tab TYPE STANDARD TABLE OF zc_gl08_chungtughiso WITH EMPTY KEY.

    "! One matching group: some Debit lines and some Credit lines that
    "! belong together (either via Offsetting Account, or via the positional
    "! fallback) and must balance to zero once fully allocated.
    TYPES: BEGIN OF ty_cluster,
             debit  TYPE ty_raw_tab,
             credit TYPE ty_raw_tab,
           END OF ty_cluster.
    TYPES ty_cluster_tab TYPE STANDARD TABLE OF ty_cluster WITH EMPTY KEY.

    CONSTANTS c_debit          TYPE shkzg VALUE 'S'.
    CONSTANTS c_credit         TYPE shkzg VALUE 'H'.
    CONSTANTS c_leading_ledger TYPE rldnr VALUE '0L'.
    CONSTANTS c_status_open    TYPE char1 VALUE 'O'.
    CONSTANTS c_status_cleared TYPE char1 VALUE 'C'.

    METHODS read_line_items
      IMPORTING
        io_request    TYPE REF TO if_rap_query_request
      RETURNING
        VALUE(rt_raw) TYPE ty_raw_tab
      RAISING
        cx_rap_query_provider.

    "! Top-level entry point for one document's pairing: builds Offsetting
    "! Account groups, falls back positionally for anything left over, then
    "! runs the waterfall allocation on every resulting group.
    METHODS combine_debit_credit
      IMPORTING
        it_debit         TYPE ty_raw_tab
        it_credit        TYPE ty_raw_tab
      RETURNING
        VALUE(rt_result) TYPE ty_result_tab.

    "! True if a Debit line and a Credit line reference each other via
    "! Offsetting Account (either direction), matching G/L Account or,
    "! when the offset is a business partner posting, Customer/Supplier.
    METHODS is_linked
      IMPORTING
        is_debit        TYPE ty_raw
        is_credit       TYPE ty_raw
      RETURNING
        VALUE(rv_linked) TYPE abap_bool.

    "! Groups debit/credit lines that are linked via Offsetting Account
    "! (transitively - if A links to B and B links to C, all three group
    "! together). Lines with no link to anything on the other side are
    "! returned separately as leftovers for the positional fallback.
    METHODS cluster_by_offsetting_account
      IMPORTING
        it_debit             TYPE ty_raw_tab
        it_credit            TYPE ty_raw_tab
      EXPORTING
        et_clusters          TYPE ty_cluster_tab
        et_leftover_debit    TYPE ty_raw_tab
        et_leftover_credit   TYPE ty_raw_tab.

    "! Positional fallback for lines with no Offsetting Account link: tax
    "! lines are excluded first, remaining lines are walked in document
    "! order (each new Debit line starts a new group), then excluded tax
    "! lines are reinserted into whichever group is furthest from balancing.
    METHODS cluster_by_position_fallback
      IMPORTING
        it_leftover_debit    TYPE ty_raw_tab
        it_leftover_credit   TYPE ty_raw_tab
      RETURNING
        VALUE(rt_clusters)   TYPE ty_cluster_tab.

    "! Allocates amounts within a single group by repeatedly consuming
    "! min(abs(remaining debit), abs(remaining credit)) from the largest
    "! remaining Debit line against the smallest remaining Credit line,
    "! emitting one output row per consumption (see class doc for why this
    "! reproduces the FS's TH1/TH2/TH3 examples as special cases).
    METHODS waterfall_allocate
      IMPORTING
        it_debit         TYPE ty_raw_tab
        it_credit        TYPE ty_raw_tab
      RETURNING
        VALUE(rt_result) TYPE ty_result_tab.

    "! Fills every output field that does NOT depend on the waterfall
    "! amount allocation (references, texts, quantity/unit price, ...).
    "! NOTE: quantity/unit price are NOT prorated when a line's amount gets
    "! split across multiple output rows - a known simplification.
    METHODS fill_common_fields
      IMPORTING
        is_debit      TYPE ty_raw
        is_credit     TYPE ty_raw
      RETURNING
        VALUE(rs_row) TYPE zc_gl08_chungtughiso.

ENDCLASS.


CLASS zbp_gl08_chungtughiso IMPLEMENTATION.

  METHOD if_rap_query_provider~select.

    DATA(lt_raw) = read_line_items( io_request ).
    SORT lt_raw BY company_code fiscal_year accounting_document ledger_gl_line_item ASCENDING.

    DATA lt_result TYPE ty_result_tab.
    DATA lt_debit  TYPE ty_raw_tab.
    DATA lt_credit TYPE ty_raw_tab.

    LOOP AT lt_raw INTO DATA(ls_raw)
         GROUP BY ( company_code        = ls_raw-company_code
                    fiscal_year         = ls_raw-fiscal_year
                    accounting_document = ls_raw-accounting_document )
         ASCENDING
         REFERENCE INTO DATA(lo_group).

      CLEAR: lt_debit, lt_credit.

      LOOP AT GROUP lo_group INTO DATA(ls_member).
        CASE ls_member-debit_credit_code.
          WHEN c_debit.
            APPEND ls_member TO lt_debit.
          WHEN c_credit.
            APPEND ls_member TO lt_credit.
        ENDCASE.
      ENDLOOP.

      " FS field 27 "Thanh tien": sum of Amount In Company Code Currency
      " across all DEBIT lines of this one document - repeated on every
      " output row belonging to this document (a document-level total,
      " deliberately NOT the same as the per-row debit/credit amount
      " columns, which get split/allocated and would double count if simply
      " summed in the UI footer).
      DATA(lv_total_amount) = REDUCE wrbtr( INIT sum = 0
                                             FOR ls_d IN lt_debit
                                             NEXT sum = sum + ls_d-amount_in_company_code_ccy ).

      DATA(lv_before) = lines( lt_result ).
      APPEND LINES OF combine_debit_credit( it_debit  = lt_debit
                                             it_credit = lt_credit ) TO lt_result.

      LOOP AT lt_result ASSIGNING FIELD-SYMBOL(<fs_row>) FROM lv_before + 1.
        <fs_row>-total_amount = lv_total_amount.
      ENDLOOP.

    ENDLOOP.

    " FS "Mo ta tieu chi sap xep" (section 2.2.4): Journal Entry, then
    " Debit Journal Entry Item, then Credit Journal Entry Item, all ASC.
    SORT lt_result BY journal_entry            ASCENDING
                      debit_journal_entry_item  ASCENDING
                      credit_journal_entry_item ASCENDING.

    " --- Paging / total count / response -----------------------------------
    " TODO VERIFY: exact method names on IF_RAP_QUERY_REQUEST / the response
    " object can vary slightly by release - see class-level documentation.
    DATA(lo_response) = io_request->create_response_data( ).

    IF io_request->is_total_numb_of_rec_requested( ).
      lo_response->set_total_number_of_records( lines( lt_result ) ).
    ENDIF.

    DATA(lv_offset)    = io_request->get_paging( )->get_offset( ).
    DATA(lv_page_size) = io_request->get_paging( )->get_page_size( ).

    IF lv_page_size IS INITIAL.
      lo_response->set_data( lt_result ).
    ELSE.
      DATA(lv_to) = lv_offset + lv_page_size.
      IF lv_to > lines( lt_result ).
        lv_to = lines( lt_result ).
      ENDIF.
      IF lv_offset < lines( lt_result ).
        lo_response->set_data( VALUE #( FOR ls_row IN lt_result
                                         FROM lv_offset + 1 TO lv_to
                                         ( ls_row ) ) ).
      ENDIF.
    ENDIF.

    result = lo_response.

  ENDMETHOD.


  METHOD read_line_items.

    " --- Mandatory filters (FS 2.2.2: Company Code, Posting Date) ----------
    DATA(lt_range_company_code) = io_request->get_filter( )->get_as_ranges( 'COMPANY_CODE' ).
    DATA(lt_range_posting_date) = io_request->get_filter( )->get_as_ranges( 'POSTING_DATE' ).

    IF lt_range_company_code IS INITIAL OR lt_range_posting_date IS INITIAL.
      " TODO: raise with a proper message class instead of the generic
      " client_error text, e.g. "Please enter Company Code and Posting Date".
      RAISE EXCEPTION TYPE cx_rap_query_provider
        EXPORTING
          textid = cx_rap_query_provider=>client_error.
    ENDIF.

    " --- Optional filters (FS 2.2.2) - extend/adjust field names as needed --
    DATA(lt_range_gl_account)         = io_request->get_filter( )->get_as_ranges( 'GL_ACCOUNT' ).
    DATA(lt_range_journal_entry_type) = io_request->get_filter( )->get_as_ranges( 'JOURNAL_ENTRY_TYPE' ).
    DATA(lt_range_journal_entry)      = io_request->get_filter( )->get_as_ranges( 'JOURNAL_ENTRY' ).
    DATA(lt_range_customer)          = io_request->get_filter( )->get_as_ranges( 'CUSTOMER' ).
    DATA(lt_range_supplier)          = io_request->get_filter( )->get_as_ranges( 'SUPPLIER' ).
    DATA(lt_range_fixed_asset)       = io_request->get_filter( )->get_as_ranges( 'FIXED_ASSET' ).
    DATA(lt_range_tax_code)          = io_request->get_filter( )->get_as_ranges( 'TAX_CODE' ).
    DATA(lt_range_product)          = io_request->get_filter( )->get_as_ranges( 'PRODUCT' ).
    DATA(lt_range_cost_center)       = io_request->get_filter( )->get_as_ranges( 'COST_CENTER' ).
    DATA(lt_range_profit_center)     = io_request->get_filter( )->get_as_ranges( 'PROFIT_CENTER' ).
    DATA(lt_range_document_ref_id)   = io_request->get_filter( )->get_as_ranges( 'DOCUMENT_REFERENCE_ID' ).

    " NOTE: "Debit G/L account", "Credit G/L account", Is Reversed/Is
    " Reversing filters only make sense AFTER pairing (they are not
    " properties of a single I_GLAccountLineItem row) - apply those as an
    " extra FILTER on rt_raw/lt_result if the business needs them pushed
    " down; small, isolated extension point.

    " NOTE: FS does not expose "Ledger" as a selection parameter. Hardcoded
    " to the leading ledger (0L) below - add a real filter/parameter if
    " parallel ledgers are in scope for this report.

    SELECT FROM i_glaccountlineitem                                    "#EC CI_NOORDER
      FIELDS
        companycode                    AS company_code,
        fiscalyear                      AS fiscal_year,
        accountingdocument               AS accounting_document,
        ledger                            AS ledger,
        ledgergllineitem                   AS ledger_gl_line_item,       " confirmed: LedgerGLLineItem
        glaccount                          AS gl_account,
        offsettingaccount                   AS offsetting_account,       " TODO VERIFY exact spelling (per your screenshot)
        debitcreditcode                       AS debit_credit_code,
        postingdate                            AS posting_date,
        documentdate                            AS document_date,        "TODO VERIFY: also used for "Journal Entry Date"? (FS #3 vs #13)
        journalentrycreatedbyuser                AS created_by_user,     " medium-high confidence: FS's own param label matches this name
        accountingdocumenttype                    AS accounting_document_type,
        amountincompanycodecurrency                AS amount_in_company_code_ccy,
        companycodecurrency                          AS company_code_currency,
        amountintransactioncurrency                    AS amount_in_transaction_ccy,
        transactioncurrency                              AS transaction_currency,
        documentreferenceid                                AS document_reference_id,
        customer                                             AS customer,
        supplier                                               AS supplier,
        fixedasset                                              AS fixed_asset,
        documentitemtext                                          AS item_text,   "TODO VERIFY field name
        quantity                                                    AS quantity,
        baseunit                                                      AS base_unit_of_measure,
        taxcode                                                         AS tax_code,
        taxamount                                                         AS tax_amount,
        product                                                             AS product,   "TODO VERIFY: may be "material"
        costcenter                                                           AS cost_center,
        profitcenter                                                           AS profit_center,
        isreversed                                                               AS is_reversed,              " confirmed
        reversalreason                                                            AS reversal_reason,          " confirmed
        reversedocument                                                            AS reverse_document,        " confirmed
        clearingdate                                                                 AS clearing_date,
        clearingaccountingdocument                                                   AS clearing_accounting_document " confirmed
      WHERE
            companycode IN @lt_range_company_code
        AND postingdate IN @lt_range_posting_date
        AND ledger      = @c_leading_ledger
        AND ( @lt_range_gl_account         IS INITIAL OR glaccount              IN @lt_range_gl_account )
        AND ( @lt_range_journal_entry_type IS INITIAL OR accountingdocumenttype IN @lt_range_journal_entry_type )
        AND ( @lt_range_journal_entry      IS INITIAL OR accountingdocument     IN @lt_range_journal_entry )
        AND ( @lt_range_customer           IS INITIAL OR customer               IN @lt_range_customer )
        AND ( @lt_range_supplier           IS INITIAL OR supplier               IN @lt_range_supplier )
        AND ( @lt_range_fixed_asset        IS INITIAL OR fixedasset             IN @lt_range_fixed_asset )
        AND ( @lt_range_tax_code           IS INITIAL OR taxcode                IN @lt_range_tax_code )
        AND ( @lt_range_product            IS INITIAL OR product                IN @lt_range_product )
        AND ( @lt_range_cost_center        IS INITIAL OR costcenter             IN @lt_range_cost_center )
        AND ( @lt_range_profit_center      IS INITIAL OR profitcenter           IN @lt_range_profit_center )
        AND ( @lt_range_document_ref_id    IS INITIAL OR documentreferenceid    IN @lt_range_document_ref_id )
      INTO CORRESPONDING FIELDS OF TABLE @rt_raw.

    " creation_date_time (date+time as one field vs two separate fields on
    " the real view) is still a TODO - see README "Known gaps".

  ENDMETHOD.


  METHOD combine_debit_credit.

    IF it_debit IS INITIAL OR it_credit IS INITIAL.
      " Document has only one side (e.g. a one-sided/statistical posting) -
      " no pairing is defined for this case, so it is skipped.
      RETURN.
    ENDIF.

    DATA lt_clusters        TYPE ty_cluster_tab.
    DATA lt_leftover_debit  TYPE ty_raw_tab.
    DATA lt_leftover_credit TYPE ty_raw_tab.

    cluster_by_offsetting_account(
      EXPORTING it_debit           = it_debit
                it_credit          = it_credit
      IMPORTING et_clusters        = lt_clusters
                et_leftover_debit  = lt_leftover_debit
                et_leftover_credit = lt_leftover_credit ).

    APPEND LINES OF cluster_by_position_fallback(
                       it_leftover_debit  = lt_leftover_debit
                       it_leftover_credit = lt_leftover_credit ) TO lt_clusters.

    LOOP AT lt_clusters INTO DATA(ls_cluster).
      APPEND LINES OF waterfall_allocate( it_debit  = ls_cluster-debit
                                          it_credit = ls_cluster-credit ) TO rt_result.
    ENDLOOP.

  ENDMETHOD.


  METHOD is_linked.

    rv_linked = xsdbool(
         ( is_debit-offsetting_account IS NOT INITIAL
           AND ( is_debit-offsetting_account = is_credit-gl_account
              OR is_debit-offsetting_account = is_credit-customer
              OR is_debit-offsetting_account = is_credit-supplier ) )
      OR ( is_credit-offsetting_account IS NOT INITIAL
           AND ( is_credit-offsetting_account = is_debit-gl_account
              OR is_credit-offsetting_account = is_debit-customer
              OR is_credit-offsetting_account = is_debit-supplier ) ) ).

  ENDMETHOD.


  METHOD cluster_by_offsetting_account.

    TYPES: BEGIN OF ty_tagged,
             line          TYPE ty_raw,
             is_debit_side TYPE abap_bool,
             cluster_id    TYPE i,
           END OF ty_tagged.
    DATA lt_tagged TYPE STANDARD TABLE OF ty_tagged WITH EMPTY KEY.

    LOOP AT it_debit INTO DATA(ls_d).
      APPEND VALUE #( line = ls_d is_debit_side = abap_true cluster_id = sy-tabix ) TO lt_tagged.
    ENDLOOP.
    DATA(lv_offset) = lines( it_debit ).
    LOOP AT it_credit INTO DATA(ls_c).
      APPEND VALUE #( line = ls_c is_debit_side = abap_false cluster_id = lv_offset + sy-tabix ) TO lt_tagged.
    ENDLOOP.

    " Simple union-find by repeated relabeling (small n per document - a
    " journal entry rarely has more than a handful of line items).
    DATA(lv_changed) = abap_true.
    WHILE lv_changed = abap_true.
      lv_changed = abap_false.
      LOOP AT lt_tagged ASSIGNING FIELD-SYMBOL(<a>) WHERE is_debit_side = abap_true.
        LOOP AT lt_tagged ASSIGNING FIELD-SYMBOL(<b>) WHERE is_debit_side = abap_false.
          IF <a>-cluster_id <> <b>-cluster_id AND is_linked( is_debit = <a>-line is_credit = <b>-line ) = abap_true.
            DATA(lv_old_id) = <b>-cluster_id.
            DATA(lv_new_id) = <a>-cluster_id.
            LOOP AT lt_tagged ASSIGNING FIELD-SYMBOL(<c>) WHERE cluster_id = lv_old_id.
              <c>-cluster_id = lv_new_id.
            ENDLOOP.
            lv_changed = abap_true.
          ENDIF.
        ENDLOOP.
      ENDLOOP.
    ENDWHILE.

    SORT lt_tagged BY cluster_id ASCENDING.

    LOOP AT lt_tagged INTO DATA(ls_tagged)
         GROUP BY ( id = ls_tagged-cluster_id ) ASCENDING
         REFERENCE INTO DATA(lo_grp).

      DATA lt_grp_debit  TYPE ty_raw_tab.
      DATA lt_grp_credit TYPE ty_raw_tab.
      CLEAR: lt_grp_debit, lt_grp_credit.

      LOOP AT GROUP lo_grp INTO DATA(ls_member).
        IF ls_member-is_debit_side = abap_true.
          APPEND ls_member-line TO lt_grp_debit.
        ELSE.
          APPEND ls_member-line TO lt_grp_credit.
        ENDIF.
      ENDLOOP.

      IF lt_grp_debit IS NOT INITIAL AND lt_grp_credit IS NOT INITIAL.
        APPEND VALUE #( debit = lt_grp_debit credit = lt_grp_credit ) TO et_clusters.
      ELSE.
        APPEND LINES OF lt_grp_debit  TO et_leftover_debit.
        APPEND LINES OF lt_grp_credit TO et_leftover_credit.
      ENDIF.

    ENDLOOP.

  ENDMETHOD.


  METHOD cluster_by_position_fallback.

    DATA lt_debit_main  TYPE ty_raw_tab.
    DATA lt_credit_main TYPE ty_raw_tab.
    DATA lt_tax_lines   TYPE ty_raw_tab.

    LOOP AT it_leftover_debit INTO DATA(ls_ld).
      IF ls_ld-tax_code IS NOT INITIAL.
        APPEND ls_ld TO lt_tax_lines.
      ELSE.
        APPEND ls_ld TO lt_debit_main.
      ENDIF.
    ENDLOOP.
    LOOP AT it_leftover_credit INTO DATA(ls_lc).
      IF ls_lc-tax_code IS NOT INITIAL.
        APPEND ls_lc TO lt_tax_lines.
      ELSE.
        APPEND ls_lc TO lt_credit_main.
      ENDIF.
    ENDLOOP.

    " Walk the remaining (non-tax) lines in original document order: every
    " new Debit line opens a new group, subsequent Credit lines join it
    " until the next Debit line starts another group.
    DATA lt_ordered TYPE ty_raw_tab.
    APPEND LINES OF lt_debit_main  TO lt_ordered.
    APPEND LINES OF lt_credit_main TO lt_ordered.
    SORT lt_ordered BY ledger_gl_line_item ASCENDING.

    DATA lt_cur_debit         TYPE ty_raw_tab.
    DATA lt_cur_credit        TYPE ty_raw_tab.
    DATA lv_have_open_cluster TYPE abap_bool VALUE abap_false.

    LOOP AT lt_ordered INTO DATA(ls_o).
      IF ls_o-debit_credit_code = c_debit.
        IF lv_have_open_cluster = abap_true.
          APPEND VALUE #( debit = lt_cur_debit credit = lt_cur_credit ) TO rt_clusters.
          CLEAR: lt_cur_debit, lt_cur_credit.
        ENDIF.
        APPEND ls_o TO lt_cur_debit.
        lv_have_open_cluster = abap_true.
      ELSE.
        APPEND ls_o TO lt_cur_credit.
      ENDIF.
    ENDLOOP.
    IF lv_have_open_cluster = abap_true.
      APPEND VALUE #( debit = lt_cur_debit credit = lt_cur_credit ) TO rt_clusters.
    ENDIF.

    " Reinsert excluded tax lines into whichever group is furthest from
    " balancing (business rule: "nhom nao thieu thi bu thue vao").
    LOOP AT lt_tax_lines INTO DATA(ls_tax).
      DATA(lv_best_idx) = 0.
      DATA(lv_best_gap) = 0.
      LOOP AT rt_clusters ASSIGNING FIELD-SYMBOL(<cl>).
        DATA(lv_debit_total)  = REDUCE wrbtr( INIT s = 0 FOR d IN <cl>-debit  NEXT s = s + d-amount_in_company_code_ccy ).
        DATA(lv_credit_total) = REDUCE wrbtr( INIT s = 0 FOR c IN <cl>-credit NEXT s = s + c-amount_in_company_code_ccy ).
        DATA(lv_gap) = abs( lv_debit_total + lv_credit_total ).
        IF lv_gap > lv_best_gap.
          lv_best_gap = lv_gap.
          lv_best_idx = sy-tabix.
        ENDIF.
      ENDLOOP.

      IF lv_best_idx = 0 AND rt_clusters IS NOT INITIAL.
        " No group is out of balance (or none found) - do not silently drop
        " the tax line's amount; attach it to the first group instead.
        lv_best_idx = 1.
      ENDIF.

      IF lv_best_idx > 0.
        IF ls_tax-debit_credit_code = c_debit.
          APPEND ls_tax TO rt_clusters[ lv_best_idx ]-debit.
        ELSE.
          APPEND ls_tax TO rt_clusters[ lv_best_idx ]-credit.
        ENDIF.
      ENDIF.
    ENDLOOP.

  ENDMETHOD.


  METHOD waterfall_allocate.

    IF it_debit IS INITIAL OR it_credit IS INITIAL.
      RETURN.
    ENDIF.

    DATA lt_debit  TYPE ty_raw_tab.
    DATA lt_credit TYPE ty_raw_tab.
    lt_debit  = it_debit.
    lt_credit = it_credit.

    " ASSUMPTION (ACDOCA sign convention): Debit amounts are stored positive,
    " Credit amounts negative. Sorting both DESCENDING therefore yields
    " "largest absolute amount first" for Debit and "smallest absolute
    " amount first" for Credit - i.e. the confirmed business rule "chia so
    " lon theo so nho, it phai chia nho nhat" (consume the bigger line using
    " the smaller ones first, to minimize the number of splits).
    SORT lt_debit  BY amount_in_company_code_ccy DESCENDING.
    SORT lt_credit BY amount_in_company_code_ccy DESCENDING.

    DATA(lv_di) = 1.
    DATA(lv_ci) = 1.
    DATA(lv_debit_rem_cc)  = lt_debit[ 1 ]-amount_in_company_code_ccy.
    DATA(lv_debit_rem_tc)  = lt_debit[ 1 ]-amount_in_transaction_ccy.
    DATA(lv_credit_rem_cc) = lt_credit[ 1 ]-amount_in_company_code_ccy.
    DATA(lv_credit_rem_tc) = lt_credit[ 1 ]-amount_in_transaction_ccy.

    WHILE lv_di <= lines( lt_debit ) AND lv_ci <= lines( lt_credit ).

      DATA(ls_row) = fill_common_fields( is_debit  = lt_debit[ lv_di ]
                                          is_credit = lt_credit[ lv_ci ] ).

      " Consume the smaller remaining absolute amount this round - that
      " side is fully closed out, the other side carries its remainder to
      " the next iteration (possibly matched against the NEXT line on the
      " side that just closed).
      DATA(lv_alloc_cc) = COND wrbtr( WHEN abs( lv_debit_rem_cc ) <= abs( lv_credit_rem_cc )
                                       THEN lv_debit_rem_cc
                                       ELSE 0 - lv_credit_rem_cc ).
      DATA(lv_alloc_tc) = COND wrbtr( WHEN abs( lv_debit_rem_cc ) <= abs( lv_credit_rem_cc )
                                       THEN lv_debit_rem_tc
                                       ELSE 0 - lv_credit_rem_tc ).

      ls_row-debit_amount_cc  = lv_alloc_cc.
      ls_row-debit_amount_tc  = lv_alloc_tc.
      ls_row-credit_amount_cc = 0 - lv_alloc_cc.
      ls_row-credit_amount_tc = 0 - lv_alloc_tc.

      APPEND ls_row TO rt_result.

      lv_debit_rem_cc  = lv_debit_rem_cc  - lv_alloc_cc.
      lv_debit_rem_tc  = lv_debit_rem_tc  - lv_alloc_tc.
      lv_credit_rem_cc = lv_credit_rem_cc + lv_alloc_cc.
      lv_credit_rem_tc = lv_credit_rem_tc + lv_alloc_tc.

      IF lv_debit_rem_cc = 0.
        lv_di = lv_di + 1.
        IF lv_di <= lines( lt_debit ).
          lv_debit_rem_cc = lt_debit[ lv_di ]-amount_in_company_code_ccy.
          lv_debit_rem_tc = lt_debit[ lv_di ]-amount_in_transaction_ccy.
        ENDIF.
      ENDIF.

      IF lv_credit_rem_cc = 0.
        lv_ci = lv_ci + 1.
        IF lv_ci <= lines( lt_credit ).
          lv_credit_rem_cc = lt_credit[ lv_ci ]-amount_in_company_code_ccy.
          lv_credit_rem_tc = lt_credit[ lv_ci ]-amount_in_transaction_ccy.
        ENDIF.
      ENDIF.

    ENDWHILE.

  ENDMETHOD.


  METHOD fill_common_fields.

    rs_row-company_code              = is_debit-company_code.
    rs_row-fiscal_year                = is_debit-fiscal_year.
    rs_row-accounting_document        = is_debit-accounting_document.
    rs_row-journal_entry               = is_debit-accounting_document.
    rs_row-debit_journal_entry_item    = is_debit-ledger_gl_line_item.
    rs_row-credit_journal_entry_item   = is_credit-ledger_gl_line_item.

    rs_row-debit_gl_account            = is_debit-gl_account.
    rs_row-credit_gl_account           = is_credit-gl_account.
    rs_row-debit_code                  = is_debit-debit_credit_code.
    rs_row-credit_code                 = is_credit-debit_credit_code.

    " FS #1 "Status": derived from clearing info (ClearingDate /
    " ClearingAccountingDocument). ASSUMPTION: taken from the Debit line;
    " clearing status is tracked per GL line item and could in principle
    " differ between the debit and credit side of the same document -
    " confirm with the FS author whether that's possible/relevant.
    rs_row-status = COND #( WHEN is_debit-clearing_date IS NOT INITIAL
                               OR is_debit-clearing_accounting_document IS NOT INITIAL
                             THEN c_status_cleared
                             ELSE c_status_open ).

    " TODO VERIFY: FS lists "So chung tu" as a separate output field (#2)
    " from "Journal Entry" (#9) and from "Document Reference ID" (#4) - the
    " exact distinct source is unclear from the FS text; defaulted here to
    " Document Reference ID as the closest candidate.
    rs_row-document_number             = is_debit-document_reference_id.
    rs_row-invoice_date                = is_debit-document_date.
    rs_row-document_reference_id       = is_debit-document_reference_id.
    rs_row-customer                    = is_debit-customer.
    rs_row-supplier                    = is_debit-supplier.
    rs_row-fixed_asset                 = is_debit-fixed_asset.
    rs_row-item_text                   = is_debit-item_text.
    rs_row-journal_entry_type          = is_debit-accounting_document_type.
    rs_row-posting_date                = is_debit-posting_date.
    " TODO VERIFY: "Journal Entry Date" vs "Posting Date" vs "Ngay hoa don"
    " (Document Date) are three separate FS fields (#3, #12, #13) - confirm
    " which source date each one really is; document_date is reused twice
    " below as a placeholder.
    rs_row-journal_entry_date          = is_debit-document_date.

    rs_row-company_code_currency       = is_debit-company_code_currency.
    rs_row-transaction_currency        = is_debit-transaction_currency.

    " --- FS fields 25/26: Quantity / Don gia (unit price) -------------------
    " NOTE: not prorated when a line's amount is split across several
    " output rows (see class doc) - a known simplification.
    IF is_debit-quantity IS NOT INITIAL.
      rs_row-quantity             = is_debit-quantity.
      rs_row-base_unit_of_measure = is_debit-base_unit_of_measure.
      rs_row-unit_price           = is_debit-amount_in_company_code_ccy / is_debit-quantity.
    ELSEIF is_credit-quantity IS NOT INITIAL.
      rs_row-quantity             = is_credit-quantity.
      rs_row-base_unit_of_measure = is_credit-base_unit_of_measure.
      rs_row-unit_price           = is_credit-amount_in_company_code_ccy / is_credit-quantity.
    ELSE.
      rs_row-quantity   = 0.
      rs_row-unit_price = 0.
    ENDIF.

    rs_row-tax_code            = is_debit-tax_code.
    rs_row-tax_amount          = is_debit-tax_amount.
    rs_row-product             = is_debit-product.
    rs_row-cost_center         = is_debit-cost_center.
    rs_row-profit_center       = is_debit-profit_center.

    " FS #35 "Is Reversed": taken from the confirmed IsReversed field.
    rs_row-is_reversed         = is_debit-is_reversed.

    " FS #36 "Is Reversing": no directly-confirmed boolean field for "this
    " document reverses another one". Derived here as "a ReverseDocument
    " reference exists and this document itself was NOT the one reversed" -
    " ASSUMPTION, direction of ReverseDocument needs confirming in ADT
    " against real reversed/reversing document pairs.
    rs_row-is_reversing        = COND #( WHEN is_debit-reverse_document IS NOT INITIAL
                                            AND is_debit-is_reversed = abap_false
                                          THEN abap_true ELSE abap_false ).

    " company_name / address / account_assignment are left blank here - the
    " FS's source fields for these are not part of I_GLAccountLineItem and
    " need an extra text/BP-address lookup; see README "Known gaps".

  ENDMETHOD.

ENDCLASS.
