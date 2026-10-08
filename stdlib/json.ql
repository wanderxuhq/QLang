// JSON.stringify implemented in ordinary QLang; object-key reflection and
// numeric text formatting remain existing injected dependencies.
import ./json_quote.ql;
import ./number.ql;

// JSON.parse in ordinary QLang. Only the string indexing/length and
// fromCodePoint construction mechanisms come from the runtime; the parser,
// escape decoding, surrogate validation and error handling live here.
let jsonState = (source) -> {
  let state = { source: source, cpAt: std.String.codePointAt(source), at: 0, size: source.length, failed: false };
  state;
};
let jsonFail = (st) -> { st.failed = true; null; };
let jsonPeek = (st) -> { if st.at < st.size { st.cpAt(st.at); } else { -1; }; };
let jsonAdvance = (st) -> { st.at = st.at + 1; };
let jsonTake = (st, byte) -> { if jsonPeek(st) == byte { jsonAdvance(st); true; } else { false; }; };
let jsonSpace = (st) -> {
  let c = jsonPeek(st);
  while c == 32 || c == 10 || c == 13 || c == 9 { jsonAdvance(st); c = jsonPeek(st); };
};
let jsonDigit = (c) -> c >= 48 && c <= 57;
let jsonHex = (st) -> {
  let n = 0; let k = 0;
  while k < 4 {
    let c = jsonPeek(st); let d = -1;
    if c >= 48 && c <= 57 { d = c - 48; }
    else if c >= 65 && c <= 70 { d = c - 55; }
    else if c >= 97 && c <= 102 { d = c - 87; };
    if d < 0 { jsonFail(st); return 0; };
    n = n * 16 + d; jsonAdvance(st); k = k + 1;
  };
  n;
};
let jsonString = (st) -> {
  if !jsonTake(st, 34) { return jsonFail(st); };
  let out = "";
  while true {
    let c = jsonPeek(st);
    if c < 32 { return jsonFail(st); };
    jsonAdvance(st);
    if c == 34 { return out; };
    if c == 92 {
      let e = jsonPeek(st); jsonAdvance(st);
      if e == 34 || e == 92 || e == 47 { out = out + std.String.fromCodePoint(e); }
      else if e == 98 { out = out + std.String.fromCodePoint(8); }
      else if e == 102 { out = out + std.String.fromCodePoint(12); }
      else if e == 110 { out = out + std.String.fromCodePoint(10); }
      else if e == 114 { out = out + std.String.fromCodePoint(13); }
      else if e == 116 { out = out + std.String.fromCodePoint(9); }
      else if e == 117 {
        let cp = jsonHex(st);
        if st.failed { return null; };
        if cp >= 55296 && cp <= 56319 {
          if !jsonTake(st, 92) || !jsonTake(st, 117) { return jsonFail(st); };
          let low = jsonHex(st);
          if st.failed { return null; };
          if low < 56320 || low > 57343 { return jsonFail(st); };
          cp = 65536 + (cp - 55296) * 1024 + low - 56320;
        } else if cp >= 56320 && cp <= 57343 { return jsonFail(st); };
        out = out + std.String.fromCodePoint(cp);
      } else { return jsonFail(st); };
    } else {
      out = out + st.source[st.at - 1];
    };
  };
};
let jsonLiteral = (st, text, value) -> {
  let code = std.String.codePointAt(text);
  let k = 0;
  while k < text.length {
    if !jsonTake(st, code(k)) { return jsonFail(st); };
    k = k + 1;
  };
  value;
};
let jsonNumber = (st) -> {
  let start = st.at;
  jsonTake(st, 45);
  if !jsonTake(st, 48) {
    if !jsonDigit(jsonPeek(st)) { return jsonFail(st); };
    while jsonDigit(jsonPeek(st)) { jsonAdvance(st); };
  };
  if jsonTake(st, 46) {
    if !jsonDigit(jsonPeek(st)) { return jsonFail(st); };
    while jsonDigit(jsonPeek(st)) { jsonAdvance(st); };
  };
  if jsonTake(st, 101) || jsonTake(st, 69) {
    let negativeExp = jsonTake(st, 45);
    if !negativeExp { jsonTake(st, 43); };
    if !jsonDigit(jsonPeek(st)) { return jsonFail(st); };
    while jsonDigit(jsonPeek(st)) { jsonAdvance(st); };
  };
  let text = ""; let k = start;
  while k < st.at { text = text + st.source[k]; k = k + 1; };
  NumberLibrary.parseFloat(text);
};
let jsonValue = (st, depth) -> {
  if depth > 128 { return jsonFail(st); };
  jsonSpace(st);
  let c = jsonPeek(st);
  if c == 34 { return jsonString(st); };
  if c == 110 { return jsonLiteral(st, "null", null); };
  if c == 116 { return jsonLiteral(st, "true", true); };
  if c == 102 { return jsonLiteral(st, "false", false); };
  if c == 45 || jsonDigit(c) { return jsonNumber(st); };
  if c == 91 {
    jsonAdvance(st); jsonSpace(st);
    let a = [];
    if jsonTake(st, 93) { return a; };
    while true {
      let v = jsonValue(st, depth + 1);
      if st.failed { return null; };
      a[a.length] = v;
      jsonSpace(st);
      if jsonTake(st, 93) { return a; };
      if !jsonTake(st, 44) { return jsonFail(st); };
    };
  };
  if c == 123 {
    jsonAdvance(st); jsonSpace(st);
    let o = {};
    if jsonTake(st, 125) { return o; };
    while true {
      jsonSpace(st);
      let key = jsonString(st);
      if st.failed { return null; };
      jsonSpace(st);
      if !jsonTake(st, 58) { return jsonFail(st); };
      let v = jsonValue(st, depth + 1);
      if st.failed { return null; };
      o[key] = v;
      jsonSpace(st);
      if jsonTake(st, 125) { return o; };
      if !jsonTake(st, 44) { return jsonFail(st); };
    };
  };
  jsonFail(st);
};
let jsonParse = (source) -> {
  if !String.check(source) { return std.Error.raise("TypeMismatch", "JSON.parse expects String", null); };
  let st = jsonState(source);
  let value = jsonValue(st, 0);
  jsonSpace(st);
  if st.failed || st.at != st.size {
    return std.Error.raise("TypeMismatch", "cannot apply JSON.parse to " + source + " and valid JSON", null);
  };
  value;
};

let makeJSON = (enumerateKeys, numberToString, numberIsFinite) -> {
  let stringify = (root) -> {
    // Each value lives inside a non-Error holder. This lets container-stored
    // Errors travel through the ordinary call boundary as data and encode null.
    let frames = [{
      kind: "value",
      holder: { value: root },
      depth: 0
    }];
    let output = "";

    // Iterative depth-first walk. Frames hold the current container, depth,
    // index and object keys; no recursive QLang stringify call is made.
    while frames.length > 0 {
      let last = frames.length - 1;
      let frame = frames[last];

      if frame.kind == "value" {
        frames.remove(last);
        let value = frame.holder.value;
        let depth = frame.depth;
        if depth > 128 {
          return std.Error.raise("TypeMismatch", "JSON.stringify nesting too deep", null);
        };

        if isError(value) {
          output = output + "null";
        } else if Null.check(value) {
          output = output + "null";
        } else if Number.check(value) {
          if numberIsFinite(value) {
            output = output + numberToString(value);
          } else {
            output = output + "null";
          };
        } else if Boolean.check(value) {
          if value { output = output + "true"; }
          else { output = output + "false"; };
        } else if String.check(value) {
          output = output + quoteJsonString(value);
        } else if AnyArray.check(value) || AnyObject.check(value) || std.Type.check(value) {
          if AnyArray.check(value) {
            output = output + "[";
            frames[frames.length] = {
              kind: "array",
              holder: { value: value },
              depth: depth,
              index: 0,
              length: value.length
            };
          } else {
            let keys = enumerateKeys(value);
            output = output + "{";
            frames[frames.length] = {
              kind: "object",
              holder: { value: value },
              keys: keys,
              depth: depth,
              index: 0,
              length: keys.length
            };
          };
        } else {
          // Functions and values outside JSON's existing scalar/container set.
          output = output + "null";
        };
      } else if frame.kind == "array" {
        if frame.index >= frame.length {
          output = output + "]";
          frames.remove(last);
        } else {
          if frame.index > 0 { output = output + ","; };
          let index = frame.index;
          frame.index = index + 1;
          let child = frame.holder.value[index];
          frames[frames.length] = {
            kind: "value",
            holder: { value: child },
            depth: frame.depth + 1
          };
        };
      } else {
        if frame.index >= frame.length {
          output = output + "}";
          frames.remove(last);
        } else {
          if frame.index > 0 { output = output + ","; };
          let index = frame.index;
          frame.index = index + 1;
          let key = frame.keys[index];
          let child = frame.holder.value[key];
          output = output + quoteJsonString(key) + ":";
          frames[frames.length] = {
            kind: "value",
            holder: { value: child },
            depth: frame.depth + 1
          };
        };
      };
    };

    output;
  };

  { stringify: stringify, parse: jsonParse };
};

let JSONLibrary = makeJSON(std.Object.keys, std.Number.toString, NumberLibrary.isFinite);
export { JSONLibrary };
