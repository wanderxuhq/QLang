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
                        if m.group('var') in QUtil.keywords:
                            nodes.append(QNode(QUtil.TokenType.KEY, m.group('var')))
                        else:
                            nodes.append(QNode(QUtil.TokenType.VAR, m.group('var')))
                    elif m.group('num') != None:
                        nodes.append(QNode(QUtil.TokenType.NUM, m.group('num')))
                    elif m.group('alp') != None:
                        nodes.append(QNode(QUtil.TokenType.ALP, m.group('alp')))
                    elif m.group('str') != None:
                        nodes.append(QNode(QUtil.TokenType.STR, m.group('str')))
                    elif m.group('dob') != None:
                        nodes.append(QNode(QUtil.TokenType.DOB, m.group('dob')))
                    elif m.group('pnt') != None:
                        nodes.append(QNode(QUtil.TokenType.PNT, m.group('pnt')))
                    elif m.group('cmt') != None:
                        nodes.append(QNode(QUtil.TokenType.CMT, m.group('cmt')))
                    #else:
                        #print("error")
            #print(tokens)
            self.nodes = nodes
            return nodes

    def execute(self, start, end, variables, functions):
        stack=[]
        i = start
        l = end
        while i < end - self.cutlength:
        #call function
            if i < end - 1 - self.cutlength and len(self.nodes) > 0 and self.nodes[i].type == QUtil.TokenType.VAR and self.nodes[i + 1].value == "(" and self.nodes[i].value not in QUtil.keywords:
                if self.nodes[i].value == "print":
                    self.execute(i + 1, len(self.nodes), variables, functions)
                    print(self.nodes[i + 1].getstrval(variables), end="")
                    break
                else:
                    #call function
                    function = functions[self.nodes[i].value]
                    #get params
                    l = i + 1
                    params = []
                    fstack = []
                    fstack.append(l)
                    l = l + 1
                    k = l
                    while len(fstack) > 0:
                        if self.nodes[l].value == ",":
                            l = self.execute(k, l - 1, variables, functions)
                            params.append(self.nodes[k])
                            l = k + 1
                        elif self.nodes[l].value == "(":
                            fstack.append(l)
                        elif self.nodes[l].value == ")":
                            fstack.pop()
                        l = l + 1
                    #self.cutlength = 0
                    #self.cutlength = 0
                    self.execute(k, l - 1, variables, functions)
                    
                    params.append(self.nodes[k])
                    result = function.call(self, params, functions)
                    k = i
                    while k < l - 1 - self.cutlength:
                        del(self.nodes[i])
                        #end = end - 1
                        k = k + 1
                    l = i + 1
                    self.nodes[i] = result
                    #print("check")
            elif len(self.nodes) > 0 and self.nodes[i].value == "return": #i should always == 0
                self.execute(start + 1, end - self.cutlength, variables, functions)
                #self.nodes[1]
                #1 -> some variable
                return self.nodes[1].getvalue(variables)
                #i = i + 1
            else:
                i = i + 1
        
        end = l
        #self.cutlength = 0
        i = start
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
                    k = self.execute(startpos, i, variables, functions)
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
                self.nodes[i]=QNode(QUtil.TokenType.NUM, str(val))
            elif node.value == "/":
                val = float(self.nodes[i-1].getvalue(variables).value) / float(self.nodes[i+1].getvalue(variables).value)
                self.cut(i+1)
                self.cut(i-1)
                #end = end - 2
                i = i - 1
                if val == int(val):
                    val = int(val)
                self.nodes[i]=QNode(QUtil.TokenType.NUM, str(val))
            else:
                i = i + 1

        i=start

        while i < end - self.cutlength:
            node = self.nodes[i]
            #print(str(token.value)+" "+str(token.type))
            if node.value == "+":
                if self.nodes[i-1].getvalue(variables).type == QUtil.TokenType.NUM and self.nodes[i+1].getvalue(variables).type == QUtil.TokenType.NUM:
                    val = float(self.nodes[i-1].getvalue(variables).value) + float(self.nodes[i+1].getvalue(variables).value)
                    self.cut(i+1)
                    self.cut(i-1)
                    #end = end - 2
                    i = i - 1
                    if val == int(val):
                        val = int(val)
                    self.nodes[i]=QNode(QUtil.TokenType.NUM, str(val))
                elif self.nodes[i-1].getvalue(variables).type == QUtil.TokenType.STR or self.nodes[i+1].getvalue(variables).type == QUtil.TokenType.STR:
                    val = str(self.nodes[i-1].getvalue(variables).getstrval(variables)) + str(self.nodes[i+1].getvalue(variables).getstrval(variables))
                    self.cut(i+1)
                    self.cut(i-1)
                    #end = end - 2
                    i = i - 1
                    self.nodes[i]=QNode(QUtil.TokenType.STR, str("\""+val+"\""))
                    
            elif node.value == "-":
                left = self.nodes[i-1].getvalue(variables)
                if left.type != QUtil.TokenType.NUM:
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
                self.nodes[i]=QNode(QUtil.TokenType.NUM, str(val))
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

    def bool_true(self, variables, functions):
        self.execute(0, len(self.nodes), variables, functions)
        return len(self.nodes) == 1 and self.nodes[0].bool_true()
