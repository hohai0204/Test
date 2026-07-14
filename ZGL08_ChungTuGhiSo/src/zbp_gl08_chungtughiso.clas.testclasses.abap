"! ABAP Unit tests for the debit/credit pairing algorithm (TH1/TH2/TH3),
"! independent of the database and the RAP query framework. Run these first
"! whenever the pairing logic changes - they encode the FS's worked examples.
CLASS zbp_gl08_chungtughiso DEFINITION LOCAL FRIENDS ltc_pairing.

CLASS ltc_pairing DEFINITION FOR TESTING
  DURATION SHORT
  RISK LEVEL HARMLESS
  FINAL.

  PRIVATE SECTION.
    DATA cut TYPE REF TO zbp_gl08_chungtughiso.

    METHODS setup.

    "! FS TH1: 1 Debit, n Credit (n>1) - debit is broadcast against every
    "! credit line; debit amount is derived as -1 * that row's credit amount.
    METHODS th1_one_debit_n_credit FOR TESTING RAISING cx_static_check.

    "! FS TH2: n Debit, 1 Credit (n>1) - symmetric to TH1.
    METHODS th2_n_debit_one_credit FOR TESTING RAISING cx_static_check.

    "! Equal counts (n1=n2, not explicitly defined by the FS): 1:1 pairing,
    "! both sides keep their own real amounts.
    METHODS equal_counts_pass_through FOR TESTING RAISING cx_static_check.

    "! One-sided document (only debit or only credit lines): no rows are
    "! produced - the FS does not define pairing for this case.
    METHODS one_sided_document_is_skipped FOR TESTING RAISING cx_static_check.

    METHODS make_line
      IMPORTING
        item        TYPE docln6
        dc_code     TYPE shkzg
        amount_cc   TYPE wrbtr
        amount_tc   TYPE wrbtr DEFAULT 0
      RETURNING
        VALUE(line) TYPE zbp_gl08_chungtughiso=>ty_raw.

ENDCLASS.


CLASS ltc_pairing IMPLEMENTATION.

  METHOD setup.
    cut = NEW zbp_gl08_chungtughiso( ).
  ENDMETHOD.

  METHOD make_line.
    line-journal_entry_item         = item.
    line-debit_credit_code          = dc_code.
    line-amount_in_company_code_ccy = amount_cc.
    line-amount_in_transaction_ccy  = COND #( WHEN amount_tc = 0 THEN amount_cc ELSE amount_tc ).
    line-gl_account                 = |ACC{ item }|.
  ENDMETHOD.

  METHOD th1_one_debit_n_credit.

    DATA(lt_debit) = VALUE zbp_gl08_chungtughiso=>ty_raw_tab(
      ( make_line( item = 1 dc_code = 'S' amount_cc = '300.00' ) ) ).

    DATA(lt_credit) = VALUE zbp_gl08_chungtughiso=>ty_raw_tab(
      ( make_line( item = 1 dc_code = 'H' amount_cc = '100.00' ) )
      ( make_line( item = 2 dc_code = 'H' amount_cc = '200.00' ) ) ).

    DATA(lt_result) = cut->combine_debit_credit( it_debit = lt_debit it_credit = lt_credit ).

    cl_abap_unit_assert=>assert_equals( act = lines( lt_result ) exp = 2 ).

    cl_abap_unit_assert=>assert_equals( act = lt_result[ 1 ]-credit_amount_cc exp = '100.00' ).
    cl_abap_unit_assert=>assert_equals( act = lt_result[ 1 ]-debit_amount_cc  exp = '-100.00' ).
    cl_abap_unit_assert=>assert_equals( act = lt_result[ 2 ]-credit_amount_cc exp = '200.00' ).
    cl_abap_unit_assert=>assert_equals( act = lt_result[ 2 ]-debit_amount_cc  exp = '-200.00' ).

  ENDMETHOD.

  METHOD th2_n_debit_one_credit.

    DATA(lt_debit) = VALUE zbp_gl08_chungtughiso=>ty_raw_tab(
      ( make_line( item = 1 dc_code = 'S' amount_cc = '100.00' ) )
      ( make_line( item = 2 dc_code = 'S' amount_cc = '200.00' ) ) ).

    DATA(lt_credit) = VALUE zbp_gl08_chungtughiso=>ty_raw_tab(
      ( make_line( item = 1 dc_code = 'H' amount_cc = '300.00' ) ) ).

    DATA(lt_result) = cut->combine_debit_credit( it_debit = lt_debit it_credit = lt_credit ).

    cl_abap_unit_assert=>assert_equals( act = lines( lt_result ) exp = 2 ).

    cl_abap_unit_assert=>assert_equals( act = lt_result[ 1 ]-debit_amount_cc  exp = '100.00' ).
    cl_abap_unit_assert=>assert_equals( act = lt_result[ 1 ]-credit_amount_cc exp = '-100.00' ).
    cl_abap_unit_assert=>assert_equals( act = lt_result[ 2 ]-debit_amount_cc  exp = '200.00' ).
    cl_abap_unit_assert=>assert_equals( act = lt_result[ 2 ]-credit_amount_cc exp = '-200.00' ).

  ENDMETHOD.

  METHOD equal_counts_pass_through.

    DATA(lt_debit) = VALUE zbp_gl08_chungtughiso=>ty_raw_tab(
      ( make_line( item = 1 dc_code = 'S' amount_cc = '150.00' ) )
      ( make_line( item = 2 dc_code = 'S' amount_cc = '250.00' ) ) ).

    DATA(lt_credit) = VALUE zbp_gl08_chungtughiso=>ty_raw_tab(
      ( make_line( item = 1 dc_code = 'H' amount_cc = '150.00' ) )
      ( make_line( item = 2 dc_code = 'H' amount_cc = '250.00' ) ) ).

    DATA(lt_result) = cut->combine_debit_credit( it_debit = lt_debit it_credit = lt_credit ).

    cl_abap_unit_assert=>assert_equals( act = lines( lt_result ) exp = 2 ).
    cl_abap_unit_assert=>assert_equals( act = lt_result[ 1 ]-debit_amount_cc  exp = '150.00' ).
    cl_abap_unit_assert=>assert_equals( act = lt_result[ 1 ]-credit_amount_cc exp = '150.00' ).
    cl_abap_unit_assert=>assert_equals( act = lt_result[ 2 ]-debit_amount_cc  exp = '250.00' ).
    cl_abap_unit_assert=>assert_equals( act = lt_result[ 2 ]-credit_amount_cc exp = '250.00' ).

  ENDMETHOD.

  METHOD one_sided_document_is_skipped.

    DATA(lt_debit) = VALUE zbp_gl08_chungtughiso=>ty_raw_tab(
      ( make_line( item = 1 dc_code = 'S' amount_cc = '100.00' ) ) ).

    DATA(lt_result) = cut->combine_debit_credit( it_debit = lt_debit it_credit = VALUE #( ) ).

    cl_abap_unit_assert=>assert_initial( lt_result ).

  ENDMETHOD.

ENDCLASS.
