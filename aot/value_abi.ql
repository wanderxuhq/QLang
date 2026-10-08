// Value representation and truthiness helpers emitted by the QLang compiler.
let valueABI = `; Internal value ABI helpers. They do not allocate.
define internal i1 @ql_empty(%ql_value %v) alwaysinline {
entry:
  %kind = extractvalue %ql_value %v, 0
  %bits = extractvalue %ql_value %v, 1
  %both = or i64 %kind, %bits
  %empty = icmp eq i64 %both, 0
  ret i1 %empty
}
define internal i64 @ql_tag(%ql_value %v) alwaysinline {
entry:
  %kind = extractvalue %ql_value %v, 0
  %bits = extractvalue %ql_value %v, 1
  %heap = icmp eq i64 %kind, 0
  %present = icmp ne i64 %bits, 0
  %read = and i1 %heap, %present
  br i1 %read, label %object, label %scalar
object:
  %pointer = inttoptr i64 %bits to ptr
  %tag = load i64, ptr %pointer, align 1
  ret i64 %tag
scalar:
  ret i64 %kind
}
define internal i64 @ql_word(%ql_value %v, i64 %offset) alwaysinline {
entry:
  %kind = extractvalue %ql_value %v, 0
  %bits = extractvalue %ql_value %v, 1
  %heap = icmp eq i64 %kind, 0
  br i1 %heap, label %object, label %scalar
object:
  %pointer = inttoptr i64 %bits to ptr
  %address = getelementptr i8, ptr %pointer, i64 %offset
  %word = load i64, ptr %address, align 1
  ret i64 %word
scalar:
  %header = icmp eq i64 %offset, 0
  %result = select i1 %header, i64 %kind, i64 %bits
  ret i64 %result
}
define internal i8 @ql_byte(%ql_value %v, i64 %offset) alwaysinline {
entry:
  %kind = extractvalue %ql_value %v, 0
  %bits = extractvalue %ql_value %v, 1
  %heap = icmp eq i64 %kind, 0
  br i1 %heap, label %object, label %scalar
object:
  %pointer = inttoptr i64 %bits to ptr
  %address = getelementptr i8, ptr %pointer, i64 %offset
  %byte = load i8, ptr %address, align 1
  ret i8 %byte
scalar:
  %header = icmp ult i64 %offset, 8
  %word = select i1 %header, i64 %kind, i64 %bits
  %index = and i64 %offset, 7
  %shift = shl i64 %index, 3
  %shifted = lshr i64 %word, %shift
  %result = trunc i64 %shifted to i8
  ret i8 %result
}
define internal i1 @ql_truthy(%ql_value %v) alwaysinline {
entry:
  %tag = call i64 @ql_tag(%ql_value %v)
  %bits = extractvalue %ql_value %v, 1
  switch i64 %tag, label %other [ i64 1, label %number
    i64 3, label %boolean
    i64 2, label %sized
    i64 5, label %sized ]
number:
  %n = bitcast i64 %bits to double
  %nz = fcmp une double %n, 0.0
  ret i1 %nz
boolean:
  %b = icmp ne i64 %bits, 0
  ret i1 %b
sized:
  %pointer = inttoptr i64 %bits to ptr
  %address = getelementptr i8, ptr %pointer, i64 16
  %length = load i64, ptr %address
  %nonempty = icmp ne i64 %length, 0
  ret i1 %nonempty
other:
  %object = icmp eq i64 %tag, 6
  %function = icmp eq i64 %tag, 7
  %error = icmp eq i64 %tag, 8
  %of = or i1 %object, %function
  %result = or i1 %of, %error
  ret i1 %result
}
`;
export valueABI;
