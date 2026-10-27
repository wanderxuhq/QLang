// QLang 版静态字符串校验(对应 native_link.py 的 ir_strings + validate)。
//
//   verify <elf> <ir> [<extra-ir> ...]
//
// 产物里的每个字符串盒都必须和 IR 里声明的字节一致:符号存在、header = {tag=2, size},
// buffer 指针由 R_AARCH64_RELATIVE 重定位填入、buffer 字节等于 IR 里的 c"..." 字面量。
// 全部用 std.Bytes 读 ELF(不依赖 readelf);IR 侧是纯文本扫描,不用正则。

let fail = (message) -> { assert(false, "verify: " + message); 1; };

// ---- 数字与文本工具 -----------------------------------------------------------
let isDigit = (c) -> c >= 48 && c <= 57;              // 仅用于 ASCII
let ascii = (text, index) -> std.String.codePointAt(text)(index);
let digitsFrom = (text, start) -> {
  let out = ""; let i = start;
  while i < text.length {
    let c = ascii(text, i);
    if !isDigit(c) { i = text.length; } else { out = out + std.String.toString(c - 48); i = i + 1; };
  };
  out;
};
let numberFromText = (text) -> {
  let value = 0; let i = 0;
  while i < text.length { value = value * 10 + (ascii(text, i) - 48); i = i + 1; };
  value;
};
let findFrom = (text, needle, start) -> {
  let n = needle.length; let i = start;
  while i + n <= text.length {
    let j = 0; let ok = true;
    while j < n { if ascii(text, i + j) != ascii(needle, j) { ok = false; j = n; } else { j = j + 1; }; };
    if ok { return i; };
    i = i + 1;
  };
  -1;
};

// ---- IR 扫描(按字节扫,不 split 成行:7MB 的 IR 会撑爆堆)------------------
let byteAt = (b, i) -> std.Bytes.byteAt(b, i);
let matchesAt = (b, at, literal) -> {
  let i = 0;
  while i < literal.length {
    if at + i >= std.Bytes.length(b) { return false; };
    if byteAt(b, at + i) != std.String.codePointAt(literal)(i) { return false; };
    i = i + 1;
  };
  true;
};
// 从 at 开始读连续数字,返回 {value, next}
let readInt = (b, at) -> {
  let value = 0; let i = at; let seen = false;
  while i < std.Bytes.length(b) {
    let c = byteAt(b, i);
    if !isDigit(c) { i = std.Bytes.length(b); } else { value = value * 10 + (c - 48); seen = true; i = i + 1; };
  };
  { value: value, seen: seen };
};
// 在 [at, end) 里找 byte 串
let findBytes = (b, at, literal) -> {
  let i = at; let n = std.Bytes.length(b);
  while i + literal.length <= n { if matchesAt(b, i, literal) { return i; }; i = i + 1; };
  -1;
};
let scanIr = (b, buffers, boxes) -> {
  let n = std.Bytes.length(b);
  let i = 0;
  while i < n {
    if byteAt(b, i) == 64 {
      let lineStart = i == 0 || byteAt(b, i - 1) == 10;
      if lineStart && matchesAt(b, i, "@.strbox") {
        let boxId = readInt(b, i + 8);
        let bufferAt = findBytes(b, i + 9, "@.str");
        if bufferAt >= 0 {
          let bufferId = readInt(b, bufferAt + 5);
          let lengthAt = findBytes(b, bufferAt, ", i64 ");
          let length = 0;
          if lengthAt >= 0 { length = readInt(b, lengthAt + 6).value; };
          boxes[".strbox" + std.String.toString(boxId.value)] = { buffer: bufferId.value, length: length };
        };
      } else if lineStart && matchesAt(b, i, "@.str") {
        let bufferId = readInt(b, i + 5);
        let quote = findBytes(b, i, "c\"");
        if quote >= 0 {
          // 字面量区是 \XX 交错的反斜杠转义:取这一段文本、去掉反斜杠,剩下的就是十六进制。
          // 逐个字节 toString 会得到十进制(踩过),整段 hex 再去 5c 会误伤数据里的 0x5c。
          let start = quote + 2; let end = start;
          while end < n && byteAt(b, end) != 34 { end = end + 1; };
          let region = std.Bytes.slice(b, start, end - start);
          // 大小写:std.Bytes.hex 是小写,IR 字面量保留原样,统一转小写再比。
          buffers[std.String.toString(bufferId.value)] = std.String.toLowerCase(std.String.replace(region)("\\")(""));
        };
      };
    };
    i = i + 1;
  };
  null;
};

// ---- ELF 解析 ---------------------------------------------------------------
let readElfHeader = (b) -> {
  if std.Bytes.length(b) < 64 { fail("file is too small to be ELF"); };
  if std.Bytes.hex(b, 0, 4) != "7f454c46" { fail("not an ELF file"); };
  if std.Bytes.byteAt(b, 4) != 2 { fail("expected ELF64"); };
  // e_shentsize/e_shnum/e_phentsize/e_phnum 都是 2 字节字段:用 u32 读再取低 16 位,
  // 否则会把相邻字段吞进来(踩过:shnum 变成 257 亿,循环直接吃光堆)。
  let short16 = (at) -> std.Bytes.u32(b, at) % 65536;
  { shoff: std.Bytes.u64(b, 40), shentsize: short16(58), shnum: short16(60),
    phoff: std.Bytes.u64(b, 32), phentsize: short16(54), phnum: short16(56) };
};
let sectionAt = (b, header, index) -> {
  let base = header.shoff + index * header.shentsize;
  { type: std.Bytes.u32(b, base + 4), address: std.Bytes.u64(b, base + 16),
    offset: std.Bytes.u64(b, base + 24), size: std.Bytes.u64(b, base + 32), link: std.Bytes.u32(b, base + 40) };
};
// 符号名以 ".strbox" 开头时,把后面的数字解析成 id(全程数字,不做字符转换)。
let symbolId = (b, nameAt, namesEnd) -> {
  let prefix = [46, 115, 116, 114, 98, 111, 120];      // ".strbox"
  let i = 0;
  while i < 7 { if nameAt + i >= namesEnd || std.Bytes.byteAt(b, nameAt + i) != prefix[i] { return -1; }; i = i + 1; };
  let id = 0; let p = nameAt + 7;
  while p < namesEnd {
    let c = std.Bytes.byteAt(b, p);
    if c == 0 { p = namesEnd; } else if !isDigit(c) { return -1; } else { id = id * 10 + (c - 48); p = p + 1; };
  };
  id;
};
let symbolTable = (b, sections) -> {
  let i = 0; let found = null;
  while i < sections.length {
    if sections[i].type == 2 { found = sections[i]; i = sections.length; } else { i = i + 1; };
  };
  if found == null { fail("ELF has no symbol table (validate before stripping)"); };
  let names = sections[found.link];
  let namesEnd = names.offset + names.size;
  let symbols = {}; let count = found.size / 24; let k = 0;
  while k < count {
    let at = found.offset + k * 24;
    let id = symbolId(b, names.offset + std.Bytes.u32(b, at), namesEnd);
    if id >= 0 { symbols[id] = { address: std.Bytes.u64(b, at + 8), size: std.Bytes.u64(b, at + 16) }; };
    k = k + 1;
  };
  symbols;
};
let relocations = (b, sections) -> {
  let map = {}; let i = 0;
  while i < sections.length {
    let section = sections[i];
    if section.type == 4 {
      let count = section.size / 24; let k = 0;
      while k < count {
        let at = section.offset + k * 24;
        if std.Bytes.u64(b, at + 8) == 1027 { map[std.String.toString(std.Bytes.u64(b, at))] = std.Bytes.u64(b, at + 16); };
        k = k + 1;
      };
    };
    i = i + 1;
  };
  map;
};
let loadSegments = (b, header) -> {
  let segments = []; let i = 0;
  while i < header.phnum {
    let base = header.phoff + i * header.phentsize;
    if std.Bytes.u32(b, base) == 1 {
      segments[segments.length] = { offset: std.Bytes.u64(b, base + 8), address: std.Bytes.u64(b, base + 16), size: std.Bytes.u64(b, base + 32) };
    };
    i = i + 1;
  };
  segments;
};
let fileOffsetOf = (segments, address) -> {
  let i = 0;
  while i < segments.length {
    let segment = segments[i];
    if address >= segment.address && address - segment.address < segment.size { return segment.offset + address - segment.address; };
    i = i + 1;
  };
  -1;
};

// ---- 主流程 -----------------------------------------------------------------
if args.length < 2 { fail("usage: verify <elf> <ir> [<extra-ir> ...]"); };
let elfPath = args[0];
let elf = std.Bytes.read(elfPath);
if isError(elf) { fail("cannot read " + elfPath); };
let header = readElfHeader(elf);
let sections = []; let si = 0;
while si < header.shnum { sections[si] = sectionAt(elf, header, si); si = si + 1; };
let symbols = symbolTable(elf, sections);
let relocs = relocations(elf, sections);
let segments = loadSegments(elf, header);

let buffers = {}; let boxes = {};
let ai = 1;
while ai < args.length {
  let irBytes = std.Bytes.read(args[ai]);
  if isError(irBytes) { fail("cannot read " + args[ai]); };
  scanIr(irBytes, buffers, boxes);
  ai = ai + 1;
};

let counted = 0;
let names = std.Object.keys(boxes);
let bi = 0;
while bi < names.length {
  let name = names[bi];
  let box = boxes[name];
  let id = numberFromText(digitsFrom(name, 7));   // ".strbox" 是 7 个字符
  let payload = buffers[box.buffer];
  if isError(payload) || payload == null { fail(name + ": IR string box has no buffer"); };
  let size = payload.length / 2;
  if size != box.length { fail(name + ": IR length does not match its bytes"); };
  let symbol = symbols[id];
  if isError(symbol) || symbol == null { fail(name + ": missing ELF symbol"); };
  let headerAt = fileOffsetOf(segments, symbol.address);
  if headerAt < 0 { fail(name + ": symbol address is not in a loadable segment"); };
  if std.Bytes.u64(elf, headerAt) != 2 { fail(name + ": string tag is not 2"); };
  if std.Bytes.u64(elf, headerAt + 16) != size { fail(name + ": string size does not match IR"); };
  let relocation = relocs[std.String.toString(symbol.address + 8)];
  let bufferAddress = 0;
  if isError(relocation) || relocation == null { bufferAddress = std.Bytes.u64(elf, headerAt + 8); } else { bufferAddress = relocation; };
  if bufferAddress == 0 { fail(name + ": null string-buffer pointer"); };
  let bufferAt = fileOffsetOf(segments, bufferAddress);
  if bufferAt < 0 { fail(name + ": string buffer is not in a loadable segment"); };
  if std.Bytes.hex(elf, bufferAt, size) != payload { fail(name + ": linked bytes do not match IR"); };
  counted = counted + 1;
  bi = bi + 1;
};
println("verify: " + std.String.toString(counted) + " static strings ok");
