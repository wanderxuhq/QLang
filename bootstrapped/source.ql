// Source coordinates use one-based lines and Unicode-scalar columns.
// CRLF is one newline; a lone CR or LF also starts a new line.
let SourceMap = (chars) -> {
  let starts = [0]; let size = chars.length; let i = 0;
  while i < size {
    if chars[i] == "\r" {
      if i + 1 < size && chars[i + 1] == "\n" { i = i + 1; };
      starts[starts.length] = i + 1;
    } else if chars[i] == "\n" { starts[starts.length] = i + 1; };
    i = i + 1;
  };
  let position = (offset) -> {
    if offset < 0 { offset = 0; };
    if offset > size { offset = size; };
    let low = 0; let high = starts.length;
    while low + 1 < high {
      let total = low + high; let middle = (total - total % 2) / 2;
      if starts[middle] <= offset { low = middle; } else { high = middle; };
    };
    {line: low + 1, col: offset - starts[low] + 1};
  };
  {position: position};
};
export SourceMap;
