import { Ast } from "../ast/index.js";
import rootEnv from "../env.js";
import { fromNative, wrap } from "../native/fromNative.js";
import toNative from "../native/toNative.js";
import { runValue } from "../runtime/run-value.js";
import { Void } from "../value/constant.js";

export default fromNative({
    fields: fromNative(obj => {
        let o = fromNative(obj.value.fields.map(f => {
            return fromNative({
                name: fromNative(f.key.value), value: f.value
            })
        }));

        return o;
    }),
    merge: fromNative(obj => {
        let fn = wrap((e) => {
            obj.value.fields.push(...runValue(e.env)(e).value.value.fields);

            return { type: Ast.VALUE, value: Void };
        });
        fn.env = rootEnv

        return fn;
    }),
    addField: fromNative(obj => {
        let fn = wrap((field) => {
            //const native = toNative(e);
            const name = field.value.fields.find(e => e.key.value === "name");
            const value = field.value.fields.find(e => e.key.value === "value");
            obj.value.fields.push({key: {value: name.value.value.value}, value: value.value});

            return { type: Ast.VALUE, value: Void };
        });
        fn.env = rootEnv

        return fn;
    }),
    updateField: fromNative(obj => {
        let fn = wrap((key, value) => {
            const index = obj.value.fields.findIndex(field => field.key.value === toNative(key));
            obj.value.fields[index].value = value;

            return { type: Ast.VALUE, value: Void };
        });
        fn.env = rootEnv

        return fn;
    }),
    removeField: fromNative(obj => {
        let fn = wrap((e) => {
            const index = obj.value.fields.findIndex(field => field.key.value === toNative(e));
            obj.value.fields.splice(index, 1);

            return { type: Ast.VALUE, value: Void };
        });
        fn.env = rootEnv

        return fn;
    }),
    
});
