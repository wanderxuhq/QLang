import {notMatch} from './match.js';

const parseIdentity = str => (index) => {
    let _index = index;
    let char = str.substring(index, index + 1);
    let length = 0;
    if (char.match(/[A-Za-z]/)) {
        let id = char;
        _index++;
        length++
        while (char.match(/[A-Za-z0-9]/)) {
            char = str.substring(_index, _index + 1);
            if (char.match(/[A-Za-z0-9]/)) {
                id += char
                _index++;
                length++
            }
        }

        if (id !== 'let' &&
            id !== 'if' &&
            id !== 'else' &&
            id !== 'while' &&
            id !== 'return' &&
            id !== 'true' &&
            id !== 'false' &&
            id !== 'import' &&
            id !== 'export'
        ) {
            return {
                type: 'IDENTITY',
                start: index,
                end: index + length,
                length: length,
                value: id
            }
        } else {
            return notMatch(index);
        }
    } else {
        return notMatch(index);
    }
}

export {
    parseIdentity
}