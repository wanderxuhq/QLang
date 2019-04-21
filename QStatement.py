import re
from QNode import *
from QOperation import *
from QExpression import *
class QStatement:
    inputs = None
    pattern = re.compile(
        r"\s*((?P<cmt>\/\/.*)|(?P<var>[_$A-Za-z][_\$A-Za-z0-9]*)|(?P<num>((?<=[+-])[+-][0-9]+(\.[0-9]+)?)|([0-9]+)(\.[0-9]+)?)|(?P<alp>[A-Za-z][A-Za-z0-9]*)|(?P<str>\"(\\\\|\\\"|\\n|[^\"])*\")|(?P<dob>==|!=|<=|>=|&&|\|\|)|(?P<pnt>[.,/#!$%^&\*;:{}+-=_`~()><]))?"
    )
    def __init__(self, inputs):
        self.inputs = inputs
        #self.parse()
        #self.opstack = [0]
    
    def __str__(self):
        return str(self.inputs)
    def __repr__(self):
        return str(self.inputs)

    def boolvalue(self, node):
        return node.value == "true"

    def run(self):
            nodes = []
            for m in self.pattern.finditer(self.inputs):
                    if m.group('var') != None:
                        if m.group('var') in QUtil.keywords:
                            nodes.append(QNode(TokenType.KEY, m.group('var')))
                        else:
                            nodes.append(QNode(TokenType.VAR, m.group('var')))
                    elif m.group('num') != None:
                        nodes.append(QNode(TokenType.NUM, m.group('num')))
                    elif m.group('alp') != None:
                        nodes.append(QNode(TokenType.ALP, m.group('alp')))
                    elif m.group('str') != None:
                        nodes.append(QNode(TokenType.STR, m.group('str')))
                    elif m.group('dob') != None:
                        nodes.append(QNode(TokenType.DOB, m.group('dob')))
                    elif m.group('pnt') != None:
                        nodes.append(QNode(TokenType.PNT, m.group('pnt')))
                    elif m.group('cmt') != None:
                        nodes.append(QNode(TokenType.CMT, m.group('cmt')))
                    #else:
                        #print("error")
            #print(tokens)
            #parent_stack = [{'predicate': None}]
            print(self.execute(nodes))

    def execute(self, nodes):
        exp = [{'predicate': None}]
        length = len(nodes)
        n = 0
        while n < length:
            node = nodes[n]
            if node.value == '(':
                exp[len(exp) - 1]['noun'], skip = self.execute(nodes[n + 1: len(nodes)])
                n = n + skip
            elif node.value == ')':
                length = n + 1
                break
            elif node.type == TokenType.VAR or node.type == TokenType.NUM or node.type == TokenType.STR:
                exp[len(exp) - 1]['noun'] = node
            elif node.type == TokenType.DOB or node.type == TokenType.PNT:
                if exp[len(exp) - 1]['predicate'] != None and Operation[exp[len(exp) - 1]['predicate']]['priority'] >= Operation[node.value]['priority']:
                    for i in range(len(exp) - 1, 0, -1):
                        exp[i - 1]['noun'] = QNode(2, Operation[exp[i]['predicate']]['apply'](int(exp[i - 1]['noun'].value), int(exp[i]['noun'].value)))
                    exp = [{'predicate': None, 'noun': exp[0]['noun']}]
                exp.append({'predicate': node.value})
            n = n + 1
        if len(exp) > 1:
            for i in range(len(exp) - 1, 0, -1):
                exp[i - 1]['noun'] = QNode(2, Operation[exp[i]['predicate']]['apply'](int(exp[i - 1]['noun'].value), int(exp[i]['noun'].value)))
        return exp[0]['noun'], length
                
class TokenType(Enum):
    KEY=0
    VAR=1
    NUM=2
    ALP=3
    STR=4
    DOB=5
    PNT=6
    CMT=7

Operation = {
    '+': {'priority': 1, 'apply': lambda x, y: x + y},
    '-': {'priority': 1, 'apply': lambda x, y: x - y},
    '*': {'priority': 2, 'apply': lambda x, y: x * y},
    '/': {'priority': 2, 'apply': lambda x, y: x / y},
    '^': {'priority': 3, 'apply': lambda x, y: x ** y}
}
