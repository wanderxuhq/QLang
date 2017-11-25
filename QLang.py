#import string
import re
import logging
from QNode import *
logger=logging.getLogger("QLang")
logger.setLevel(10)
#print(logger.getEffectiveLevel())
#input="42/21+3+-8/(5-(2*1+2))"
inputs=["a = 1","b=a","c=42/21+3+-8/(5-(2+a*2))"]
#f=open('D:\\\\out.txt','w')
pattern = re.compile(
    r"\s*((?P<var>[_$A-Za-z][_\$A-Za-z0-9]*)|(?P<num>((?<=[+-])[+-][0-9]+(\.[0-9]+)?)|([0-9]+)(\.[0-9]+)?)|(?P<alp>[A-Za-z][A-Za-z0-9]*)|(?P<str>\"(\\\\|\\\"|\\n|[^\"])*\")|(?P<dob>==|<=|>=|&&|\|\|)|(?P<pnt>[.,/#!$%^&\*;:{}+-=_`~()])|(?P<cmt>\/\/.*))?"
)
print(inputs)
#pattern="\s*((?P<num>[0-9]+)|([A-Za-z][A-Za-z0-9]*)|(\"(\\\\|\\\"|\\n|[^\"])*\")|(==|<=|>=|&&|\|\|)|([.,/#!$%^&\*;:{}+-=_`~()])|(\/\/.*))?"
#num, character, string, double punct, punct, comment
#0, a, "a0", ==, +, //
#m = pattern.match(input)
lexer = {'var':0, 'num':1, 'alp':2, 'str':3, 'dob':4, 'pnt':5, 'cmt':6}
tokens=[]
cutlength = 0
variables = {}

def cut(tokens, i):
    global cutlength
    del(tokens[i])
    cutlength = cutlength + 1

def getvalue(token):
    if(token.type == lexer['var']):
        return getvalue(variables[token.value])
    else:
        return token

def execute(tokens, start, end):
    stack=[]
    global cutlength
    i = start        
    while i < end - cutlength:
        token = tokens[i]
        if token.value == "(":
            i = i + 1
            stack.append(i)
        elif token.value == ")":
            startpos = stack.pop()
            #print(startpos, i)
            if len(stack) == 0:
                #print("call!")
                k = execute(tokens, startpos, i)
                cut(tokens, k)
                cut(tokens, k - 2)
                #end = end - 2
                i = i - 1
            else:
                i = i + 1
        else:
            i = i + 1
    i = start
    #for token in tokens:
    #    print(token.value)
    while i < end - cutlength:
        #print(i, end)
        #for token in tokens:
        #    print(token.value)
        token = tokens[i]
        #print(str(token.value)+" "+str(token.type))
        if token.value == "*":
            val = float(getvalue(tokens[i-1]).value) * float(getvalue(tokens[i+1]).value)
            cut(tokens, i+1)
            cut(tokens, i-1)
            #end = end - 2
            i = i - 1
            if val == int(val):
                val = int(val)
            tokens[i].value=str(val)
        elif token.value == "/":
            val = float(getvalue(tokens[i-1]).value) / float(getvalue(tokens[i+1]).value)
            cut(tokens, i+1)
            cut(tokens, i-1)
            #end = end - 2
            i = i - 1
            if val == int(val):
                val = int(val)
            tokens[i].value=str(val)
        else:
            i = i + 1

    i=start

    while i < end - cutlength:
        token = tokens[i]
        #print(str(token.value)+" "+str(token.type))
        if token.value == "+":
            val = float(getvalue(tokens[i-1]).value) + float(getvalue(tokens[i+1]).value)
            cut(tokens, i+1)
            cut(tokens, i-1)
            #end = end - 2
            i = i - 1
            if val == int(val):
                val = int(val)
            tokens[i].value=str(val)
        elif token.value == "-":
            val = float(getvalue(tokens[i-1]).value) - float(getvalue(tokens[i+1]).value)
            cut(tokens, i+1)
            cut(tokens, i-1)
            #end = end - 2
            i = i - 1
            if val == int(val):
                val = int(val)
            tokens[i].value=str(val)
        else:
            i = i + 1
        
    i=start

    while i < end - cutlength:
        token = tokens[i]
        if token.value == "=":
            variables[tokens[i-1].value] = getvalue(tokens[i+1])
        i = i + 1

    return i
    
for input in inputs:
    for m in pattern.finditer(input):
        if m.group('var') != None:
            tokens.append(QNode(lexer['var'], m.group('var')))
        elif m.group('num') != None:
            tokens.append(QNode(lexer['num'], m.group('num')))
        elif m.group('alp') != None:
            tokens.append(QNode(lexer['alp'], m.group('alp')))
        elif m.group('str') != None:
            tokens.append(QNode(lexer['str'], m.group('str')))
        elif m.group('dob') != None:
            tokens.append(QNode(lexer['dob'], m.group('dob')))
        elif m.group('pnt') != None:
            tokens.append(QNode(lexer['pnt'], m.group('pnt')))
        elif m.group('cmt') != None:
            tokens.append(QNode(lexer['cmt'], m.group('cmt')))
        #else:
            #print("error")
    execute(tokens, 0, len(tokens))
    tokens.clear()
    #calc = copy.deepcopy(tokens)
print(tokens)



#def execute end
#while len(tokens) > 1:
#execute(tokens, 0, len(tokens))
#print(len(tokens))
for token in tokens:
    print(token.value)
print(variables)
        
    #m = pattern.match(input)
    
#for m in re.match(pattern, input):
#    print(m.group('num'))
    #f.write(token[0]+"\n")
#f.close()
#if __name__ == "main":
