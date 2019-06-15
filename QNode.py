class QNode:
    type = None
    value = None
    def __init__(self, type, symbol):
        self.type = type
        self.value = symbol
    def __str__(self):
        return str(self.value)
    def __repr__(self):
        return str(self.value)

    NUM = 1
    CHAR = 2
    STR = 3
    VAR = 4
    PNT = 5