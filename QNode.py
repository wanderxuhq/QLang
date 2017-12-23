class QNode:
    type = None
    value = None
    keywords = ["true", "false"]
    def __init__(self, type, value):
        self.type = type
        self.value = value
    def __str__(self):
        return str(self.value)
    def __repr__(self):
        return str(self.value)
    lexer = {'var':0, 'num':1, 'alp':2, 'str':3, 'dob':4, 'pnt':5, 'cmt':6}

    def bool_true(self):
        return self.value == "true"

    def getstrval(self):
        if self.type == QNode.lexer['str']:
            result = self.value[1: len(self.value) - 1]
            result = result.replace("\\n", "\n")
            result = result.replace("\\t", "\t")
            return result
        else:
            return self.value
class NumQNode(QNode):{}
class AlpQNode(QNode):{}