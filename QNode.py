class QNode:
    type = None
    value = None
    def __init__(self, type, value):
        self.type = type
        self.value = value
    def __str__(self):
        return str(self.value) + " " + str(self.type)
    def __repr__(self):
<<<<<<< Updated upstream
        return str(self.value) + " " + str(self.type)
=======
        return str(self.value)
    def bool_true(self):
        return self.value == "true"

    def getvalue(self, variables):
        if self.type == QUtil.TokenType.VAR and self.value not in QUtil.keywords:
            return variables[self.value].getvalue(variables)
        else:
            return self

    def getstrval(self, variables):
        if self.type == QUtil.TokenType.STR:
            result = self.value[1: len(self.value) - 1]
            result = result.replace("\\n", "\n")
            result = result.replace("\\t", "\t")
            return result
        elif self.type == QUtil.TokenType.VAR:
            return self.getvalue(variables)
        else:
            return self.value
>>>>>>> Stashed changes
class NumQNode(QNode):{}
class AlpQNode(QNode):{}