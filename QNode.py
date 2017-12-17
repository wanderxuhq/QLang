class QNode:
    type = None
    value = None
    keywords = ["true", "false"]
    def __init__(self, type, value):
        self.type = type
        self.value = value
    def __str__(self):
        return str(self.value) + " " + str(self.type)
    def __repr__(self):
        return str(self.value) + " " + str(self.type)
    lexer = {'var':0, 'num':1, 'alp':2, 'str':3, 'dob':4, 'pnt':5, 'cmt':6}

    def bool_true(self):
        return self.value == "true"
class NumQNode(QNode):{}
class AlpQNode(QNode):{}