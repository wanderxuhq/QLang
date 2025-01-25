import { PrimeType } from "../type/constant.js";
import array from "./array.js";

let std = new Map();
//TODO Better way?
std.set(PrimeType.Array.value, array)

const findInStd = (type, attribute) => {
    if (std.has(type.value)) {
        const lib = std.get(type.value)
        if (lib.has(attribute)) {
            return lib.get(attribute);
        } else {
            return null;
        }
    } else {
        return null;
    }
}

//findInStd(PrimeType.Array, 'length')
//findInStd('print');

export {findInStd}