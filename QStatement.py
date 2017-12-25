import re
from QNode import *
class QStatement:
    inputs = None
    nodes = None
    cutlength = 0
    pattern = re.compile(
        r"\s*((?P<cmt>\/\/.*)|(?P<var>[_$A-Za-z][_\$A-Za-z0-9]*)|(?P<num>((?<=[+-])[+-][0-9]+(\.[0-9]+)?)|([0-9]+)(\.[0-9]+)?)|(?P<alp>[A-Za-z][A-Za-z0-9]*)|(?P<str>\"(\\\\|\\\"|\\n|[^\"])*\")|(?P<dob>==|!=|<=|>=|&&|\|\|)|(?P<pnt>[.,/#!$%^&\*;:{}+-=_`~()><]))?"
    )
    def __init__(self, inputs):
        self.inputs = inputs
        self.parse()
    
    def __str__(self):
        return str(self.inputs)
    def __repr__(self):
        return str(self.inputs)

    def cut(self, i):
        del(self.nodes[i])
        self.cutlength = self.cutlength + 1

    def boolvalue(self, node):
        return node.value == "true"

    def reset(self, tokens):
        tokens.clear()
        self.cutlength = 0

    def parse(self):
            nodes = []
            for m in self.pattern.finditer(self.inputs):
                    if m.group('var') != None:
                        nodes.append(QNode(QUtil.lexer['var'], m.group('var')))
                    elif m.group('num') != None:
                        nodes.append(QNode(QUtil.lexer['num'], m.group('num')))
                    elif m.group('alp') != None:
                        nodes.append(QNode(QUtil.lexer['alp'], m.group('alp')))
                    elif m.group('str') != None:
                        nodes.append(QNode(QUtil.lexer['str'], m.group('str')))
                    elif m.group('dob') != None:
                        nodes.append(QNode(QUtil.lexer['dob'], m.group('dob')))
                    elif m.group('pnt') != None:
                        nodes.append(QNode(QUtil.lexer['pnt'], m.group('pnt')))
                    elif m.group('cmt') != None:
                        nodes.append(QNode(QUtil.lexer['cmt'], m.group('cmt')))
                    #else:
                        #print("error")
            #print(tokens)
            self.nodes = nodes
            return nodes

    def execute(self, start, end, variables):
        stack=[]
        i = start
        if i == 0 and len(self.nodes) > 0 and self.nodes[0].value == "print":
           self.execute(1, len(self.nodes), variables)
           print(self.nodes[1].getstrval(variables), end="")
        else:
            
            while i < end - self.cutlength:
                node = self.nodes[i]
                if node.value == "(":
                    i = i + 1
                    stack.append(i)
                elif node.value == ")":
                    startpos = stack.pop()
                    #print(startpos, i)
                    if len(stack) == 0:
                        #print("call!")
                        k = self.execute(startpos, i, variables)
                        self.cut(k)
                        self.cut(k - 2)
                        #end = end - 2
                        i = i - 1
                    else:
                        i = i + 1
                else:
                    i = i + 1
            i = start
            #for token in tokens:
            #    print(token.value)
            while i < end - self.cutlength:
                #print(i, end)
                #for token in tokens:
                #    print(token.value)
                node = self.nodes[i]
                #print(str(token.value)+" "+str(token.type))
                if node.value == "*":
                    val = float(self.nodes[i-1].getvalue(variables).value) * float(self.nodes[i+1].getvalue(variables).value)
                    self.cut(i+1)
                    self.cut(i-1)
                    #end = end - 2
                    i = i - 1
                    if val == int(val):
                        val = int(val)
                    self.nodes[i]=QNode(QUtil.lexer['num'], str(val))
                elif node.value == "/":
                    val = float(self.nodes[i-1].getvalue(variables).value) / float(self.nodes[i+1].getvalue(variables).value)
                    self.cut(i+1)
                    self.cut(i-1)
                    #end = end - 2
                    i = i - 1
                    if val == int(val):
                        val = int(val)
                    self.nodes[i]=QNode(QUtil.lexer['num'], str(val))
                else:
                    i = i + 1

            i=start

            while i < end - self.cutlength:
                node = self.nodes[i]
                #print(str(token.value)+" "+str(token.type))
                if node.value == "+":
                    if self.nodes[i-1].getvalue(variables).type == QUtil.lexer['num'] and self.nodes[i+1].getvalue(variables).type == QUtil.lexer['num']:
                        val = float(self.nodes[i-1].getvalue(variables).value) + float(self.nodes[i+1].getvalue(variables).value)
                        self.cut(i+1)
                        self.cut(i-1)
                        #end = end - 2
                        i = i - 1
                        if val == int(val):
                            val = int(val)
                        self.nodes[i]=QNode(QUtil.lexer['num'], str(val))
                    elif self.nodes[i-1].getvalue(variables).type == QUtil.lexer['str'] or self.nodes[i+1].getvalue(variables).type == QUtil.lexer['str']:
                        val = str(self.nodes[i-1].getvalue(variables).getstrval(variables)) + str(self.nodes[i+1].getvalue(variables).getstrval(variables))
                        self.cut(i+1)
                        self.cut(i-1)
                        #end = end - 2
                        i = i - 1
                        self.nodes[i]=QNode(QUtil.lexer['str'], str("\""+val+"\""))
                        
                elif node.value == "-":
                    left = self.nodes[i-1].getvalue(variables)
                    if left.type != QUtil.lexer['num']:
                        val = -float(self.nodes[i+1].getvalue(variables).value)
                        self.cut(i+1)
                    else:
                        val = float(left.value) -float(self.nodes[i+1].getvalue(variables).value)
                        self.cut(i+1)
                        self.cut(i-1)
                        i = i - 1
                    #end = end - 2
                    
                    if val == int(val):
                        val = int(val)
                    self.nodes[i]=QNode(QUtil.lexer['num'], str(val))
                else:
                    i = i + 1
            
            i = start
            while i < end - self.cutlength:
                node = self.nodes[i]
                if node.value == "==":
                    val = self.nodes[i-1].getvalue(variables).value == self.nodes[i+1].getvalue(variables).value
                    self.cut(i+1)
                    self.cut(i-1)
                    #end = end - 2
                    i = i - 1
                    if val:
                        self.nodes[i].value = "true"
                    else:
                        self.nodes[i].value = "false"
                elif node.value == "!=":
                    val = self.nodes[i-1].getvalue(variables).value != self.nodes[i+1].getvalue(variables).value
                    self.cut(i+1)
                    self.cut(i-1)
                    #end = end - 2
                    i = i - 1
                    if val:
                        self.nodes[i].value = "true"
                    else:
                        self.nodes[i].value = "false"
                elif node.value == ">":
                    val = float(self.nodes[i-1].getvalue(variables).value) > float(self.nodes[i+1].getvalue(variables).value)
                    self.cut(i+1)
                    self.cut(i-1)
                    #end = end - 2
                    i = i - 1
                    if val:
                        self.nodes[i].value = "true"
                    else:
                        self.nodes[i].value = "false"
                elif node.value == "<":
                    val = float(self.nodes[i-1].getvalue(variables).value) < float(self.nodes[i+1].getvalue(variables).value)
                    self.cut(i+1)
                    self.cut(i-1)
                    i = i - 1
                    if val:
                        self.nodes[i].value = "true"
                    else:
                        self.nodes[i].value = "false"
                elif node.value == ">=":
                    val = float(self.nodes[i-1].getvalue(variables).value) >= float(self.nodes[i+1].getvalue(variables).value)
                    self.cut(i+1)
                    self.cut(i-1)
                    #end = end - 2
                    i = i - 1
                    if val:
                        self.nodes[i].value = "true"
                    else:
                        self.nodes[i].value = "false"
                elif node.value == "<=":
                    val = float(self.nodes[i-1].getvalue(variables).value) <= float(self.nodes[i+1].getvalue(variables).value)
                    self.cut(i+1)
                    self.cut(i-1)
                    #end = end - 2
                    i = i - 1
                    if val:
                        self.nodes[i].value = "true"
                    else:
                        self.nodes[i].value = "false"
                else:
                    i = i + 1

            i=start
            while i < end - self.cutlength:
                node = self.nodes[i]
                if node.value == "&&":
                    val = self.boolvalue(self.nodes[i-1].getvalue(variables)) and self.boolvalue(self.nodes[i+1].getvalue(variables))
                    self.cut(i+1)
                    self.cut(i-1)
                    #end = end - 2
                    i = i - 1
                    if val:
                        self.nodes[i].value = "true"
                    else:
                        self.nodes[i].value = "false"
                else:
                    i = i + 1
            i=start
            while i < end - self.cutlength:
                node = self.nodes[i]
                if node.value == "||":
                    val = self.boolvalue(self.nodes[i-1].getvalue(variables)) or self.boolvalue(self.nodes[i+1].getvalue(variables))
                    self.cut(i+1)
                    self.cut(i-1)
                    #end = end - 2
                    i = i - 1
                    if val:
                        self.nodes[i].value = "true"
                    else:
                        self.nodes[i].value = "false"
                else:
                    i = i + 1

            i=start
            while i < end - self.cutlength:
                node = self.nodes[i]
                if node.value == "=":
                    variables[self.nodes[i-1].value] = self.nodes[i+1].getvalue(variables)
                i = i + 1

        
            return i

    def bool_true(self, variables):
        self.execute(0, len(self.nodes), variables)
        return len(self.nodes) == 1 and self.nodes[0].bool_true()
