from enum import Enum
class QUtil:
    class TokenType(Enum):
        KEY=0
        VAR=1
        NUM=2
        ALP=3
        STR=4
        DOB=5
        PNT=6
        CMT=7
    keywords = ["true", "false", "if", "elif", "else", "while"]
