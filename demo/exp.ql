//a.add(2)
let f = (a) -> {
    let x = 5
    return {
        g = (b) -> {
            return x
        }
    }
}
let n = f(3)
print(n.g(4))
//print(f(3)(4))
print('\n')
let a = [1]
println(a.add(2).add(3))
println(a)
a.add(4)
println(a)
/*
let arr = [1];
//arr.add(1);
print(arr)

let obj = {
    a: (x) -> {
        return 1
    }
}
let arr = [5]
arr.add = e -> {
    Arrays.add(arr, e)
}
arr.add(1);
print(arr)
print('\n')
//print([1,2,3][0])
let a = [[1,2,3],[4,5,6]]
a[0][0] = 8
print(a)
print('\n')
let a = {
    x = 5,
    b = {d = 2}
}
a.b.c = 1
a.b.c = 2
a.b.c = 3
print(a)
*/
