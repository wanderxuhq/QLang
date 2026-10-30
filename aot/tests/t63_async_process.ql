// std.process.spawn/wait:并发起两个子进程,再逐个收状态与输出。
let h1 = std.process.spawn(["sh", "-c", "printf a"]);
let h2 = std.process.spawn(["sh", "-c", "printf b"]);
let r1 = std.process.wait(h1);
let r2 = std.process.wait(h2);
println(r1.stdout + r2.stdout);
let bad = std.process.spawn(["sh", "-c", "exit 3"]);
println(std.process.wait(bad).status);
