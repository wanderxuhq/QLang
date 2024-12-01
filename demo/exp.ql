
//f()[0]()

let f = () -> {
    let a = 1;
    let h = () -> {return a}
    return [h]
}
print(f()[0]())

/*
let f = () -> {
    let a = 1;
    let h = () -> {return a}
    return [h]
}

let g = (arr) -> {
    return arr;
}
//let arr1 = f()
//debug(arr1)
let x = f()[0]();
debug(x)
//print(g(arr1))

//print(g())
*/
/*let f = (x) -> {
    let g = (y) -> {return {i = y, z = [y + 1]}}
    let a = 1;
    let b = 2;
    return [[a,b],x, g(x+1)]
}
print(f(3))
*/
/*let x = 1
let o = {a = x, b = 2}
print(o.a)
*/
/*let f = (x) -> {
    let n = x;
    
    return {
        a = () -> {return x}
    }
}
debug(f(2).a())
*/
/*
let x = (y) -> {
    let n = y;
    return {a = y, b = n}
}(3);
debug(x.a)
*/
/*
let f = (x) -> {
    let y = 5
    return {
        b = y,
        a = x,
        g = z -> {
            return z
        },
        h = [x,y]
    }
}
//debug(1)
let z = f(1)

debug(f(1).h)
*/
/*
let f = (x) -> {
    //debug(m)
    return x;
}
//debug(f(1))
let g = (y) -> {
    let m = 20;
    return f(y);
}
debug(g(1));
*/
/*
let h = a -> {
    return {
        x = a,
        y = (b) -> {
            return {
                j = a,
                m = b
            }
        }
    }
};
//h(10).y(5).j
let k = h(6).y(8);
println(k.m)
//println(k.b)
*/
/*
let f = (v) -> {
    return () -> {return v;};
}

let g = (w) -> {
    return f(w);
}

print(g(3)());
*/
/*
//a.add(2)
let f = (a) -> {
    let x = a
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
let a = [f(6).g(8)]
print(a)
*/
/*
let f = (g, n) -> {return g(n)}
print(f(x -> {return x + 1;}, 6))
*/
/*
let a = [];
a.add(2)
//println(a.add(2).add(3))
println(a)
a.add(4)
println(a)
*/
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
