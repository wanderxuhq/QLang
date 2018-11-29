from QNode import *
from QUtil import *
class QOperation:
    def execute(self):
        pass

class Plus(QOperation):
    def execute(self, exp):
        return QNode(QUtil.TokenType.NUM, exp[0].node.value + exp[1].node.value)

class Minus(QOperation):
    def execute(self, exp):
        return QNode(QUtil.TokenType.NUM, exp[0].node.value - exp[1].node.value)

class Multiply(QOperation):
    def execute(self, exp):
        return QNode(QUtil.TokenType.NUM, exp[0].node.value * exp[1].node.value)

class Divide(QOperation):
    def execute(self, exp):
        return QNode(QUtil.TokenType.NUM, exp[0].node.value / exp[1].node.value)

priority = {
    '+': 1, 
    '-': 1, 
    '*': 2, 
    '/': 2,
    }