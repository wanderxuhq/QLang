// Internal portable candidate. Not installed in std.JSON.
// The table preserves the existing AOT JSON encoder's escape choices.
let jsonControlEscapes = [
  ["\u0000", "\\u0000"], ["\u0001", "\\u0001"],
  ["\u0002", "\\u0002"], ["\u0003", "\\u0003"],
  ["\u0004", "\\u0004"], ["\u0005", "\\u0005"],
  ["\u0006", "\\u0006"], ["\u0007", "\\u0007"],
  ["\u0008", "\\u0008"], ["\t", "\\t"],
  ["\n", "\\n"], ["\u000b", "\\u000b"],
  ["\u000c", "\\u000c"], ["\r", "\\r"],
  ["\u000e", "\\u000e"], ["\u000f", "\\u000f"],
  ["\u0010", "\\u0010"], ["\u0011", "\\u0011"],
  ["\u0012", "\\u0012"], ["\u0013", "\\u0013"],
  ["\u0014", "\\u0014"], ["\u0015", "\\u0015"],
  ["\u0016", "\\u0016"], ["\u0017", "\\u0017"],
  ["\u0018", "\\u0018"], ["\u0019", "\\u0019"],
  ["\u001a", "\\u001a"], ["\u001b", "\\u001b"],
  ["\u001c", "\\u001c"], ["\u001d", "\\u001d"],
  ["\u001e", "\\u001e"], ["\u001f", "\\u001f"]
];

let quoteJsonString = (value) -> {
  if !String.check(value) {
    return std.Error.raise("TypeMismatch", "JSON string quote expects String", null);
  };
  let out = "\"";
  let i = 0;
  while i < value.length {
    let character = value[i];
    if character == "\"" || character == "\\" {
      out = out + "\\" + character;
    } else {
      let escaped = character;
      let j = 0;
      while j < jsonControlEscapes.length {
        let entry = jsonControlEscapes[j];
        if character == entry[0] { escaped = entry[1]; };
        j = j + 1;
      };
      out = out + escaped;
    };
    i = i + 1;
  };
  out + "\"";
};

export quoteJsonString;
