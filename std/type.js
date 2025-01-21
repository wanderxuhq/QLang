import { Ast } from "../ast/index.js";
import { PrimeType } from "../type/constant.js";
import { fromNative, toNative, wrap } from "../runtime/native.js";
import { runValue } from "../runtime/run-value.js";

let Type = {
    create: (compatible) => {
        if (!compatible) {
            throw new Error('Type.create: compatible function is required');
        }

        return {
            type: Ast.VALUE,
            value: {
                type: PrimeType.Type,
                fields: [{
                    variable: { value: "compatible" },
                    value: compatible
                }]
            },
            env: compatible.env
        };
    },

    compatible: (t) => {
        return fromNative(t.value.type === PrimeType.Type);
    },

    check: (t, v) => {
        if (!t) {
            throw new Error('Type.check: type parameter is required');
        }
        let wrappedValue;
        if (!v.native) {
            wrappedValue = v;
        } else {
            wrappedValue = wrap(v);
        }

        if (t.type === Ast.VALUE) {
            const nativeT = toNative(t);
            if (!nativeT?.compatible) {
                throw new Error('Type.check: invalid type object');
            }
            const field = t.value.fields.find(e => e.variable.value === 'compatible').value
            const result = runValue(t.env)({
                type: Ast.VALUE,
                arguments: [{parameters: [wrappedValue]}],
                value: runValue(field.env)(field).value.value,
                native: field.native
            });

            return result.value;
        }

        const nativeT = toNative(t);
        if (typeof nativeT?.compatible !== 'function') {
            throw new Error('Type.check: invalid compatible function');
        }

        return fromNative(nativeT.compatible(wrappedValue));
    },

    get: (v) => {
        return fromNative(v.value.type);
    }
};

//const Type0 = fromNative(Type);
//Type0.value.type = PrimeType.Type;

//console.log(Type.create(wrap(v => v.value.type === 'Number')));

export default Type;