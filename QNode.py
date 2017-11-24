class QNode:
    type = None
    value = None
    def __init__(self, type, value):
        self.type = type
        self.value = value
class NumQNode(QNode):{}
class AlpQNode(QNode):{}