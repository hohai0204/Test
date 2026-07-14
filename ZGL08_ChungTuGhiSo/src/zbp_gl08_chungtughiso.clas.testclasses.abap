"! ABAP Unit tests for the debit/credit pairing algorithm (v3: Offsetting
"! Account clustering + positional fallback + waterfall allocation),
"! independent of the database and the RAP query framework. Several of these
"! encode the exact real examples provided by the business during review -
"! run these first whenever the pairing logic changes.
CLASS zbp_gl08_chungtughiso DEFINITION LOCAL FRIENDS ltc_pairing.

CLASS ltc_pairing DEFINITION FOR TESTING
  DURATION SHORT
  RISK LEVEL HARMLESS
  FINAL.

  PRIVATE SECTION.
    DATA cut TYPE REF TO zbp_gl08_chungtughiso.

    METHODS setup.

    "! Real example #1 (no Offsetting Account data): 1 Debit line (300)
    "! against 2 Credit lines (100, 200) - falls back to positional
    "! grouping, then the waterfall reproduces the FS's TH1 result.
    METHODS fallback_one_debit_n_credit FOR TESTING RAISING cx_static_check.

    "! Real example #2 (business-provided screenshot): 2 Debit lines
    "! (6,000,000 / 400,000) and 2 Credit lines (4,400,000 / 2,000,000),
    "! linked via Offsetting Account (some pointing at the other side's G/L
    "! Account, some at the other side's Supplier) - expects the exact 3
    "! output rows confirmed by the business: 2,000,000 / 4,000,000 / 400,000.
    METHODS offsetting_account_waterfall_example FOR TESTING RAISING cx_static_check.

    "! is_linked() must match both by G/L Account and by Customer/Supplier
    "! (when the Offsetting Account holds a business partner number instead
    "! of a G/L account).
    METHODS is_linked_via_gl_account FOR TESTING RAISING cx_static_check.
    METHODS is_linked_via_supplier FOR TESTING RAISING cx_static_check.
    METHODS not_linked_when_no_match FOR TESTING RAISING cx_static_check.

    "! Positional fallback: a tax line with no Offsetting Account link gets
    "! reinserted into whichever group is furthest from balancing.
    METHODS fallback_reinserts_tax_line_into_short_group FOR TESTING RAISING cx_static_check.

    "! One-sided document (only debit or only credit lines): no rows.
    METHODS one_sided_document_is_skipped FOR TESTING RAISING cx_static_check.

    METHODS make_line
      IMPORTING
        item                TYPE docln6
        dc_code             TYPE shkzg
        amount_cc           TYPE wrbtr
        amount_tc           TYPE wrbtr OPTIONAL
        gl_account          TYPE saknr OPTIONAL
        offsetting_account  TYPE char10 OPTIONAL
        customer            TYPE kunnr OPTIONAL
        supplier            TYPE lifnr OPTIONAL
        tax_code            TYPE mwskz OPTIONAL
      RETURNING
        VALUE(line)         TYPE zbp_gl08_chungtughiso=>ty_raw.

ENDCLASS.


CLASS ltc_pairing IMPLEMENTATION.

  METHOD setup.
    cut = NEW zbp_gl08_chungtughiso( ).
  ENDMETHOD.

  METHOD make_line.
    line-ledger_gl_line_item         = item.
    line-debit_credit_code           = dc_code.
    line-amount_in_company_code_ccy  = amount_cc.
    line-amount_in_transaction_ccy   = COND #( WHEN amount_tc = 0 THEN amount_cc ELSE amount_tc ).
    line-gl_account                  = COND #( WHEN gl_account IS SUPPLIED THEN gl_account ELSE |ACC{ item }| ).
    line-offsetting_account          = offsetting_account.
    line-customer                    = customer.
    line-supplier                    = supplier.
    line-tax_code                    = tax_code.
  ENDMETHOD.

  METHOD fallback_one_debit_n_credit.

    " ACDOCA sign convention: Debit positive, Credit negative.
    DATA(lt_debit) = VALUE zbp_gl08_chungtughiso=>ty_raw_tab(
      ( make_line( item = 1 dc_code = 'S' amount_cc = '300.00' ) ) ).

    DATA(lt_credit) = VALUE zbp_gl08_chungtughiso=>ty_raw_tab(
      ( make_line( item = 2 dc_code = 'H' amount_cc = '-100.00' ) )
      ( make_line( item = 3 dc_code = 'H' amount_cc = '-200.00' ) ) ).

    DATA(lt_result) = cut->combine_debit_credit( it_debit = lt_debit it_credit = lt_credit ).

    cl_abap_unit_assert=>assert_equals( act = lines( lt_result ) exp = 2 ).

    " Waterfall sorts Credit descending (least-negative/smallest-abs first),
    " so -100 is consumed before -200.
    cl_abap_unit_assert=>assert_equals( act = lt_result[ 1 ]-credit_amount_cc exp = '-100.00' ).
    cl_abap_unit_assert=>assert_equals( act = lt_result[ 1 ]-debit_amount_cc  exp = '100.00' ).
    cl_abap_unit_assert=>assert_equals( act = lt_result[ 2 ]-credit_amount_cc exp = '-200.00' ).
    cl_abap_unit_assert=>assert_equals( act = lt_result[ 2 ]-debit_amount_cc  exp = '200.00' ).

  ENDMETHOD.

  METHOD offsetting_account_waterfall_example.

    " D1: G/L 3310999902 (TK GR/IR tien phi), 6,000,000, offsets to the
    " vendor (100272, zero-padded to 10 chars) - which is also the Supplier
    " tagged on C1/C2.
    DATA(ls_d1) = make_line( item = 2 dc_code = 'S' amount_cc = '6000000.00'
                              gl_account = '3310999902' offsetting_account = '0000100272' ).
    " D2: G/L 1331000001 (VAT), 400,000, same vendor offset.
    DATA(ls_d2) = make_line( item = 4 dc_code = 'S' amount_cc = '400000.00'
                              gl_account = '1331000001' offsetting_account = '0000100272'
                              tax_code = 'X' ).

    " C1: G/L 3310100001 (Phai tra nguoi ban), -4,400,000, offsets to D1's
    " own G/L account (3310999902); also tagged with Supplier 100272.
    DATA(ls_c1) = make_line( item = 1 dc_code = 'H' amount_cc = '-4400000.00'
                              gl_account = '3310100001' offsetting_account = '3310999902'
                              supplier = '0000100272' ).
    " C2: G/L 1520101001 (NVL chinh), -2,000,000, same offset to D1's account.
    DATA(ls_c2) = make_line( item = 3 dc_code = 'H' amount_cc = '-2000000.00'
                              gl_account = '1520101001' offsetting_account = '3310999902'
                              supplier = '0000100272' ).

    DATA(lt_result) = cut->combine_debit_credit(
      it_debit  = VALUE #( ( ls_d1 ) ( ls_d2 ) )
      it_credit = VALUE #( ( ls_c1 ) ( ls_c2 ) ) ).

    cl_abap_unit_assert=>assert_equals( act = lines( lt_result ) exp = 3 ).

    cl_abap_unit_assert=>assert_equals( act = lt_result[ 1 ]-debit_amount_cc  exp = '2000000.00' ).
    cl_abap_unit_assert=>assert_equals( act = lt_result[ 1 ]-credit_amount_cc exp = '-2000000.00' ).
    cl_abap_unit_assert=>assert_equals( act = lt_result[ 1 ]-credit_gl_account exp = '1520101001' ).

    cl_abap_unit_assert=>assert_equals( act = lt_result[ 2 ]-debit_amount_cc  exp = '4000000.00' ).
    cl_abap_unit_assert=>assert_equals( act = lt_result[ 2 ]-credit_amount_cc exp = '-4000000.00' ).
    cl_abap_unit_assert=>assert_equals( act = lt_result[ 2 ]-credit_gl_account exp = '3310100001' ).

    cl_abap_unit_assert=>assert_equals( act = lt_result[ 3 ]-debit_amount_cc  exp = '400000.00' ).
    cl_abap_unit_assert=>assert_equals( act = lt_result[ 3 ]-credit_amount_cc exp = '-400000.00' ).
    cl_abap_unit_assert=>assert_equals( act = lt_result[ 3 ]-debit_gl_account exp = '1331000001' ).
    cl_abap_unit_assert=>assert_equals( act = lt_result[ 3 ]-credit_gl_account exp = '3310100001' ).

  ENDMETHOD.

  METHOD is_linked_via_gl_account.
    DATA(ls_debit)  = make_line( item = 1 dc_code = 'S' amount_cc = '100.00'
                                  gl_account = '1000' offsetting_account = '2000' ).
    DATA(ls_credit) = make_line( item = 2 dc_code = 'H' amount_cc = '-100.00'
                                  gl_account = '2000' ).
    cl_abap_unit_assert=>assert_true( cut->is_linked( is_debit = ls_debit is_credit = ls_credit ) ).
  ENDMETHOD.

  METHOD is_linked_via_supplier.
    DATA(ls_debit)  = make_line( item = 1 dc_code = 'S' amount_cc = '100.00'
                                  gl_account = '1000' offsetting_account = '0000100272' ).
    DATA(ls_credit) = make_line( item = 2 dc_code = 'H' amount_cc = '-100.00'
                                  gl_account = '2000' supplier = '0000100272' ).
    cl_abap_unit_assert=>assert_true( cut->is_linked( is_debit = ls_debit is_credit = ls_credit ) ).
  ENDMETHOD.

  METHOD not_linked_when_no_match.
    DATA(ls_debit)  = make_line( item = 1 dc_code = 'S' amount_cc = '100.00'
                                  gl_account = '1000' offsetting_account = '9999' ).
    DATA(ls_credit) = make_line( item = 2 dc_code = 'H' amount_cc = '-100.00'
                                  gl_account = '2000' supplier = '0000100272' ).
    cl_abap_unit_assert=>assert_false( cut->is_linked( is_debit = ls_debit is_credit = ls_credit ) ).
  ENDMETHOD.

  METHOD fallback_reinserts_tax_line_into_short_group.

    " No Offsetting Account data at all -> pure positional fallback with TWO
    " groups. Document order: D1(1000), C1(-1000), D2(500), C2(-700),
    " D3(200,tax). Positional grouping (excluding the tax line D3) yields:
    "   group 1: debit=[D1=1000], credit=[C1=-1000]  -> already balanced
    "   group 2: debit=[D2=500],  credit=[C2=-700]   -> short by 200
    " The excluded tax line D3 (200) must be reinserted into group 2 (the
    " short one), not group 1 (already balanced) or an arbitrary group.
    DATA(lt_debit) = VALUE zbp_gl08_chungtughiso=>ty_raw_tab(
      ( make_line( item = 1 dc_code = 'S' amount_cc = '1000.00' ) )
      ( make_line( item = 3 dc_code = 'S' amount_cc = '500.00' ) )
      ( make_line( item = 5 dc_code = 'S' amount_cc = '200.00' tax_code = 'X' ) ) ).

    DATA(lt_credit) = VALUE zbp_gl08_chungtughiso=>ty_raw_tab(
      ( make_line( item = 2 dc_code = 'H' amount_cc = '-1000.00' ) )
      ( make_line( item = 4 dc_code = 'H' amount_cc = '-700.00' ) ) ).

    DATA(lt_result) = cut->combine_debit_credit( it_debit = lt_debit it_credit = lt_credit ).

    " Group 1 stays a single untouched pair (1000/-1000); group 2 becomes
    " [500,200] vs [-700], which the waterfall splits into 2 rows
    " (500 then 200) once the tax line tops it up to balance.
    DATA(lv_sum_debit) = REDUCE wrbtr( INIT s = 0 FOR r IN lt_result NEXT s = s + r-debit_amount_cc ).
    cl_abap_unit_assert=>assert_equals( act = lines( lt_result ) exp = 3 ).
    cl_abap_unit_assert=>assert_equals( act = lv_sum_debit exp = '1700.00' ).

    DATA(lv_has_200_row) = xsdbool( line_exists( lt_result[ table_line-debit_amount_cc = '200.00' ] ) ).
    cl_abap_unit_assert=>assert_true( lv_has_200_row ).

  ENDMETHOD.

  METHOD one_sided_document_is_skipped.

    DATA(lt_debit) = VALUE zbp_gl08_chungtughiso=>ty_raw_tab(
      ( make_line( item = 1 dc_code = 'S' amount_cc = '100.00' ) ) ).

    DATA(lt_result) = cut->combine_debit_credit( it_debit = lt_debit it_credit = VALUE #( ) ).

    cl_abap_unit_assert=>assert_initial( lt_result ).

  ENDMETHOD.

ENDCLASS.
