// Regenerate or verify stdlib/unicode_data.ql from the committed UCD 15.1.0
// files (third_party/ucd/15.1.0). This is the QLang replacement for
// stdlib/generate_unicode_tables.py; all parsing, packing and formatting run
// here, and the input SHA-256s come from `sh -c sha256sum` (same precedent as
// aot/link.ql and aot/stdlib_build.ql).
//
// Build (from the repo root):
//   target/tools/build aot/generate_unicode_tables.ql -o /tmp/gen_unicode \
//     --compiler target/selfhost/stage2 \
//     --stdlib-object target/stdlib/<key>/stdlib.o
//
//   /tmp/gen_unicode                     print the generated file to stdout
//   /tmp/gen_unicode --out <file>        write it to <file>
//   /tmp/gen_unicode --check             compare stdlib/unicode_data.ql; exit 0/1
//   /tmp/gen_unicode --check --table <f> compare another copy of the table
//   /tmp/gen_unicode --write             explicitly rewrite stdlib/unicode_data.ql
//   /tmp/gen_unicode --ucd-dir <dir>     read UCD from <dir>
//
// Nothing overwrites stdlib/unicode_data.ql unless --write (or an explicit
// --out) asks for it.

let fail = (message) -> {
  assert(false, "generate_unicode_tables: " + message);
  0;
};

let sourceNames = ["UnicodeData.txt", "SpecialCasing.txt", "DerivedCoreProperties.txt", "PropList.txt"];
// Pinned provenance: the generator refuses to run against different UCD bytes.
let expectedHashes = {
  "UnicodeData.txt": "2fc713e6a31a87c4850a37fe2caffa4218180fadb5de86b43a143ddb4581fb86",
  "SpecialCasing.txt": "55a477efd933a52cd27e6a9bf70265bb2d8814af31aab07767abc8eb421f27ef",
  "DerivedCoreProperties.txt": "f55d0db69123431a7317868725b1fcbf1eab6b265d756d1bd7f0f6d9f9ee108b",
  "PropList.txt": "05672956317b6296bc2ec3d6cef1f6452b57ff4f2efc6dc55b0a19277d5fcfd1"
};
let version = "15.1.0";
let defaultUcdDir = "third_party/ucd/15.1.0";
let defaultTable = "stdlib/unicode_data.ql";

let shQuote = (value) -> "'" + std.String.replace(value)("'")("'\\''") + "'";
let isBlankByte = (b) -> b == 32 || b == 9 || b == 13 || b == 10 || b == 12 || b == 11;
let trimAscii = (s) -> {
  let size = std.Bytes.length(s);
  let start = 0;
  let end = size;
  while start < end && isBlankByte(std.Bytes.byteAt(s, start)) { start = start + 1; };
  while end > start && isBlankByte(std.Bytes.byteAt(s, end - 1)) { end = end - 1; };
  if start == 0 && end == size { return s; };
  std.Bytes.slice(s, start, end - start);
};
// UCD inputs are ASCII; byte offsets keep the scanner linear and avoid one
// string allocation per character. Every separator used here is one ASCII byte,
// so a UTF-8 continuation byte can never be mistaken for a separator.
let splitFast = (s, separator) -> {
  let parts = [];
  let size = std.Bytes.length(s);
  let code = std.Bytes.byteAt(separator, 0);
  let start = 0;
  let i = 0;
  while i < size {
    if std.Bytes.byteAt(s, i) == code {
      parts[parts.length] = std.Bytes.slice(s, start, i - start);
      start = i + 1;
    };
    i = i + 1;
  };
  parts[parts.length] = std.Bytes.slice(s, start, size - start);
  parts;
};
let stripComment = (line) -> trimAscii(splitFast(line, "#")[0]);
let fieldsOf = (line) -> {
  let parts = splitFast(line, ";");
  let out = [];
  let i = 0;
  while i < parts.length { out[out.length] = trimAscii(parts[i]); i = i + 1; };
  out;
};
let hexByte = (b) -> {
  if b >= 48 && b <= 57 { return b - 48; };
  if b >= 65 && b <= 70 { return b - 55; };
  if b >= 97 && b <= 102 { return b - 87; };
  -1;
};
let hexValue = (s) -> {
  let size = std.Bytes.length(s);
  if size == 0 { fail("empty hexadecimal field"); };
  let value = 0;
  let i = 0;
  while i < size {
    let digit = hexByte(std.Bytes.byteAt(s, i));
    if digit < 0 { fail("bad hexadecimal field: " + s); };
    value = value * 16 + digit;
    i = i + 1;
  };
  value;
};
// UnicodeData's code-point and mapping fields are bare hex, so the hot parser
// reads them in place instead of slicing three strings per record.
let hexRange = (text, start, end) -> {
  if start == end { fail("empty hexadecimal field"); };
  let value = 0;
  let i = start;
  while i < end {
    let digit = hexByte(std.Bytes.byteAt(text, i));
    if digit < 0 { fail("bad hexadecimal field in UnicodeData.txt"); };
    value = value * 16 + digit;
    i = i + 1;
  };
  value;
};
let readSource = (path) -> {
  let text = std.fs.readFileText(path);
  if isError(text) { fail("cannot read " + path + ": " + text.message); };
  text;
};
// sha256sum gets all four inputs in one process; output order is argv order.
let hashInputs = (directory) -> {
  let command = "sha256sum";
  let i = 0;
  while i < sourceNames.length {
    command = command + " " + shQuote(directory + "/" + sourceNames[i]);
    i = i + 1;
  };
  let result = std.process.run(["sh", "-c", command]);
  if result.status != 0 { fail("sha256sum failed:\n" + result.stderr); };
  let hashes = [];
  let lines = splitFast(result.stdout, "\n");
  i = 0;
  while i < lines.length {
    let line = trimAscii(lines[i]);
    if line != "" {
      let parts = splitFast(line, " ");
      hashes[hashes.length] = parts[0];
    };
    i = i + 1;
  };
  if hashes.length != sourceNames.length {
    fail("sha256sum returned " + std.Number.toString(hashes.length) + " digests, expected " +
         std.Number.toString(sourceNames.length));
  };
  i = 0;
  while i < sourceNames.length {
    if hashes[i] != expectedHashes[sourceNames[i]] {
      fail("unexpected Unicode data: " + sourceNames[i] + " has SHA-256 " + hashes[i] +
           ", expected " + expectedHashes[sourceNames[i]]);
    };
    i = i + 1;
  };
  hashes;
};

// Mappings are keyed by the decimal code point so a slash-free string key is
// used on both sides; insertion order is irrelevant because we sort the key
// list before emitting.
let addMapping = (values, codePoints, cp, mapped) -> {
  let key = std.Number.toString(cp);
  if isError(values[key]) { codePoints[codePoints.length] = cp; };
  values[key] = mapped;
  null;
};
let parseCodePointList = (field) -> {
  let parts = splitFast(field, " ");
  let out = [];
  let i = 0;
  while i < parts.length {
    if parts[i] != "" { out[out.length] = hexValue(parts[i]); };
    i = i + 1;
  };
  out;
};

let copyRange = (a, start, end) -> {
  let out = [];
  let i = start;
  while i < end { out[out.length] = a[i]; i = i + 1; };
  out;
};
let mergeNumbers = (a, b) -> {
  let out = [];
  let i = 0;
  let j = 0;
  while i < a.length && j < b.length {
    if a[i] <= b[j] { out[out.length] = a[i]; i = i + 1; }
    else { out[out.length] = b[j]; j = j + 1; };
  };
  while i < a.length { out[out.length] = a[i]; i = i + 1; };
  while j < b.length { out[out.length] = b[j]; j = j + 1; };
  out;
};
let sortNumbers = (a) -> {
  if a.length <= 1 { return a; };
  let mid = (a.length - a.length % 2) / 2;
  mergeNumbers(sortNumbers(copyRange(a, 0, mid)), sortNumbers(copyRange(a, mid, a.length)));
};

// UnicodeData.txt is comment-free and has 15 semicolon fields; scanning it once
// and reading fields 0/12/13 in place is much cheaper than splitting all 15.
let parseUnicodeData = (text, upperValues, upperCps, lowerValues, lowerCps) -> {
  let size = std.Bytes.length(text);
  let start = 0;
  let field = 0;
  let cp = 0;
  let upperValue = -1;
  let lowerValue = -1;
  let i = 0;
  while i <= size {
    let b = 10;
    if i < size { b = std.Bytes.byteAt(text, i); };
    if b == 59 || b == 10 {
      let blank = b == 10 && field == 0 && i == start;
      if !blank {
        if field == 0 { cp = hexRange(text, start, i); }
        else if field == 12 { if i > start { upperValue = hexRange(text, start, i); }; }
        else if field == 13 { if i > start { lowerValue = hexRange(text, start, i); }; };
        if b == 10 {
          if field < 13 { fail("UnicodeData.txt: fewer than 14 fields"); };
          if upperValue >= 0 { addMapping(upperValues, upperCps, cp, [upperValue]); };
          if lowerValue >= 0 { addMapping(lowerValues, lowerCps, cp, [lowerValue]); };
          field = 0;
          cp = 0;
          upperValue = -1;
          lowerValue = -1;
          start = i + 1;
        } else {
          field = field + 1;
          start = i + 1;
        };
      } else {
        field = 0;
        start = i + 1;
      };
    };
    i = i + 1;
  };
  null;
};
let parseSpecialCasing = (text, upperValues, upperCps, lowerValues, lowerCps) -> {
  let lines = splitFast(text, "\n");
  let i = 0;
  while i < lines.length {
    let line = stripComment(lines[i]);
    if line != "" {
      let fields = fieldsOf(line);
      if fields.length < 5 { fail("SpecialCasing.txt: fewer than 5 fields: " + line); };
      // Field 4 empty == unconditional; locale/context rows are not implemented.
      if fields[4] == "" {
        let cp = hexValue(fields[0]);
        addMapping(lowerValues, lowerCps, cp, parseCodePointList(fields[1]));
        addMapping(upperValues, upperCps, cp, parseCodePointList(fields[3]));
      };
    };
    i = i + 1;
  };
  null;
};

let mappingChunks = (values, codePoints) -> {
  let sorted = sortNumbers(codePoints);
  let chunks = [];
  let chunk = "";
  let i = 0;
  while i < sorted.length {
    let cp = sorted[i];
    let mapped = values[std.Number.toString(cp)];
    if isError(mapped) { fail("missing mapping for code point " + std.Number.toString(cp)); };
    if mapped.length < 1 || mapped.length > 3 {
      fail("mapping for code point " + std.Number.toString(cp) + " has " +
           std.Number.toString(mapped.length) + " code points");
    };
    if !(mapped.length == 1 && mapped[0] == cp) {
      let record = std.String.fromCodePoint(cp);
      let j = 0;
      while j < mapped.length {
        record = record + std.String.fromCodePoint(mapped[j]);
        j = j + 1;
      };
      record = record + "|";
      if chunk.length + record.length > 128 {
        chunks[chunks.length] = chunk;
        chunk = "";
      };
      chunk = chunk + record;
    };
    i = i + 1;
  };
  if chunk != "" { chunks[chunks.length] = chunk; };
  chunks;
};

let rangeBounds = (field) -> {
  let size = std.Bytes.length(field);
  let dot = -1;
  let i = 0;
  while i + 1 < size {
    if std.Bytes.byteAt(field, i) == 46 && std.Bytes.byteAt(field, i + 1) == 46 {
      dot = i;
      i = size;
    } else { i = i + 1; };
  };
  if dot < 0 {
    let cp = hexValue(field);
    return [cp, cp];
  };
  [hexValue(std.Bytes.slice(field, 0, dot)),
   hexValue(std.Bytes.slice(field, dot + 2, size - dot - 2))];
};
// Parse the property-range files once; both DerivedCoreProperties selections
// (Cased, Case_Ignorable) then reuse the same rows. One pass over the bytes
// captures only fields 0/1 and drops `#` comments.
let parseRangeRows = (text) -> {
  let rows = [];
  let size = std.Bytes.length(text);
  let start = 0;
  let field = 0;
  let first = "";
  let property = "";
  let inComment = false;
  let i = 0;
  while i <= size {
    let b = 10;
    if i < size { b = std.Bytes.byteAt(text, i); };
    if b == 10 {
      if !inComment {
        if field == 0 { first = trimAscii(std.Bytes.slice(text, start, i - start)); }
        else if field == 1 { property = trimAscii(std.Bytes.slice(text, start, i - start)); };
      };
      if field >= 1 && property != "" {
        let bounds = rangeBounds(first);
        rows[rows.length] = { property: property, low: bounds[0], high: bounds[1] };
      };
      field = 0;
      first = "";
      property = "";
      inComment = false;
      start = i + 1;
    } else if !inComment && b == 35 {
      if field == 0 { first = trimAscii(std.Bytes.slice(text, start, i - start)); }
      else if field == 1 { property = trimAscii(std.Bytes.slice(text, start, i - start)); };
      inComment = true;
    } else if !inComment && b == 59 {
      if field == 0 { first = trimAscii(std.Bytes.slice(text, start, i - start)); }
      else if field == 1 { property = trimAscii(std.Bytes.slice(text, start, i - start)); };
      field = field + 1;
      start = i + 1;
    };
    i = i + 1;
  };
  rows;
};
// Ranges are ascending in UCD order; expand them and cut the concatenation
// every 128 scalars, exactly like the Python generator.
let propertyChunks = (rows, property) -> {
  let chunks = [];
  let chunk = "";
  let i = 0;
  while i < rows.length {
    if rows[i].property == property {
      let cp = rows[i].low;
      let high = rows[i].high;
      while cp <= high {
        chunk = chunk + std.String.fromCodePoint(cp);
        if chunk.length == 128 {
          chunks[chunks.length] = chunk;
          chunk = "";
        };
        cp = cp + 1;
      };
    };
    i = i + 1;
  };
  if chunk != "" { chunks[chunks.length] = chunk; };
  chunks;
};

let lowerHex = "0123456789abcdef";
let hex4 = (cp) -> {
  let digits = [];
  let value = cp;
  let k = 0;
  while k < 4 {
    let d = value % 16;
    digits[k] = lowerHex[d];
    value = (value - d) / 16;
    k = k + 1;
  };
  digits[3] + digits[2] + digits[1] + digits[0];
};
// Python's json.dumps(ensure_ascii=False): quote/backslash and only the five
// short control escapes; every other code point below 0x20 becomes \u00xx.
let jsonEscape = (cp) -> {
  if cp == 8 { return "\\b"; };
  if cp == 9 { return "\\t"; };
  if cp == 10 { return "\\n"; };
  if cp == 12 { return "\\f"; };
  if cp == 13 { return "\\r"; };
  "\\u" + hex4(cp);
};
let quoteJson = (s) -> {
  let out = "\"";
  let i = 0;
  while i < s.length {
    let c = s[i];
    let cp = std.String.codePointAt(s)(i);
    if c == "\"" { out = out + "\\\""; }
    else if c == "\\" { out = out + "\\\\"; }
    else if cp < 32 { out = out + jsonEscape(cp); }
    else { out = out + c; };
    i = i + 1;
  };
  out + "\"";
};
let jsonSection = (name, chunks) -> {
  let out = "  \"" + name + "\": [\n";
  let i = 0;
  while i < chunks.length {
    out = out + "    " + quoteJson(chunks[i]);
    if i + 1 < chunks.length { out = out + ","; };
    out = out + "\n";
    i = i + 1;
  };
  out + "  ]";
};

let clip = (s) -> {
  if s.length <= 160 { return s; };
  let out = "";
  let i = 0;
  while i < 160 { out = out + s[i]; i = i + 1; };
  out + "... (" + std.Number.toString(s.length) + " chars)";
};
let absolute = (n) -> { if n < 0 { -n; } else { n; }; };
let describeDifference = (expected, generated) -> {
  let want = splitFast(expected, "\n");
  let have = splitFast(generated, "\n");
  let limit = want.length;
  if have.length < limit { limit = have.length; };
  let report = "";
  let differences = 0;
  let shown = 0;
  let i = 0;
  while i < limit {
    if want[i] != have[i] {
      differences = differences + 1;
      if shown < 8 {
        report = report + "line " + std.Number.toString(i + 1) + ":\n" +
                 "  unicode_data.ql: " + clip(want[i]) + "\n" +
                 "  generator:      " + clip(have[i]) + "\n";
        shown = shown + 1;
      };
    };
    i = i + 1;
  };
  if want.length != have.length {
    report = report + "line count: unicode_data.ql has " + std.Number.toString(want.length) +
             ", generator has " + std.Number.toString(have.length) + "\n";
    differences = differences + absolute(want.length - have.length);
  };
  report + std.Number.toString(differences) + " differing line(s)";
};

let check = false;
let write = false;
let ucdDir = defaultUcdDir;
let tablePath = defaultTable;
let outPath = "";
let ai = 0;
while ai < args.length {
  let arg = args[ai];
  if arg == "--check" { check = true; }
  else if arg == "--write" { write = true; }
  else if arg == "--ucd-dir" {
    ai = ai + 1;
    if ai >= args.length { fail("--ucd-dir needs a path"); };
    ucdDir = args[ai];
  }
  else if arg == "--table" {
    ai = ai + 1;
    if ai >= args.length { fail("--table needs a path"); };
    tablePath = args[ai];
  }
  else if arg == "--out" {
    ai = ai + 1;
    if ai >= args.length { fail("--out needs a path"); };
    outPath = args[ai];
  }
  else { fail("unknown argument: " + arg); };
  ai = ai + 1;
};
if write {
  if outPath != "" && outPath != tablePath {
    fail("--write and --out name different destinations");
  };
  outPath = tablePath;
};
if check && outPath != "" { fail("--check does not write output"); };

let hashes = hashInputs(ucdDir);
let upperValues = {};
let lowerValues = {};
let upperCps = [];
let lowerCps = [];
let unicodeDataText = readSource(ucdDir + "/UnicodeData.txt");
let specialCasingText = readSource(ucdDir + "/SpecialCasing.txt");
let derivedText = readSource(ucdDir + "/DerivedCoreProperties.txt");
let propListText = readSource(ucdDir + "/PropList.txt");

parseUnicodeData(unicodeDataText, upperValues, upperCps, lowerValues, lowerCps);
parseSpecialCasing(specialCasingText, upperValues, upperCps, lowerValues, lowerCps);

let upperChunks = mappingChunks(upperValues, upperCps);
let lowerChunks = mappingChunks(lowerValues, lowerCps);
let derivedRows = parseRangeRows(derivedText);
let propListRows = parseRangeRows(propListText);
let casedChunks = propertyChunks(derivedRows, "Cased");
let ignorableChunks = propertyChunks(derivedRows, "Case_Ignorable");
let spaceChunks = propertyChunks(propListRows, "White_Space");

// The first line keeps the historical `.py` spelling on purpose: it is part of
// stdlib/unicode_data.ql today and --check compares bytes, not just structures.
let generated = "// Generated Unicode 15.1.0 data. Regenerate with generate_unicode_tables.ql.\n";
generated = generated + "// Unicode copyright Unicode, Inc.; see unicode-LICENSE.txt.\n";
let hi = 0;
while hi < sourceNames.length {
  generated = generated + "// " + sourceNames[hi] + " SHA-256 " + hashes[hi] + "\n";
  hi = hi + 1;
};
generated = generated + "let unicodeData = {\n";
generated = generated + "  \"version\": \"" + version + "\",\n";
generated = generated + jsonSection("upper", upperChunks) + ",\n";
generated = generated + jsonSection("lower", lowerChunks) + ",\n";
generated = generated + jsonSection("cased", casedChunks) + ",\n";
generated = generated + jsonSection("ignorable", ignorableChunks) + ",\n";
generated = generated + jsonSection("space", spaceChunks) + "\n";
generated = generated + "};\nexport unicodeData;\n";

if check {
  let expected = readSource(tablePath);
  if generated != expected {
    fail("Unicode tables are stale (" + tablePath + "):\n" + describeDifference(expected, generated));
  };
  println("Unicode 15.1 data verified");
} else if outPath != "" {
  let written = std.fs.writeText(outPath, generated);
  if isError(written) { fail("cannot write " + outPath + ": " + written.message); };
  println("Unicode 15.1 data generated: " + outPath);
} else {
  print(generated);
};
0;
