"! Query provider class for the ZGL08_ChungTuGhiSo custom entity.
"!
"! Implements the FS's core business rule (section 2.2, TH1/TH2/TH3): for
"! each Journal Entry, debit and credit line items are paired into output
"! rows, with whichever side has FEWER lines getting its shown amount
"! derived as -1 * the paired line on the other (more itemized) side.
"!
"! IMPORTANT - things you must verify/adjust against your own system before
"! this compiles and runs (I have no live connection to your SAP system):
"!   1. Field names of I_GLAccountLineItem used in read_line_items() - marked
"!      "TODO VERIFY" wherever uncertain. Open the view in ADT (F2/Data
"!      Preview) and adjust the SELECT's field list accordingly.
"!   2. The exact IF_RAP_QUERY_PROVIDER / IF_RAP_QUERY_REQUEST method
"!      signatures below (paging, response object creation) can differ
"!      slightly by release. If activation fails on those calls, regenerate
"!      this class's skeleton via ADT ("New Behavior Definition" wizard for
"!      a Custom Entity) for your exact release, then drop the business
"!      logic methods (read_line_items / combine_debit_credit /
"!      fill_common_fields) into it unchanged.
"!   3. The row-cardinality assumptions documented in combine_debit_credit()
"!      for the n1=n2 case and the general n1<>n2 (both >1) case are NOT
"!      explicitly stated in the FS - confirm with the FS author using real
"!      sample documents before go-live.
CLASS zbp_gl08_chungtughiso DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    INTERFACES if_rap_query_provider.

  PRIVATE SECTION.
    TYPES:
      "! One row as read from I_GLAccountLineItem (one row per GL line item,
      "! i.e. BEFORE debit/credit pairing). TODO VERIFY every field name.
      BEGIN OF ty_raw,
        company_code               TYPE bukrs,
        fiscal_year                 TYPE gjahr,
        accounting_document         TYPE belnr_d,
        journal_entry_item          TYPE docln6,
        gl_account                  TYPE saknr,
        debit_credit_code           TYPE shkzg,
        posting_date                TYPE budat,
        document_date               TYPE bldat,
        creation_date_time          TYPE cpudt,
        created_by_user             TYPE usnam,
        accounting_document_type    TYPE blart,
        amount_in_company_code_ccy  TYPE wrbtr,
        company_code_currency       TYPE waers,
        amount_in_transaction_ccy   TYPE wrbtr,
        transaction_currency        TYPE waers,
        document_reference_id       TYPE xblnr1,
        customer                    TYPE kunnr,
        supplier                    TYPE lifnr,
        fixed_asset                 TYPE anln1,
        item_text                   TYPE sgtxt,
        quantity                    TYPE menge_d,
        base_unit_of_measure        TYPE meins,
        tax_code                    TYPE mwskz,
        tax_amount                  TYPE wmwst,
        product                     TYPE matnr,
        cost_center                 TYPE kostl,
        profit_center               TYPE prctr,
        is_reversed                 TYPE abap_boolean,
        is_reversing                TYPE abap_boolean,
        status                      TYPE char1,
      END OF ty_raw.
    TYPES ty_raw_tab TYPE STANDARD TABLE OF ty_raw WITH EMPTY KEY.
    TYPES ty_result_tab TYPE STANDARD TABLE OF zc_gl08_chungtughiso WITH EMPTY KEY.

    CONSTANTS c_debit  TYPE shkzg VALUE 'S'.
    CONSTANTS c_credit TYPE shkzg VALUE 'H'.

    METHODS read_line_items
      IMPORTING
        io_request    TYPE REF TO if_rap_query_request
      RETURNING
        VALUE(rt_raw) TYPE ty_raw_tab
      RAISING
        cx_rap_query_provider.

    "! Pairs one document's debit lines against its credit lines per FS
    "! rules TH1/TH2/TH3 (amount sign-flip only - see class doc for the
    "! row-cardinality assumptions in the n1=n2 and general n1<>n2 cases).
    METHODS combine_debit_credit
      IMPORTING
        it_debit         TYPE ty_raw_tab
        it_credit        TYPE ty_raw_tab
      RETURNING
        VALUE(rt_result) TYPE ty_result_tab.

    "! Fills every output field that does NOT depend on the TH1/TH2/TH3
    "! amount derivation (references, texts, quantity/unit price, ...).
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
    SORT lt_raw BY company_code fiscal_year accounting_document journal_entry_item ASCENDING.

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
      " columns, which get sign-flipped/derived per TH1-TH3 and would
      " double count if simply summed in the UI footer).
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
    " Reversing filters only make sense AFTER TH1/TH2/TH3 pairing (they are
    " not properties of a single I_GLAccountLineItem row) - apply those as
    " an extra FILTER on rt_raw/lt_result if the business needs them pushed
    " down; small, isolated extension point.

    SELECT FROM i_glaccountlineitem                              "#EC CI_NOORDER
      FIELDS
        companycode                AS company_code,
        fiscalyear                  AS fiscal_year,
        accountingdocument           AS accounting_document,
        glaccountlineitem            AS journal_entry_item,        "TODO VERIFY
        glaccount                    AS gl_account,
        debitcreditcode              AS debit_credit_code,
        postingdate                  AS posting_date,
        documentdate                  AS document_date,             "TODO VERIFY: also used for "Journal Entry Date"?
        journalentrycreatedbyuser      AS created_by_user,           "TODO VERIFY field name
        accountingdocumenttype          AS accounting_document_type,
        amountincompanycodecurrency      AS amount_in_company_code_ccy,
        companycodecurrency                AS company_code_currency,
        amountintransactioncurrency          AS amount_in_transaction_ccy,
        transactioncurrency                    AS transaction_currency,
        documentreferenceid                      AS document_reference_id,
        customer                                   AS customer,
        supplier                                     AS supplier,
        fixedasset                                    AS fixed_asset,
        documentitemtext                                AS item_text,   "TODO VERIFY field name
        quantity                                          AS quantity,
        baseunit                                            AS base_unit_of_measure,
        taxcode                                               AS tax_code,
        taxamount                                               AS tax_amount,
        product                                                   AS product,   "TODO VERIFY: may be "material"
        costcenter                                                 AS cost_center,
        profitcenter                                                 AS profit_center
      WHERE
            companycode IN @lt_range_company_code
        AND postingdate IN @lt_range_posting_date
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

    " status / is_reversed / is_reversing / creation_date_time are left as
    " TODOs here (not wired into the SELECT above) - see README "Known gaps".

  ENDMETHOD.


  METHOD combine_debit_credit.

    DATA(n1) = lines( it_debit ).
    DATA(n2) = lines( it_credit ).

    IF n1 = 0 OR n2 = 0.
      " Document has only one side (e.g. a one-sided/statistical posting) -
      " the FS does not define pairing for this case, so it is skipped.
      RETURN.
    ENDIF.

    IF n1 = n2.
      " ASSUMPTION (the FS's TH1/TH2/TH3 only define n1=1<n2, n2=1<n1, and
      " n1<>n2 both >1 - it is silent on n1=n2): pair 1:1 in ascending item
      " order, both sides keep their OWN real amounts. CONFIRM with the FS
      " author before go-live.
      DO n1 TIMES.
        DATA(lv_idx) = sy-index.
        DATA(ls_row_eq) = fill_common_fields( is_debit  = it_debit[ lv_idx ]
                                               is_credit = it_credit[ lv_idx ] ).
        ls_row_eq-debit_amount_cc  = it_debit[ lv_idx ]-amount_in_company_code_ccy.
        ls_row_eq-credit_amount_cc = it_credit[ lv_idx ]-amount_in_company_code_ccy.
        ls_row_eq-debit_amount_tc  = it_debit[ lv_idx ]-amount_in_transaction_ccy.
        ls_row_eq-credit_amount_tc = it_credit[ lv_idx ]-amount_in_transaction_ccy.
        APPEND ls_row_eq TO rt_result.
      ENDDO.
      RETURN.
    ENDIF.

    " TH1 (n1=1,n2>1) / TH3's n1<n2 branch: credit lines are the "real"
    " itemized side, kept as-is; debit is derived per row as -1 * that row's
    " credit amount. TH2 (n2=1,n1>1) / TH3's n1>n2 branch: symmetric.
    "
    " ASSUMPTION for the general n1<>n2 (both >1) case: the FS states the
    " amount-override rule but does not spell out row cardinality. This is
    " the literal reading - a full cross join (n1 x n2 rows) of which
    " TH1/TH2 are the special cases where one side has exactly 1 line.
    " CONFIRM with the FS author using real sample documents; watch out for
    " row-count explosion on documents with many lines on both sides.
    IF n1 < n2.
      LOOP AT it_debit INTO DATA(ls_debit).
        LOOP AT it_credit INTO DATA(ls_credit).
          DATA(ls_row_lt) = fill_common_fields( is_debit = ls_debit is_credit = ls_credit ).
          ls_row_lt-credit_amount_cc = ls_credit-amount_in_company_code_ccy.
          ls_row_lt-credit_amount_tc = ls_credit-amount_in_transaction_ccy.
          ls_row_lt-debit_amount_cc  = ls_credit-amount_in_company_code_ccy * -1.
          ls_row_lt-debit_amount_tc  = ls_credit-amount_in_transaction_ccy * -1.
          APPEND ls_row_lt TO rt_result.
        ENDLOOP.
      ENDLOOP.
    ELSE. " n1 > n2
      LOOP AT it_debit INTO ls_debit.
        LOOP AT it_credit INTO ls_credit.
          DATA(ls_row_gt) = fill_common_fields( is_debit = ls_debit is_credit = ls_credit ).
          ls_row_gt-debit_amount_cc  = ls_debit-amount_in_company_code_ccy.
          ls_row_gt-debit_amount_tc  = ls_debit-amount_in_transaction_ccy.
          ls_row_gt-credit_amount_cc = ls_debit-amount_in_company_code_ccy * -1.
          ls_row_gt-credit_amount_tc = ls_debit-amount_in_transaction_ccy * -1.
          APPEND ls_row_gt TO rt_result.
        ENDLOOP.
      ENDLOOP.
    ENDIF.

  ENDMETHOD.


  METHOD fill_common_fields.

    rs_row-company_code              = is_debit-company_code.
    rs_row-fiscal_year                = is_debit-fiscal_year.
    rs_row-accounting_document        = is_debit-accounting_document.
    rs_row-journal_entry               = is_debit-accounting_document.
    rs_row-debit_journal_entry_item    = is_debit-journal_entry_item.
    rs_row-credit_journal_entry_item   = is_credit-journal_entry_item.

    rs_row-debit_gl_account            = is_debit-gl_account.
    rs_row-credit_gl_account           = is_credit-gl_account.
    rs_row-debit_code                  = is_debit-debit_credit_code.
    rs_row-credit_code                 = is_credit-debit_credit_code.

    rs_row-status                      = is_debit-status.
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
    IF is_debit-quantity IS NOT INITIAL.
      " Covers both TH3 ("both sides have quantity -> use Debit's data") and
      " the "only Debit has quantity" case - both use Debit's own numbers.
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
    rs_row-is_reversed         = is_debit-is_reversed.
    rs_row-is_reversing        = is_debit-is_reversing.

    " company_name / address / account_assignment are left blank here - the
    " FS's source fields for these are not part of I_GLAccountLineItem and
    " need an extra text/BP-address lookup; see README "Known gaps".

  ENDMETHOD.

ENDCLASS.
