[%%import
"/src/config.mlh"]

open Core_kernel

[%%ifdef
consensus_mechanism]

open Snark_bits
open Bitstring_lib
open Snark_params
open Tick
open Let_syntax

[%%else]

open Snark_bits_nonconsensus
module Unsigned_extended = Unsigned_extended_nonconsensus.Unsigned_extended

[%%endif]

open Intf
module Signed_poly = Signed_poly

type uint64 = Unsigned.uint64

module Make (Unsigned : sig
  include Unsigned_extended.S

  val to_uint64 : t -> uint64

  val of_uint64 : uint64 -> t
end) (M : sig
  val length : int
end) : sig
  [%%ifdef consensus_mechanism]

  include S with type t = Unsigned.t and type var = Boolean.var list

  val var_of_bits : Boolean.var Bitstring.Lsb_first.t -> var

  val unpack_var : Field.Var.t -> (var, _) Tick.Checked.t

  val pack_var : var -> Field.Var.t

  [%%else]

  include S with type t = Unsigned.t

  [%%endif]
end = struct
  let max_int = Unsigned.max_int

  let length_in_bits = M.length

  type t = Unsigned.t [@@deriving sexp, compare, hash]

  module Arg = struct
    type typ = t [@@deriving sexp, hash, compare]

    type t = typ [@@deriving sexp, hash, compare]

    [%%define_locally
    Unsigned.(of_int, to_int)]
  end

  include Codable.Make_of_int (Arg)
  include Hashable.Make (Arg)
  include Comparable.Make (Arg)

  [%%define_locally
  Unsigned.(to_uint64, of_uint64, of_int, to_int, of_string, to_string)]

  let gen_incl a b : t Quickcheck.Generator.t =
    let a = Bignum_bigint.of_string Unsigned.(to_string a) in
    let b = Bignum_bigint.of_string Unsigned.(to_string b) in
    Quickcheck.Generator.map
      Bignum_bigint.(gen_incl a b)
      ~f:(fun n -> of_string (Bignum_bigint.to_string n))

  let gen : t Quickcheck.Generator.t =
    let m = Bignum_bigint.of_string Unsigned.(to_string max_int) in
    Quickcheck.Generator.map
      Bignum_bigint.(gen_incl zero m)
      ~f:(fun n -> of_string (Bignum_bigint.to_string n))

  module Vector = struct
    include M
    include Unsigned

    let empty = zero

    let get t i = Infix.((t lsr i) land one = one)

    let set v i b =
      if b then Infix.(v lor (one lsl i))
      else Infix.(v land lognot (one lsl i))
  end

  include (
    Bits.Vector.Make (Vector) : Bits_intf.Convertible_bits with type t := t)

  [%%ifdef
  consensus_mechanism]

  include Bits.Snarkable.Small_bit_vector (Tick) (Vector)
  include Unpacked

  let var_to_number t = Number.of_bits (var_to_bits t :> Boolean.var list)

  let var_to_input t =
    Random_oracle.Input.bitstring (var_to_bits t :> Boolean.var list)

  let var_of_bits (bits : Boolean.var Bitstring.Lsb_first.t) : var =
    let bits = (bits :> Boolean.var list) in
    let n = List.length bits in
    assert (Int.( <= ) n M.length) ;
    let padding = M.length - n in
    bits @ List.init padding ~f:(fun _ -> Boolean.false_)

  let var_of_t t =
    List.init M.length ~f:(fun i -> Boolean.var_of_value (Vector.get t i))

  let if_ cond ~then_ ~else_ =
    Field.Checked.if_ cond ~then_:(pack_var then_) ~else_:(pack_var else_)
    >>= unpack_var

  [%%endif]

  let zero = Unsigned.zero

  let one = Unsigned.one

  let sub x y = if x < y then None else Some (Unsigned.sub x y)

  let add x y =
    let z = Unsigned.add x y in
    if z < x then None else Some z

  let ( + ) = add

  let ( - ) = sub

  type magnitude = t [@@deriving sexp, hash, compare, yojson]

  let to_input t = Random_oracle.Input.bitstring @@ to_bits t

  module Signed = struct
    type ('magnitude, 'sgn) typ = ('magnitude, 'sgn) Signed_poly.t =
      {magnitude: 'magnitude; sgn: 'sgn}
    [@@deriving sexp, hash, compare, yojson]

    type t = (Unsigned.t, Sgn.t) Signed_poly.t
    [@@deriving sexp, hash, compare, eq, yojson]

    type magnitude = Unsigned.t [@@deriving sexp, compare]

    let create ~magnitude ~sgn = {magnitude; sgn}

    let sgn {sgn; _} = sgn

    let magnitude {magnitude; _} = magnitude

    let zero = create ~magnitude:zero ~sgn:Sgn.Pos

    let gen =
      Quickcheck.Generator.map2 gen Sgn.gen ~f:(fun magnitude sgn ->
          create ~magnitude ~sgn )

    let sgn_to_bool = function Sgn.Pos -> true | Neg -> false

    let to_bits ({sgn; magnitude} : t) = sgn_to_bool sgn :: to_bits magnitude

    let to_input t = Random_oracle.Input.bitstring (to_bits t)

    let add (x : t) (y : t) : t option =
      match (x.sgn, y.sgn) with
      | Neg, (Neg as sgn) | Pos, (Pos as sgn) ->
          let open Option.Let_syntax in
          let%map magnitude = add x.magnitude y.magnitude in
          create ~sgn ~magnitude
      | Pos, Neg | Neg, Pos ->
          let c = compare_magnitude x.magnitude y.magnitude in
          Some
            ( if Int.( < ) c 0 then
              create ~sgn:y.sgn
                ~magnitude:Unsigned.Infix.(y.magnitude - x.magnitude)
            else if Int.( > ) c 0 then
              create ~sgn:x.sgn
                ~magnitude:Unsigned.Infix.(x.magnitude - y.magnitude)
            else zero )

    let negate t = {t with sgn= Sgn.negate t.sgn}

    let of_unsigned magnitude = create ~magnitude ~sgn:Sgn.Pos

    let ( + ) = add

    [%%ifdef
    consensus_mechanism]

    type nonrec var = (var, Sgn.var) Signed_poly.t

    let of_hlist : (unit, 'a -> 'b -> unit) Snarky.H_list.t -> ('a, 'b) typ =
      Snarky.H_list.(fun [magnitude; sgn] -> {magnitude; sgn})

    let to_hlist {magnitude; sgn} = Snarky.H_list.[magnitude; sgn]

    let typ =
      Typ.of_hlistable [typ; Sgn.typ] ~var_to_hlist:to_hlist
        ~var_of_hlist:of_hlist ~value_to_hlist:to_hlist
        ~value_of_hlist:of_hlist

    module Checked = struct
      let to_bits {magnitude; sgn} =
        Sgn.Checked.is_pos sgn :: (var_to_bits magnitude :> Boolean.var list)

      let to_input t = Random_oracle.Input.bitstring (to_bits t)

      let constant {magnitude; sgn} =
        {magnitude= var_of_t magnitude; sgn= Sgn.Checked.constant sgn}

      let of_unsigned magnitude = {magnitude; sgn= Sgn.Checked.pos}

      let if_ cond ~then_ ~else_ =
        let%map sgn = Sgn.Checked.if_ cond ~then_:then_.sgn ~else_:else_.sgn
        and magnitude =
          if_ cond ~then_:then_.magnitude ~else_:else_.magnitude
        in
        {sgn; magnitude}

      let to_field_var ({magnitude; sgn} : var) =
        Field.Checked.mul (pack_var magnitude) (sgn :> Field.Var.t)

      let add (x : var) (y : var) =
        let%bind xv = to_field_var x and yv = to_field_var y in
        let%bind sgn =
          exists Sgn.typ
            ~compute:
              (let open As_prover in
              let%map x = read typ x and y = read typ y in
              (Option.value_exn (add x y)).sgn)
        in
        let%bind res =
          Tick.Field.Checked.mul (sgn :> Field.Var.t) (Field.Var.add xv yv)
        in
        let%map magnitude = unpack_var res in
        {magnitude; sgn}

      let ( + ) = add

      let cswap_field (b : Boolean.var) (x, y) =
        (* (x + b(y - x), y + b(x - y)) *)
        let open Field.Checked in
        let%map b_y_minus_x =
          Tick.Field.Checked.mul (b :> Field.Var.t) (y - x)
        in
        (x + b_y_minus_x, y - b_y_minus_x)

      let cswap b (x, y) =
        let l_sgn, r_sgn =
          match (x.sgn, y.sgn) with
          | Sgn.Pos, Sgn.Pos ->
              Sgn.Checked.(pos, pos)
          | Neg, Neg ->
              Sgn.Checked.(neg, neg)
          | Pos, Neg ->
              (Sgn.Checked.neg_if_true b, Sgn.Checked.pos_if_true b)
          | Neg, Pos ->
              (Sgn.Checked.pos_if_true b, Sgn.Checked.neg_if_true b)
        in
        let%map l_mag, r_mag =
          let%bind l, r =
            cswap_field b (pack_var x.magnitude, pack_var y.magnitude)
          in
          let%map l = unpack_var l and r = unpack_var r in
          (l, r)
        in
        ({sgn= l_sgn; magnitude= l_mag}, {sgn= r_sgn; magnitude= r_mag})
    end

    [%%endif]
  end

  [%%ifdef
  consensus_mechanism]

  module Checked = struct
    let if_ = if_

    let if_value cond ~then_ ~else_ : var =
      List.init M.length ~f:(fun i ->
          match (Vector.get then_ i, Vector.get else_ i) with
          | true, true ->
              Boolean.true_
          | false, false ->
              Boolean.false_
          | true, false ->
              cond
          | false, true ->
              Boolean.not cond )

    (* Unpacking protects against underflow *)
    let sub (x : Unpacked.var) (y : Unpacked.var) =
      unpack_var (Field.Var.sub (pack_var x) (pack_var y))

    let sub_flagged x y =
      let z = Field.Var.sub (pack_var x) (pack_var y) in
      let%map bits, `Success no_underflow =
        Field.Checked.unpack_flagged z ~length:length_in_bits
      in
      (bits, `Underflow (Boolean.not no_underflow))

    (* Unpacking protects against overflow *)
    let add (x : Unpacked.var) (y : Unpacked.var) =
      unpack_var (Field.Var.add (pack_var x) (pack_var y))

    let add_flagged x y =
      let z = Field.Var.add (pack_var x) (pack_var y) in
      let%map bits, `Success no_overflow =
        Field.Checked.unpack_flagged z ~length:length_in_bits
      in
      (bits, `Overflow (Boolean.not no_overflow))

    let ( - ) = sub

    let ( + ) = add

    let add_signed (t : var) (d : Signed.var) =
      let%bind d = Signed.Checked.to_field_var d in
      Field.Var.add (pack_var t) d |> unpack_var

    let%test_module "currency_test" =
      ( module struct
        let expect_failure err c =
          if Or_error.is_ok (check c ()) then failwith err

        let expect_success err c =
          match check c () with
          | Ok () ->
              ()
          | Error e ->
              Error.(raise (tag ~tag:err e))

        let to_bigint x = Bignum_bigint.of_string (Unsigned.to_string x)

        let of_bigint x = Unsigned.of_string (Bignum_bigint.to_string x)

        let gen_incl x y =
          Quickcheck.Generator.map ~f:of_bigint
            (Bignum_bigint.gen_incl (to_bigint x) (to_bigint y))

        (* TODO: When we do something to make snarks run fast for tests, increase the trials *)
        let qc_test_fast = Quickcheck.test ~trials:100

        let%test_unit "subtraction_completeness" =
          let generator =
            let open Quickcheck.Generator.Let_syntax in
            let%bind x = gen_incl Unsigned.zero Unsigned.max_int in
            let%map y = gen_incl Unsigned.zero x in
            (x, y)
          in
          qc_test_fast generator ~f:(fun (lo, hi) ->
              expect_success
                (sprintf !"subtraction: lo=%{Unsigned} hi=%{Unsigned}" lo hi)
                (var_of_t lo - var_of_t hi) )

        let%test_unit "subtraction_soundness" =
          let generator =
            let open Quickcheck.Generator.Let_syntax in
            let%bind x = gen_incl Unsigned.zero Unsigned.(sub max_int one) in
            let%map y = gen_incl Unsigned.(add x one) Unsigned.max_int in
            (x, y)
          in
          qc_test_fast generator ~f:(fun (lo, hi) ->
              expect_failure
                (sprintf !"underflow: lo=%{Unsigned} hi=%{Unsigned}" lo hi)
                (var_of_t lo - var_of_t hi) )

        let%test_unit "addition_completeness" =
          let generator =
            let open Quickcheck.Generator.Let_syntax in
            let%bind x = gen_incl Unsigned.zero Unsigned.max_int in
            let%map y = gen_incl Unsigned.zero Unsigned.(sub max_int x) in
            (x, y)
          in
          qc_test_fast generator ~f:(fun (x, y) ->
              expect_success
                (sprintf !"overflow: x=%{Unsigned} y=%{Unsigned}" x y)
                (var_of_t x + var_of_t y) )

        let%test_unit "addition_soundness" =
          let generator =
            let open Quickcheck.Generator.Let_syntax in
            let%bind x = gen_incl Unsigned.one Unsigned.max_int in
            let%map y =
              gen_incl Unsigned.(add (sub max_int x) one) Unsigned.max_int
            in
            (x, y)
          in
          qc_test_fast generator ~f:(fun (x, y) ->
              expect_failure
                (sprintf !"overflow: x=%{Unsigned} y=%{Unsigned}" x y)
                (var_of_t x + var_of_t y) )
      end )
  end

  [%%endif]
end

let currency_length = 64

module Fee = struct
  [%%versioned
  module Stable = struct
    module V1 = struct
      type t = Unsigned_extended.UInt64.Stable.V1.t
      [@@deriving sexp, compare, hash, eq, yojson]

      let to_latest = Fn.id
    end
  end]

  module T =
    Make
      (Unsigned_extended.UInt64)
      (struct
        let length = currency_length
      end)

  include T

  type _unused = unit constraint Signed.t = (t, Sgn.t) Signed_poly.t

  include Codable.Make_of_int (T)
end

module Amount = struct
  [%%versioned
  module Stable = struct
    module V1 = struct
      type t = Unsigned_extended.UInt64.Stable.V1.t
      [@@deriving sexp, compare, hash, eq, yojson]

      let to_latest = Fn.id
    end
  end]

  module T =
    Make
      (Unsigned_extended.UInt64)
      (struct
        let length = currency_length
      end)

  [%%ifdef
  consensus_mechanism]

  include (
    T :
      module type of T
      with type var = T.var
       and module Signed = T.Signed
       and module Checked := T.Checked )

  [%%else]

  include (T : module type of T with module Signed = T.Signed)

  [%%endif]

  include Codable.Make_of_int (T)

  let of_fee (fee : Fee.t) : t = fee

  let to_fee (fee : t) : Fee.t = fee

  let add_fee (t : t) (fee : Fee.t) = add t (of_fee fee)

  [%%ifdef
  consensus_mechanism]

  module Checked = struct
    include T.Checked

    let of_fee (fee : Fee.var) : var = fee

    let to_fee (t : var) : Fee.var = t

    let add_fee (t : var) (fee : Fee.var) =
      Tick.Field.Var.add (pack_var t) (Fee.pack_var fee) |> unpack_var
  end

  [%%endif]
end

module Balance = struct
  [%%versioned
  module Stable = struct
    module V1 = struct
      type t = Amount.Stable.V1.t [@@deriving sexp, compare, hash, yojson, eq]

      let to_latest = Fn.id
    end
  end]

  [%%ifdef
  consensus_mechanism]

  include (Amount : Basic with type t = Amount.t with type var = Amount.var)

  [%%else]

  include (Amount : Basic with type t = Amount.t)

  [%%endif]

  let to_amount = Fn.id

  let add_amount = Amount.add

  let sub_amount = Amount.sub

  let ( + ) = add_amount

  let ( - ) = sub_amount

  [%%ifdef
  consensus_mechanism]

  module Checked = struct
    let add_signed_amount = Amount.Checked.add_signed

    let add_amount = Amount.Checked.add

    let sub_amount = Amount.Checked.sub

    let ( + ) = add_amount

    let ( - ) = sub_amount

    let if_ = Amount.Checked.if_
  end

  [%%endif]
end

let%test_module "sub_flagged module" =
  ( module struct
    [%%ifdef
    consensus_mechanism]

    open Tick

    module type Sub_flagged_S = sig
      type t

      type magnitude = t [@@deriving sexp, compare]

      type var = field Snarky.Cvar.t Snarky.Boolean.t list

      val zero : t

      val ( - ) : t -> t -> t option

      val typ : (var, t) Typ.t

      val gen : t Quickcheck.Generator.t

      module Checked : sig
        val sub_flagged :
          var -> var -> (var * [`Underflow of Boolean.var], 'a) Tick.Checked.t
      end
    end

    let run_test (module M : Sub_flagged_S) =
      let open M in
      let sub_flagged_unchecked (x, y) =
        if x < y then (zero, true) else (Option.value_exn (x - y), false)
      in
      let sub_flagged_checked =
        let f (x, y) =
          Snarky.Checked.map (M.Checked.sub_flagged x y)
            ~f:(fun (r, `Underflow u) -> (r, u))
        in
        Test_util.checked_to_unchecked (Typ.tuple2 typ typ)
          (Typ.tuple2 typ Boolean.typ)
          f
      in
      Quickcheck.test ~trials:100 (Quickcheck.Generator.tuple2 gen gen)
        ~f:(fun p ->
          let m, u = sub_flagged_unchecked p in
          let m_checked, u_checked = sub_flagged_checked p in
          assert (Bool.equal u u_checked) ;
          if not u then [%test_eq: M.magnitude] m m_checked )

    let%test_unit "fee sub_flagged" = run_test (module Fee)

    let%test_unit "amount sub_flagged" = run_test (module Amount)

    [%%endif]
  end )
