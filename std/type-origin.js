import { Ast } from "../ast/index.js";
import { equal, PrimeType } from "../type/constant.js";
import { fromNative, wrap } from "../native/fromNative.js";
import toNative from "../native/toNative.js";
import { runValue } from "../runtime/run-value.js";
import rootEnv from "../env.js";

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
        return fromNative(equal(t.value.type, PrimeType.Type));
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
            if (t.value.secondaryType !== 'FunctionSign') {
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
            } else {
                if (!equal(PrimeType.Function, v.value.type)) {
                    return fromNative(false)
                }
                if (v.value.parameters.length !== t.value.in.length) {
                    return fromNative(false)
                }
                for (let i = 0; i < t.value.in.length; i++) {
                    t.value.in[i]
                    v.value.parameters[i]
                    if (v.value.parameters[i].type) {
                        if (!equal(t.value.in[i], v.value.parameters[i].type)) {
                            return fromNative(false);
                        }
                    }
                    return fromNative(true)
                }
            }
        }

        const nativeT = toNative(t);
        if (typeof nativeT?.compatible !== 'function') {
            throw new Error('Type.check: invalid compatible function');
        }

        return fromNative(nativeT.compatible(wrappedValue));
    },

    get: (v) => {
        const value = v.value.type
        return runValue(rootEnv)(value).value;
    }
};

//const Type0 = fromNative(Type);
//Type0.value.type = PrimeType.Type;

//console.log(Type.create(wrap(v => v.value.type === 'Number')));

export default Type;