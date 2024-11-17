import { fromNative, toNative } from "../runtime/native.js";
import { makeRunValueInput } from "../runtime/run-value.js";
import { Void } from "../value/constant.js";

let lib = new Map();
lib.set('length', arr => fromNative(arr.values.length));
lib.set('add', arr => {
    let func = fromNative((arr, e) => {
        arr.values.push(makeRunValueInput(e));

        return Void;
    });
    func.oop = true;

    return func;
});
lib.set('remove', arr => {
    let func = fromNative((arr, index) => {
        arr.values.splice(toNative(index.value), 1);

        return Void;
    });
    func.oop = true;

    return func;
});

export default lib;