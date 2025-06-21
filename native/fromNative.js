import { Ast } from "../ast/index.js";
import { PrimeType } from "../type/constant.js";


const trueTypeOf = (obj) => Object.prototype.toString.call(obj).slice(8, -1).toLowerCase()

const fromNative = (value) => {
    const type = trueTypeOf(value);
    let result = undefined;
    if (type === 'boolean') {
        result = {
            type: PrimeType.Boolean,
            value: value
        }
    } else if (type === 'number') {
        result = {
            type: PrimeType.Number,
            value: value
        }
    } else if (type === 'string') {
        result = {
            type: PrimeType.String,
            value: value
        }
    } else if (type === 'object') {
        let fields = [];
        for (const field in value) {
            fields.push(
                {
                    key: {
                        type: Ast.IDENTITY,
                        value: field
                    },
                    value: value[field]
                }
            )
        }
        result = {
            type: PrimeType.Object,
            fields: fields
        }
    } else if (type === 'array') {
        let values = [];
        for (const v of value) {
            values.push(v)
        }
        result = {
            type: PrimeType.Array,
            values: values
        }
    } else if (type === 'function') {
        return {
            type: Ast.VALUE,
            native: true,
            value: value
        }
    }

    return {
        type: Ast.VALUE,
        value: result
    }
}

const fromNativeRec = (value) => {
    const type = trueTypeOf(value);
    let result = undefined;
    if (type === 'boolean') {
        result = {
            type: PrimeType.Boolean,
            value: value
        }
    } else if (type === 'number') {
        result = {
            type: PrimeType.Number,
            value: value
        }
    } else if (type === 'string') {
        result = {
            type: PrimeType.String,
            value: value
        }
    } else if (type === 'object') {
        let fields = [];
        for (const field in value) {
            if (value[field] !== undefined) {
                fields.push(
                    {
                        key: {
                            type: Ast.IDENTITY,
                            value: field
                        },
                        value: fromNativeRec(value[field])
                    }
                )
            }
        }
        result = {
            type: PrimeType.Object,
            fields: fields
        }
    } else if (type === 'array') {
        //let values = [];
        //for (const v of value) {
        //    values.push(v)
        //}
        result = {
            type: PrimeType.Array,
            values: value.map(fromNativeRec)
        }
    } else if (type === 'function') {
        return {
            type: Ast.VALUE,
            native: true,
            value: value
        }
    }

    return {
        type: Ast.VALUE,
        value: result
    }
}

const wrap = (value) => {
    return {
        type: Ast.VALUE,
        native: true,
        value: value
    }
}

const unwrap = (value) => {
    return value.value;
}

export {
    fromNative, fromNativeRec, wrap, unwrap
}