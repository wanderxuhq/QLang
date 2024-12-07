const generateLineIndex = (source) => {
    let result = [0];
    for (let index = 0; index < source.length; index++) {
        if (source[index] === '\n') {
            result.push(index + 1);
        }
    }

    return result;
}

const calculatePos = (source, index) => {
    const lineIndex = generateLineIndex(source);
    for (let i = 0; i < lineIndex.length; i++) {
        if (index < lineIndex[i]) {
            return {
                row: i - 1,
                col: index - lineIndex[i - 1],
            }
        }
    }
}

export {
    calculatePos
}