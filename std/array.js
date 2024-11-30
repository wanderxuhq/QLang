import { Ast } from "../ast/index.js";
import rootEnv from "../env.js";
import { fromNative, toNative } from "../runtime/native.js";
import { runValue } from "../runtime/run-value.js";
import { Void } from "../value/constant.js";

let lib = new Map();
lib.set('length', arr => fromNative(arr.values.length));
lib.set('add', arr => {
    let func = fromNative((arr, e) => {
        arr.value.values.push(e);
        //console.log('---')
        /*
        for (let [key, value] of e.env.context) {
            console.log(key);
        }
        */
        //console.log(e.env.context.map(e1 => e1.key))

        return { type: Ast.VALUE, value: Void};
    });
    func.value.oop = true;
    func.env = rootEnv

    return func;
});
lib.set('remove', arr => {
    let func = fromNative((arr, index) => {
        arr.value.values.splice(toNative(index.value), 1);

        return { type: Ast.VALUE, value: Void};
    });
    func.oop = true;
    func.env = rootEnv

    return func;
});

export default lib;