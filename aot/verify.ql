// ELF 静态字符串校验(工具入口)。
//
//   verify <elf> <strings.tsv|-> [ir] [--lto]
//
// 字符串字节本身仍由 runtime 的 `std.Bytes.verifyStrings` 校验(一次跨边界调用);
// 这里补上 Python aot/native_link.py 会拒绝、而 runtime 版会放过或无法表达的结构检查:
//   - ELF64/AArch64 头:magic/class/data/version、e_type/e_machine/e_version、表尺寸;
//   - 所有头/段/节偏移不越过文件末尾;
//   - PT_DYNAMIC:拒绝 DT_REL/DT_RELR/压缩标签,DT_RELA 三元组必须自洽;
//   - PIE/shared(e_type=3)的每个 .strbox 必须有 loader 可见的
//     R_AARCH64_RELATIVE(1027),不再回退到头部里存的指针;
//   - 符号表:entsize 24、size%24==0、STT_OBJECT、st_size∈{24,48}、id 不重复、
//     不得出现 strings.tsv ∪ IR 之外的 .strbox(除非 --lto/relaxed)。
//
// 失败退出 1。
let fail = (message) -> { assert(false, "verify: " + message); 1; };

// ---- 安全读取(越界返回 -1,绝不让 runtime 的 Bytes 叶子先报错) ----------
let lengthOf = (b) -> { let n = std.Bytes.length(b); if isError(n) { -1; } else { n; }; };
let byteOr = (b, off) -> {
  let n = lengthOf(b);
  if off < 0 || off >= n { return -1; };
  let v = std.Bytes.byteAt(b, off);
  if isError(v) { -1; } else { v; };
};
let u16Or = (b, off) -> {
  let a = byteOr(b, off); let c = byteOr(b, off + 1);
  if a < 0 || c < 0 { return -1; };
  a + c * 256;
};
let u32Or = (b, off) -> {
  let a = byteOr(b, off); let c = byteOr(b, off + 1);
  let d = byteOr(b, off + 2); let e = byteOr(b, off + 3);
  if a < 0 || c < 0 || d < 0 || e < 0 { return -1; };
  a + c * 256 + d * 65536 + e * 16777216;
};
let u64Or = (b, off) -> {
  let n = lengthOf(b);
  if off < 0 || off + 8 > n { return -1; };
  let v = std.Bytes.u64(b, off);
  if isError(v) { -1; } else { v; };
};
let hexOr = (b, off, count) -> {
  let h = std.Bytes.hex(b, off, count);
  if isError(h) { ""; } else { h; };
};

// ".strbox" 的原始字节:46 115 116 114 98 111 120
let isStrboxAt = (b, off) -> {
  byteOr(b, off) == 46 && byteOr(b, off + 1) == 115 && byteOr(b, off + 2) == 116
    && byteOr(b, off + 3) == 114 && byteOr(b, off + 4) == 98
    && byteOr(b, off + 5) == 111 && byteOr(b, off + 6) == 120;
};
// 从 start 起连续十进制数字。{value, count, end}。
let digitsAt = (b, start) -> {
  let n = lengthOf(b);
  let value = 0; let count = 0; let p = start; let done = false;
  while p < n && !done {
    let c = byteOr(b, p);
    if c >= 48 && c <= 57 { value = value * 10 + (c - 48); count = count + 1; p = p + 1; }
    else { done = true; };
  };
  { value: value, count: count, end: start + count };
};

// strings.tsv 的行首 `.strboxN\t...`
let collectTsvIds = (b, into) -> {
  let n = lengthOf(b); let at = 0;
  while at < n {
    if byteOr(b, at) == 10 { at = at + 1; }
    else {
      if isStrboxAt(b, at) {
        let run = digitsAt(b, at + 7);
        if run.count > 0 && byteOr(b, at + 7 + run.count) == 9 {
          into[std.Number.toString(run.value)] = true;
        };
      };
      while at < n && byteOr(b, at) != 10 { at = at + 1; };
    };
  };
  null;
};
// IR 定义行 `@.strboxN = ...`
let collectIrIds = (b, into) -> {
  let n = lengthOf(b); let at = 0;
  while at < n {
    let lineStart = at == 0 || byteOr(b, at - 1) == 10;
    if lineStart && byteOr(b, at) == 64 && isStrboxAt(b, at + 1) {
      let run = digitsAt(b, at + 8);
      if run.count > 0 { into[std.Number.toString(run.value)] = true; };
    };
    at = at + 1;
  };
  null;
};

// 符号名精确匹配 `.strbox<digits>` 且以 NUL 结束。
// 返回 id;不是 .strbox 返回 -1;像 .strbox 但形状不对返回 -2。
let symbolId = (b, namesOff, namesSize, nameRel) -> {
  if nameRel < 0 || nameRel >= namesSize { return -1; };
  let start = namesOff + nameRel;
  if !isStrboxAt(b, start) { return -1; };
  let run = digitsAt(b, start + 7);
  if run.count == 0 { return -2; };
  let after = start + 7 + run.count;
  if after - namesOff >= namesSize || byteOr(b, after) != 0 { return -2; };
  run.value;
};

// address → 文件偏移;count 必须落在同一个 PT_LOAD 的文件范围内。
let addrToOffset = (segments, address, count) -> {
  let i = 0;
  while i < segments.length {
    let seg = segments[i];
    if seg.type == 1 && address >= seg.vaddr {
      let delta = address - seg.vaddr;
      if delta <= seg.filesz && count >= 0 && delta + count <= seg.filesz {
        return seg.offset + delta;
      };
    };
    i = i + 1;
  };
  -1;
};

// 返回 "" 表示通过;否则返回失败原因。
let checkElf = (path, stringsPath, irPath, relaxed) -> {
  let b = std.Bytes.read(path);
  if isError(b) { return "cannot read " + path; };
  let size = lengthOf(b);
  if size < 64 {
    return "ELF data extends beyond the file: header needs 64 bytes, file has " + std.Number.toString(size);
  };
  if hexOr(b, 0, 4) != "7f454c46" { return "not an ELF file: bad magic"; };
  if byteOr(b, 4) != 2 { return "not an ELF64 file: EI_CLASS is " + std.Number.toString(byteOr(b, 4)); };
  if byteOr(b, 5) != 1 { return "not a little-endian ELF file: EI_DATA is " + std.Number.toString(byteOr(b, 5)); };
  if byteOr(b, 6) != 1 { return "unsupported ELF ident version: " + std.Number.toString(byteOr(b, 6)); };

  let eType = u16Or(b, 16);
  let eMachine = u16Or(b, 18);
  let eVersion = u32Or(b, 20);
  let eEhsize = u16Or(b, 52);
  let ePhentsize = u16Or(b, 54);
  let ePhnum = u16Or(b, 56);
  let eShentsize = u16Or(b, 58);
  let eShnum = u16Or(b, 60);
  let phoff = u64Or(b, 32);
  let shoff = u64Or(b, 40);
  if eType != 2 && eType != 3 {
    return "e_type is " + std.Number.toString(eType) + ", expected 2 (ET_EXEC) or 3 (ET_DYN)";
  };
  if eMachine != 183 {
    return "e_machine is " + std.Number.toString(eMachine) + ", expected 183 (AArch64)";
  };
  if eVersion != 1 { return "e_version is " + std.Number.toString(eVersion) + ", expected 1"; };
  if eEhsize != 64 { return "unsupported ELF header size: " + std.Number.toString(eEhsize); };
  if ePhentsize != 56 { return "unsupported program header size: " + std.Number.toString(ePhentsize); };
  if eShentsize != 64 { return "unsupported section header size: " + std.Number.toString(eShentsize); };
  if ePhnum < 0 || phoff < 0 || phoff > size || phoff + ePhnum * ePhentsize > size {
    return "ELF data extends beyond the file: program header table";
  };
  if eShnum < 0 || shoff < 0 || shoff > size || shoff + eShnum * eShentsize > size {
    return "ELF data extends beyond the file: section header table";
  };

  // 程序头:每个 p_offset + p_filesz 都必须落在文件内。
  let segments = [];
  let pi = 0;
  while pi < ePhnum {
    let at = phoff + pi * ePhentsize;
    let kind = u32Or(b, at);
    let offset = u64Or(b, at + 8);
    let vaddr = u64Or(b, at + 16);
    let filesz = u64Or(b, at + 32);
    let memsz = u64Or(b, at + 40);
    if kind < 0 || offset < 0 || vaddr < 0 || filesz < 0 || memsz < 0 {
      return "ELF data extends beyond the file: program header " + std.Number.toString(pi);
    };
    if offset + filesz > size {
      return "ELF data extends beyond the file: program header " + std.Number.toString(pi);
    };
    segments[segments.length] = { type: kind, offset: offset, vaddr: vaddr, filesz: filesz, memsz: memsz };
    pi = pi + 1;
  };

  // 节头:NOBITS 不走文件,其余 sh_offset + sh_size 必须在文件内。
  let sections = [];
  let si = 0;
  while si < eShnum {
    let at = shoff + si * eShentsize;
    let kind = u32Or(b, at + 4);
    let offset = u64Or(b, at + 24);
    let secSize = u64Or(b, at + 32);
    let link = u32Or(b, at + 40);
    let entsize = u64Or(b, at + 56);
    if kind < 0 || offset < 0 || secSize < 0 || link < 0 || entsize < 0 {
      return "ELF data extends beyond the file: section header " + std.Number.toString(si);
    };
    if kind != 8 && offset + secSize > size {
      return "ELF data extends beyond the file: section header " + std.Number.toString(si);
    };
    sections[sections.length] = { type: kind, offset: offset, size: secSize, link: link, entsize: entsize };
    si = si + 1;
  };

  // PT_DYNAMIC:loader 实际消费的重定位表。
  let dynamic = {};
  let di = 0;
  while di < segments.length {
    if segments[di].type == 2 {
      let off = segments[di].offset;
      let dsize = segments[di].filesz;
      if dsize % 16 != 0 { return "invalid dynamic table"; };
      let at = off; let stop = false;
      while at + 16 <= off + dsize && !stop {
        let tag = u64Or(b, at);
        let value = u64Or(b, at + 8);
        if tag < 0 || value < 0 { return "ELF data extends beyond the file: dynamic entry"; };
        if tag == 0 { stop = true; }
        else {
          if tag == 17 || tag == 36 || tag == 0x6000000f || tag == 0x60000011 {
            return "packed/REL relocations are not supported by this build checker";
          };
          dynamic[std.Number.toString(tag)] = value;
        };
        at = at + 16;
      };
    };
    di = di + 1;
  };

  let relocs = {};
  if !isError(dynamic["7"]) {
    let relaAddr = dynamic["7"];
    let relaSize = if isError(dynamic["8"]) { -1; } else { dynamic["8"]; };
    let relaEnt = if isError(dynamic["9"]) { -1; } else { dynamic["9"]; };
    if relaSize < 0 { return "invalid dynamic RELA table: DT_RELASZ missing"; };
    if relaEnt != 24 {
      return "invalid dynamic RELA table: DT_RELAENT is " + std.Number.toString(relaEnt) + ", expected 24";
    };
    if relaSize % 24 != 0 { return "invalid dynamic RELA table: size is not a multiple of 24"; };
    if relaSize > 0 {
      let start = addrToOffset(segments, relaAddr, relaSize);
      if start < 0 { return "ELF data extends beyond the file: dynamic RELA table"; };
      let k = 0;
      while k < relaSize / 24 {
        let at = start + k * 24;
        let target = u64Or(b, at);
        let info = u64Or(b, at + 8);
        let addend = u64Or(b, at + 16);
        if target < 0 || info < 0 || addend < 0 {
          return "ELF data extends beyond the file: dynamic relocation";
        };
        let key = std.Number.toString(target);
        if !isError(relocs[key]) { return "duplicate dynamic relocation at 0x" + hexOr(b, at, 8); };
        relocs[key] = { info: info, addend: addend };
        k = k + 1;
      };
    };
  };

  // 期望的 .strbox id:库的 strings.tsv ∪ 用户 IR 的定义行。
  let expected = {};
  if stringsPath != "" {
    let tsv = std.Bytes.read(stringsPath);
    if isError(tsv) { return "cannot read " + stringsPath; };
    collectTsvIds(tsv, expected);
  };
  if irPath != "" {
    let ir = std.Bytes.read(irPath);
    if isError(ir) { return "cannot read " + irPath; };
    collectIrIds(ir, expected);
  };

  // 符号表。
  let symbols = {};
  let ti = 0;
  while ti < sections.length {
    let sec = sections[ti];
    if sec.type == 2 {
      if sec.entsize != 24 {
        return "invalid symbol table: entsize is " + std.Number.toString(sec.entsize) + ", expected 24";
      };
      if sec.size % 24 != 0 { return "invalid symbol table: size is not a multiple of 24"; };
      if sec.link < 0 || sec.link >= sections.length {
        return "invalid symbol table: bad string table link";
      };
      let names = sections[sec.link];
      let namesOff = names.offset; let namesSize = names.size;
      let count = sec.size / 24; let k = 0;
      while k < count {
        let at = sec.offset + k * 24;
        let nameRel = u32Or(b, at);
        let info = byteOr(b, at + 4);
        let shndx = u16Or(b, at + 6);
        let address = u64Or(b, at + 8);
        let stSize = u64Or(b, at + 16);
        if nameRel < 0 || info < 0 || shndx < 0 || address < 0 || stSize < 0 {
          return "ELF data extends beyond the file: symbol " + std.Number.toString(k);
        };
        let id = symbolId(b, namesOff, namesSize, nameRel);
        if id == -2 { return "invalid .strbox symbol name"; }
        else if id >= 0 {
          let idText = std.Number.toString(id);
          if !isError(symbols[idText]) { return "duplicate .strbox symbol .strbox" + idText; };
          if shndx == 0 || info % 16 != 1 || (stSize != 24 && stSize != 48) {
            return "invalid string symbol .strbox" + idText;
          };
          symbols[idText] = { address: address, size: stSize };
        };
        k = k + 1;
      };
    };
    ti = ti + 1;
  };

  let keys = std.Object.keys(symbols);
  // 多出来的 .strbox 不在输入里 ⇒ 说明校验的输入和产物不是同一份(或库对象没给 tsv)。
  if !relaxed {
    let ei = 0;
    while ei < keys.length {
      let idText = keys[ei];
      if isError(expected[idText]) {
        return "ELF has string symbol(s) not in the input IR: .strbox" + idText;
      };
      ei = ei + 1;
    };
  };
  // ET_DYN 的指针必须由 loader 重定位给出;头部里存的旧指针只对 ET_EXEC 有效。
  let ri = 0;
  while ri < keys.length {
    let idText = keys[ri];
    let sym = symbols[idText];
    let headerAt = addrToOffset(segments, sym.address, 24);
    if headerAt < 0 {
      return ".strbox" + idText + ": symbol address not in a loadable segment";
    };
    if u64Or(b, headerAt) != 2 { return ".strbox" + idText + ": tag is not 2"; };
    let rel = relocs[std.Number.toString(sym.address + 8)];
    let bufferAddress = 0;
    if !isError(rel) {
      if rel.info != 1027 { return ".strbox" + idText + ": unsupported buffer relocation"; };
      bufferAddress = rel.addend;
    } else if eType == 3 {
      return ".strbox" + idText + ": missing string-buffer relocation";
    } else {
      bufferAddress = u64Or(b, headerAt + 8);
    };
    if bufferAddress == 0 { return ".strbox" + idText + ": null string-buffer pointer"; };
    if addrToOffset(segments, bufferAddress, 1) < 0 {
      return ".strbox" + idText + ": buffer not in a loadable segment";
    };
    ri = ri + 1;
  };
  "";
};

if args.length < 2 { fail("usage: verify <elf> <strings.tsv|-> [ir] [--lto]"); };
let ir = if args.length > 2 { args[2]; } else { ""; };
let stringsPath = if args[1] == "-" { ""; } else { args[1]; };
let relaxed = if args.length > 3 && args[3] == "--lto" { 1; } else { 0; };
if stringsPath == "" && ir == "" { fail("nothing to verify: pass strings.tsv and/or the IR"); };
let strict = checkElf(args[0], stringsPath, ir, relaxed);
if strict != "" { fail(strict); };
let report = std.Bytes.verifyStrings(args[0], stringsPath, ir, relaxed);
if isError(report) { fail("verification failed"); };
if !report.ok { fail(report.message); };
// A non-empty strings.tsv always has entries; 0 means it was not read as expected
// (wrong file kind or missing tabs) — reporting success would hide that.
if report.count == 0 && stringsPath != "" { fail("no static strings verified from " + stringsPath); };
println("verify: " + std.String.toString(report.count) + " static strings ok");
