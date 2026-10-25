// std.Result(T) — a value of type T, or an Error.
//
// `?` is the propagation sugar for it: if the value is an Error it is returned from
// the current function, otherwise the T is yielded. The error side is fixed to Error
// because that is QLang's only error carrier; a two-parameter form would only be
// needed if a second carrier ever existed.
//
// Annotating a binding with Result(T) is what makes a fallible value's type honest:
// the Ok case *is* a plain T (no wrapper, no allocation), the Err case is the
// existing Error, and consuming the T requires `?`.
let Result = (T) -> {
  let typeObject = { check: (v) -> isError(v) || T.check(v) };
  typeObject;
};

// std.Option(T) — a value of type T, or null. It is the nullable form, not
// Rust's nominal Option: `null` is also an ordinary value, so Option's `?`
// propagation is deliberately not enabled yet (see docs/rust-error-model.md).
// Error is not an Option; the Err side belongs to Result(T).
let Option = (T) -> {
  let typeObject = {
    check: (v) -> {
      if isError(v) { return false; };
      if v == null { return true; };
      T.check(v);
    }
  };
  typeObject;
};
