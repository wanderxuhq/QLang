let x = 5;
let b = ql_alloc(24);
ql_mem_store_ptr(b, 0, x);
let y = ql_mem_get_ptr(b, 0);
println(y);
