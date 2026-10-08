// Portable algorithms over the language's Array indexing and mutation operations.
let arrayArgument = (a, name) -> {
  if !AnyArray.check(a) { return std.Error.raise("TypeMismatch", name + " expects Array", null); };
  a;
};
let arrayIndex = (a, index) -> {
  if !Number.check(index) { return null; };
  let size = a.length;
  if index != index || index - index != 0 || index % 1 != 0 || index < -size || index >= size { return null; };
  if index < 0 { index = index + size; };
  index;
};
let arraySearch = (a, value) -> {
  let i = 0;
  while i < a.length {
    let candidate = a[i];
    if !isError(candidate) && candidate == value { return i; };
    i = i + 1;
  };
  -1;
};
let ArrayLibrary = {
  length: (a) -> { a = arrayArgument(a, "Array.length")?; a.length; },
  toString: (a) -> `${a}`,
  add: (a) -> {
    a = arrayArgument(a, "Array.add")?;
    (value) -> { a[a.length] = value; null; };
  },
  push: (a) -> {
    a = arrayArgument(a, "Array.push")?;
    (value) -> { a[a.length] = value; a.length; };
  },
  remove: (a) -> {
    a = arrayArgument(a, "Array.remove")?;
    (index) -> {
      let at = arrayIndex(a, index);
      if at != null { a.remove(at); };
      null;
    };
  },
  pop: (a) -> {
    a = arrayArgument(a, "Array.pop")?;
    () -> {
      let size = a.length;
      if size == 0 { return null; };
      let value = a[size - 1];
      a.remove(size - 1);
      value;
    };
  },
  get: (a) -> {
    a = arrayArgument(a, "Array.get")?;
    (index) -> {
      let at = arrayIndex(a, index);
      if at == null { return null; };
      a[at];
    };
  },
  at: (a, index) -> {
    a = arrayArgument(a, "Array.at")?;
    if !Number.check(index) { return std.Error.raise("TypeMismatch", "Array.at expects Number index", null); };
    a[index];
  },
  indexOf: (a) -> { a = arrayArgument(a, "Array.indexOf")?; (value) -> arraySearch(a, value); },
  includes: (a) -> { a = arrayArgument(a, "Array.includes")?; (value) -> arraySearch(a, value) >= 0; },
  join: (a) -> {
    a = arrayArgument(a, "Array.join")?;
    (separator) -> {
      if !String.check(separator) { separator = ","; };
      let out = ""; let i = 0;
      while i < a.length {
        if i > 0 { out = out + separator; };
        out = out + `${a[i]}`; i = i + 1;
      };
      out;
    };
  },
  reverse: (a) -> {
    a = arrayArgument(a, "Array.reverse")?;
    let out = []; let i = a.length;
    while i > 0 { i = i - 1; out[out.length] = a[i]; };
    out;
  },
  concat: (a) -> {
    a = arrayArgument(a, "Array.concat")?;
    (b) -> {
      b = arrayArgument(b, "Array.concat")?;
      let out = []; let i = 0;
      while i < a.length { out[out.length] = a[i]; i = i + 1; };
      i = 0;
      while i < b.length { out[out.length] = b[i]; i = i + 1; };
      out;
    };
  }
};
export ArrayLibrary;
