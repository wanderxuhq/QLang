import {notMatch, isMatch} from './match.js';
import {parseConst} from './parse-const.js';
import { parseNewLine } from './parse-space.js';

const parseComment = str => index => {
    let _index = index;
    let startComment = parseConst('/*')(str)(index);
    if (isMatch(startComment)) {
        _index = startComment.end;
        let char = str.substring(_index, _index + 1);

        let endComment = parseConst('*/')(str)(_index);
        if (!isMatch(endComment)) {
            let comment = char;
            _index++;
            endComment = parseConst('*/')(str)(_index);
            while (!isMatch(endComment)) {
                char = str.substring(_index, _index + 1);
                if (!isMatch(endComment)) {
                    comment += char;
                    _index++;
                    endComment = parseConst('*/')(str)(_index);
                }
            }

            return {
                type: 'COMMENT',
                start: index,
                end: endComment.end,
                comment: comment
            }
        } else {
            return {
                type: 'COMMENT',
                start: index,
                end: endComment.end,
                comment: ''
            }
        }
    } else {
        startComment = parseConst('//')(str)(index);
        if (isMatch(startComment)) {
            _index = startComment.end;
            let char = str.substring(_index, _index + 1);

            let endComment = parseNewLine(str)(_index);
            if (!isMatch(endComment)) {
                let comment = char;
                _index++;
                endComment = parseNewLine(str)(_index);
                while (!isMatch(endComment) && _index < str.length) {
                    char = str.substring(_index, _index + 1);
                    if (!isMatch(endComment)) {
                        comment += char;
                        _index++;
                        endComment = parseNewLine(str)(_index);
                    }
                }

                return {
                    type: 'COMMENT',
                    start: index,
                    end: _index,
                    comment: comment,
                }
            } else {
                return {
                    type: 'COMMENT',
                    start: index,
                    end: endComment.end,
                    comment: '',
                }
            }
        } else {
            return notMatch(index);
        }
    }
}

export {
    parseComment
}