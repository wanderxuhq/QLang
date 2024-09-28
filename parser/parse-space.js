import {notMatch, isMatch} from './match.js';
import { parseComment } from './parse-comment.js';

const parseSpaceAndNewline = str => index => {
    let _index = index;
    let length = 0;
    let char = str.substring(_index, _index + 1);
    let comment = parseComment(str)(_index);

    if (char.match(/\s/)) {
        let space = char;
        _index++;
        length++;
        while (char.match(/\s/)) {
            char = str.substring(_index, _index + 1);
            if (char.match(/\s/)) {
                space += char
                _index++;
                length++;
            } else {
                comment = parseComment(str)(_index);
                if (isMatch(comment)) {
                    _index = comment.end;
                    //console.log('comment1: ', str.substring(comment.start, comment.end));
                    char = str.substring(_index, _index + 1);
                }
            }
        }
        return {
            type: 'SPACE_ANE_NEWLINE',
            start: index,
            end: _index,
            value: space
        }
    } else if (isMatch(comment)) {
        const optionalSpaceAndNewline = parseOptionalSpaceAndNewline(str)(comment.end);
        //console.log('comment2: ', str.substring(index, optionalSpaceAndNewline.end));
        return {
            type: 'SPACE',
            start: index,
            end: optionalSpaceAndNewline.end,
            //TODO /*value*/
            value: str.substring(index, optionalSpaceAndNewline.end)
        }
    } else {
        return notMatch(index);
    }
}
const parseOptionalSpaceAndNewline = str => index => {
    const space = parseSpaceAndNewline(str)(index);

    if (isMatch(space)) {
        return space;
    } else {
        return {
            type: 'SPACE_ANE_NEWLINE',
            start: index,
            end: index,
            value: ''
        };
    }
}

const parseSpace = str => index => {
    let _index = index;
    let length = 0;
    let char = str.substring(_index, _index + 1);
    let comment = parseComment(str)(_index);

    if (char.match(/\s/) && char !== '\n' && char !== '\r') {
        let space = char;
        _index++;
        length++;
        while (char.match(/\s/) && char !== '\n' && char !== '\r') {
            char = str.substring(_index, _index + 1);
            if (char.match(/\s/) && char !== '\n' && char !== '\r') {
                space += char
                _index++;
                length++;
            } else {
                comment = parseComment(str)(_index);
                if (isMatch(comment)) {
                    _index = comment.end;
                    //console.log('comment3: ', str.substring(index, _index));
                    char = str.substring(_index, _index + 1);
                }
            }
        }
        return {
            type: 'SPACE',
            start: index,
            end: _index,
            value: space
        }
    } else if (isMatch(comment)) {
        //console.log('comment4: ', str.substring(index, comment.end));
        return {
            type: 'SPACE',
            start: index,
            end: comment.end,
            //TODO /*value*/
            value: str.substring(index, comment.end)
        }
    } else {
        return notMatch(index);
    }
}

const parseOptionalSpace = str => index => {
    const space = parseSpace(str)(index);
    if (isMatch(space)) {
        return space;
    } else {
        return {
            type: 'SPACE',
            start: index,
            end: index,
            value: ''
        };
    }
}

const parseNewLine = str => index => {
    let _index = index;
    let length = 0;
    let char = str.substring(_index, _index + 1);
    // For windows \r\n, ignore \r
    if (char.match(/\r/)) {
        _index++;
        length++;
        char = str.substring(_index, _index + 1);
    }
    if (char.match(/\n/)) {
        let newLine = char;
        _index++;
        length++;
        while (char.match(/\n/)) {
            char = str.substring(_index, _index + 1);
            if (char.match(/\n/)) {
                newLine += char
                _index++;
                length++;
            }
        }
        return {
            type: 'NEW_LINE',
            start: index,
            end: index + length,
            value: newLine
        }
    } else {
        return notMatch(index);
    }
}

const parseOptionalNewLine = str => index => {
    const newLine = parseNewLine(str)(index);
    if (isMatch(newLine)) {
        return newLine;
    } else {
        return {
            type: 'NEW_LINE',
            start: index,
            end: index,
            value: ''
        };
    }
}

export {
    parseSpaceAndNewline as parseSpace,
    parseOptionalSpaceAndNewline as parseOptionalSpace,
    parseSpace as parseSpaceOnly,
    parseOptionalSpace as parseOptionalSpaceOnly,
    parseNewLine,
    parseOptionalNewLine
};
