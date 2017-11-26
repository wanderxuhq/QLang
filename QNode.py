class QNode:
    type = None
    value = None
    def __init__(self, type, value):
        self.type = type
        self.value = value
    def __str__(self):
        return str(self.value) + " " + str(self.type)
    def __repr__(self):
        return str(self.value) + " " + str(self.type)
class NumQNode(QNode):{}
class AlpQNode(QNode):{}