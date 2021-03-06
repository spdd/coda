(* fake_accounts.ml -- generate fake accounts for testnet *)

open Core_kernel
open Signature_lib

let make_account pk balance =
  Functor.Without_private.{pk; balance; delegate= None}

let balance_gen = Quickcheck.Generator.of_list (List.range 10 500)

let gen =
  let open Quickcheck.Let_syntax in
  let%bind balance = balance_gen in
  let%map pk = Public_key.Compressed.gen in
  make_account pk balance
