(*
  This file is part of scilla.

  Copyright (c) 2018 - present Zilliqa Research Pvt. Ltd.
  
  scilla is free software: you can redistribute it and/or modify it under the
  terms of the GNU General Public License as published by the Free Software
  Foundation, either version 3 of the License, or (at your option) any later
  version.
 
  scilla is distributed in the hope that it will be useful, but WITHOUT ANY
  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
  A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
 
  You should have received a copy of the GNU General Public License along with
  scilla.  If not, see <http://www.gnu.org/licenses/>.
*)

open Core_kernel
open! Int.Replace_polymorphic_compare
open TestUtil

let () =
  run_tests
    [
      TestBech32.all_tests;
      TestInteger256.all_tests;
      TestParser.all_tests;
      TestSafeArith.all_tests;
      TestSignatures.all_tests;
      TestSnark.all_tests;
      TestSyntax.all_tests;
      (* TestPolynomial.all_tests; *)
    ]
