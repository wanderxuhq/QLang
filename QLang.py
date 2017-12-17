#import string
import logging
from QBlock import *
logger=logging.getLogger("QLang")
logger.setLevel(10)
#print(logger.getEffectiveLevel())
#input="42/21+3+-8/(5-(2*1+2))"
#inputs=["a = 1","b=a","b=b+1","while(a<b){","c=42/21+3+-8/(5-(2+b*2))","d=5" ,"}"]
#inputs=["a=0","b=5","c=3","d=7","k=a+b*(c+d)"]
inputs=["a=0","b=5","c=0","k=0","d=0","while(a<=b){","i=0","while(i<2){","d=d+i","while(k<3){","k=k+1","}","i=i+1","}","c=c+a","a=a+1","}"]
#inputs=["a = 1","a=a+1"]
#inputs=["a=1","b=a+1","c=b>a&&false"]
#f=open('D:\\\\out.txt','w')

print(inputs)
#pattern="\s*((?P<num>[0-9]+)|([A-Za-z][A-Za-z0-9]*)|(\"(\\\\|\\\"|\\n|[^\"])*\")|(==|<=|>=|&&|\|\|)|([.,/#!$%^&\*;:{}+-=_`~()])|(\/\/.*))?"
#num, character, string, double punct, punct, comment
#0, a, "a0", ==, +, //
#m = pattern.match(input)


cutlength = 0

a = QBlock(inputs, {})
a.run()


#def execute end
#while len(tokens) > 1:
#execute(tokens, 0, len(tokens))
#print(len(tokens))
print("END!")
print(a.variables)
print(a)
#print(a.sub_blocks)
        
    #m = pattern.match(input)
    
#for m in re.match(pattern, input):
#    print(m.group('num'))
    #f.write(token[0]+"\n")
#f.close()
#if __name__ == "main":
