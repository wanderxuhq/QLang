import { Ast } from "../ast/index.js";
import rootEnv from "../env.js";
import { fromNative, wrap } from "../native/fromNative.js";
import toNative from "../native/toNative.js";
import { runFunction, runValue } from "../runtime/run-value.js";
import { Void } from "../value/constant.js";

export default fromNative(
    {
        length: fromNative(arr => fromNative(arr.value.values.length)),
        add: fromNative(arr => {
            let fn = wrap((e) => {
                arr.value.values.push(e);
                
                return { type: Ast.VALUE, value: Void };
            });
            fn.env = rootEnv

            return fn;
        }),
        remove: fromNative(arr => {
            let fn = fromNative((index) => {
                arr.value.values.splice(toNative(index), 1);

                return { type: Ast.VALUE, value: Void };
            });
            fn.env = rootEnv

            return fn;
        }),
        map: fromNative(arr => {
            let fn = fromNative((mapFn) => {
                return fromNative(arr.value.values.map(e => runFunction(mapFn.env)({ type: Ast.VALUE, value: mapFn })([[e]]).value));
            });
            fn.env = rootEnv

            return fn;
        })
    }
);