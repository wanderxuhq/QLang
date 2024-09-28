/*
let f = x -> {
    let k = 1;
    return y -> {
        return 0;
    };
};

let n = 2;
let g = (y,z,a) -> {
    let j = 5;
    return 2;
};

f 1;
*/
let x = (y) -> {
    return (z) -> {
        return (a) -> {
            return (b) -> {
                return y + z * a+b;
            }
        }
    }
}

x 1 2 3 4