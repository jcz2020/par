let () =
  Alcotest.run "PAR Core" (
    Test_state_machine.suite @
    Test_expression.suite @
    Test_types.suite
  )
