let Option = {
    Some = (value) -> {
        return {
            value = value,
            isSome = () -> {return true;},
            isNone = () -> {return false;},
            then = (f) -> {return f(value);}
        }
    },
    None = {
        isSome = () -> {return false;},
        isNone = () -> {return true;},
        then = (f) -> {return false;}
    }
};

let createMap = x -> {
    let cache1 = [];
    return {
        put = (key, value) -> {
            cache1.add([key, value]);
        },
        get = key -> {
            let index = 0;
            while (index < cache1.length) {
                if (cache1[index][0] == key) {
                    return Option.Some(cache1[index][1]);
                }
                index = index + 1;
            }

            return Option.None;
        }
    }
};

let Type = () -> {
    let cache = createMap(1);
    return {
        create = (name, compatible) -> {
            let t =  {
                compatible = compatible
            };
            cache.put(name, t);
            return t;
        },
        compatible = (v1) -> {
            return cache.get(v1).then((x) -> {return true;});
        },
        check = (t, v) -> {
            return cache.get(t).value.compatible(v);
        }
    }
}()

Type.create('Type', Type.compatible)
Type.create('Any', (v) -> {
    return true;
});

println("Type.check('Type', 'Any')")
println(Type.check('Type', 'Any'));

println(Type.check('Any', 1));

Type.create('Number', (v) -> {
    return false;
})
//println(Type.check('Number', 100))

Type.create('Even', (v) -> {
    return v % 2 == 0;
})

println(Type.check('Even', 100))
println("Type.check('Even', 101)")
println(Type.check('Even', 101))

Type.create('Void', (v) -> {
    return false;
})

/*
if (~v) {
    
}
*/
/*
let x: Type = Type.sum([1, 'Str'])
Type.compatible(x, 1) //true
Type.compatible(x, 'Str') //true
Type.compatible(x, 'Str1') //false

let y: Type = Type.tuple([Int, String])
Type.compatible(y, [1, 'abc']) // true
Type.compatible(y, [true, 'abc']) // false

//TODO
let z: Type = Type.record({
    a = Int,
    b = String
});
Type.compatible(z, {a: 1, b: 'abc'}) // true

let CombineObject = Type.create(v -> {
    
})

let NumberArray : Type = Array(Int)
Type.compatible(NumberArray, [1]) // true

let dependencyType: (x: Int) -> {
    if (x == 1) {
        return Int
    } else {
        return String
    }
}
let MaybeInt = dependencyType(1)
Type.compatible(MaybeInt, 1) // true
Type.compatible(MaybeInt, 'abc') // false
let MaybeString = dependencyType(3)
Type.compatible(MaybeInt, 1) // false
Type.compatible(MaybeInt, 'abc') // true

let ComplexArray = Type.create(v -> {
    if (Type.compatible(Array(Any), v)) {
        if Type.compatible(Int, v[0]) {
            let n = 1;
            while n < n.length {
                if (!Type.compatible(String, v[n])) {
                    return false
                }
            }

            return true;
        }
    }
});
Type.compatible(ComplexArray, [1, 'abc', 'def']); // true

let FunctionType = Type.create(t -> {
    if (Type.compatible(Function([Int, Boolean], String), t)) {
        return true;
    } else {
        return false;
    }
})
Type.compatible(FunctionType, (x: Int, y: Boolean) -> {
    return 'abc'
}); // true
Type.compatible(FunctionType, (x, y) -> {
    return 'abc'
}); // false
*/